from __future__ import annotations

import threading
import struct
import zipfile
from collections import deque
from dataclasses import dataclass
from time import perf_counter
from typing import Any

from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.backends.pyocd_compat import (
    close_pyocd_session, guard_dap_error_recovery, normalise_pack_svd,
)
from take_a_look_backend.backends.probe_presence import ProbePresence, ProbePresenceMonitor
from take_a_look_backend.backends.local_firmware import batched_flash_pages, flash_sector_plan, read_firmware_chunks, sector_matches
from take_a_look_backend.backends.target_backend import capabilities_for_connection
# Re-export the existing codec entry points for external callers.
from take_a_look_backend.backends.typed_memory import (
    TypedMemoryBackend, _build_coalesced_read_plan, decode_symbol_value, encode_symbol_value,
)


_TARGET_REGISTRY_LOCK = threading.Lock()


@dataclass(frozen=True)
class PyOcdConnectionConfig:
    target: str | None
    frequency_hz: int
    unique_id: str | None = None
    probe_filter: str | None = None
    connect_mode: str = "attach"
    pack_path: str | None = None


class PyOcdMemoryBackend(TypedMemoryBackend):
    capabilities = capabilities_for_connection("local")

    def __init__(self) -> None:
        super().__init__()
        self.session: Any | None = None
        self._owns_target_registry = False
        self._pack_archive: zipfile.ZipFile | None = None
        self._presence = ProbePresenceMonitor()
        self.last_flash_stats: dict[str, int | float] | None = None

    @property
    def is_connected(self) -> bool:
        return self.session is not None and self.target is not None

    @property
    def probe(self) -> Any | None:
        return getattr(self.session, "probe", None)

    def connect(self, config: PyOcdConnectionConfig) -> None:
        if self.is_connected:
            return

        from pyocd.core.helpers import ConnectHelper
        from pyocd.core.session import Session
        from pyocd.probe.jlink_probe import JLinkProbe

        total_started = perf_counter()
        timings: dict[str, float] = {}
        options: dict[str, object] = {
            "frequency": config.frequency_hz,
            "connect_mode": config.connect_mode,
            "resume_on_disconnect": True,
        }
        if config.target:
            options["target_override"] = config.target

        probe_scan_started = perf_counter()
        probes = ConnectHelper.get_all_connected_probes(blocking=False, unique_id=config.unique_id)
        timings["probe_scan_s"] = perf_counter() - probe_scan_started
        if config.probe_filter:
            probes = [probe for probe in probes if _matches_probe_filter(probe, config.probe_filter)]
        if not probes:
            timings["total_s"] = perf_counter() - total_started
            self.last_connect_timings = timings
            raise RuntimeError("没有找到可用的调试探针。")

        probe = probes[0]
        # H723 is a single Cortex-M7 on AP0. Connecting the J-Link core enables
        # pyOCD's native block-memory interface; low-level CoreSight otherwise
        # sends every data word as a separate synchronous DLL/USB operation.
        native_jlink = (isinstance(probe, JLinkProbe) and config.pack_path is None
                        and (config.target or "").casefold() == "stm32h723xx")
        if native_jlink:
            options["jlink.device"] = "Cortex-M7"
        open_started = perf_counter()
        session = None
        try:
            self._prepare_target(config)
            session = Session(probe, auto_open=False, options=options)
            self.session = session
            # Guard before open: discovery can encounter the same failed
            # recovery as running-target memory sampling.
            guard_dap_error_recovery(session.target)
            if config.pack_path is not None:
                normalise_pack_svd(session.target)
            session.open()
            if native_jlink:
                # pylink.connect() selects automatic speed during core connect.
                # Restore the explicit clock before sampling or flashing.
                probe.set_clock(config.frequency_hz)
            timings["session_open_s"] = perf_counter() - open_started
        except Exception as error:
            timings["session_open_s"] = perf_counter() - open_started
            timings["total_s"] = perf_counter() - total_started
            self.last_connect_timings = timings
            try:
                self.disconnect()
            except Exception as cleanup_error:
                error.add_note(f"连接失败后的清理异常：{cleanup_error}")
            raise

        self.session = session
        self.target = session.target
        self._presence.reset()
        timings["total_s"] = perf_counter() - total_started
        self.last_connect_timings = timings

    def disconnect(self) -> None:
        self._close_session(probe_lost=False)

    def disconnect_lost_probe(self) -> None:
        """Release a missing probe without accessing or resuming its target."""
        self._close_session(probe_lost=True)

    def _close_session(self, *, probe_lost: bool) -> None:
        session = self.session
        self.session = None
        self.target = None
        self._presence.reset()
        self._clear_read_plans()
        try:
            if session is not None:
                close_pyocd_session(session, probe_lost=probe_lost)
        finally:
            self._release_target_registry()

    def check_connection(self, *, error: Exception | None = None, force: bool = False) -> None:
        """Check probe presence, independently of target/SWD accessibility."""
        from pyocd.core.exceptions import ProbeDisconnected

        if not self.is_connected:
            return
        if self._presence.check(self.probe, error=error, force=force) is ProbePresence.MISSING:
            raise ProbeDisconnected("本地调试探针已拔出或连接已中断。") from (error or self._presence.last_error)

    def _prepare_target(self, config: PyOcdConnectionConfig) -> None:
        from pyocd.target import TARGET, normalise_target_type_name
        from pyocd.target.builtin import BUILTIN_TARGETS
        from pyocd.target.pack.cmsis_pack import CmsisPack
        from pyocd.target.pack.pack_target import PackTargets

        if not _TARGET_REGISTRY_LOCK.acquire(blocking=False):
            raise RuntimeError("另一个本地连接正在使用目标定义。")
        self._owns_target_registry = True
        TARGET.clear()
        TARGET.update(BUILTIN_TARGETS)
        if config.pack_path is None:
            return
        if not config.target:
            raise RuntimeError("芯片包连接必须明确选择目标芯片。")
        self._pack_archive = zipfile.ZipFile(config.pack_path)
        pack = CmsisPack(self._pack_archive)
        name = normalise_target_type_name(config.target)
        devices = [device for device in pack.devices if normalise_target_type_name(device.part_number) == name]
        if len(devices) != 1:
            raise RuntimeError("所选芯片包中没有唯一匹配的目标芯片。")
        # PackTargets skips existing names. Remove just the selected name so
        # even a builtin alias is replaced by this explicit pack and version.
        TARGET.pop(name, None)
        PackTargets.populate_device(devices[0])
        if name not in TARGET:
            raise RuntimeError("无法从所选芯片包生成目标定义。")

    def _release_target_registry(self) -> None:
        if not self._owns_target_registry:
            return
        from pyocd.target import TARGET
        from pyocd.target.builtin import BUILTIN_TARGETS
        try:
            TARGET.clear()
            TARGET.update(BUILTIN_TARGETS)
            if self._pack_archive is not None:
                self._pack_archive.close()
                self._pack_archive = None
        finally:
            self._owns_target_registry = False
            _TARGET_REGISTRY_LOCK.release()

    def program_firmware(self, path: str, progress) -> None:
        from pyocd.flash.loader import MemoryLoader

        self.last_flash_stats = None
        started = perf_counter()
        target = self._require_target()
        segments = _firmware_segments(path, target)
        total = sum(len(data) for _, data in segments)
        # FileProgrammer catches invalid ELF segment addresses and only logs a
        # warning. Queue validated segments directly so no data can be skipped.
        last_progress = 0.0
        programming_start = 0.0
        def write_progress(value: float) -> None:
            nonlocal last_progress
            # pyOCD starts its progress range again between erase and program.
            last_progress = max(last_progress, min(0.8, max(0.0,
                                programming_start + value * (0.8 - programming_start))))
            progress(last_progress)
        loader = MemoryLoader(self.session, progress=write_progress,
                              chip_erase="sector", trust_crc=False)
        for address, data in segments:
            loader.add_data(address, data)
        sectors = flash_sector_plan(target, segments)
        try:
            # Pack algorithms may change Flash latency without resetting the
            # application's clocks (GD32E50x sets zero wait states). Start from
            # reset clocks before any smart-flash reads, erase, or programming.
            target.reset_and_halt()
            compare_started = perf_counter()
            compared_bytes = skipped_bytes = skipped_sectors = 0
            changed = []
            def compared(size: int) -> None:
                nonlocal compared_bytes
                compared_bytes += size
                progress(0.15 * compared_bytes / total)
            if sectors is not None:
                for sector in sectors:
                    if sector_matches(target, sector, compared):
                        skipped_bytes += sum(len(data) for _, data in sector.chunks)
                        skipped_sectors += 1
                    else:
                        # Keep ALL image chunks in a changed sector, including
                        # matching pages that its erase will destroy.
                        changed.extend(sector.chunks)
                programming_start = last_progress = 0.15
                progress(last_progress)
                loader = MemoryLoader(self.session, progress=write_progress,
                                      chip_erase="sector", trust_crc=False, smart_flash=False)
                for address, data in changed:
                    loader.add_data(address, data)
            compare_s = perf_counter() - compare_started
            program_started = perf_counter()
            wrote = sectors is None or bool(changed)
            if wrote:
                if sectors is None:
                    loader.commit()
                else:
                    with batched_flash_pages(target, changed):
                        loader.commit()
            program_s = perf_counter() - program_started
            target.halt()
            target.flush()
            progress(0.8)
            verify_started = perf_counter()
            verified = 0
            # An entirely unchanged image was already read and compared byte
            # for byte, with no flash algorithm run. Any write requires a fresh
            # read of the whole image, including the skipped sectors and RAM.
            for address, expected, actual in read_firmware_chunks(target, segments) if wrote else ():
                if actual != expected:
                    mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                                    min(len(actual), len(expected)))
                    expected_byte = f"0x{expected[mismatch]:02X}" if mismatch < len(expected) else "数据结束"
                    actual_byte = f"0x{actual[mismatch]:02X}" if mismatch < len(actual) else "未读到数据"
                    raise ProtocolError("firmware_verify_failed", "固件写后校验失败，未确认下载成功。",
                                        f"地址 0x{address + mismatch:08X}，"
                                        f"期望 {expected_byte}，实际 {actual_byte}")
                verified += len(expected)
                progress(0.8 + 0.2 * verified / total)
            self.last_flash_stats = {
                "data_bytes": total, "compared_bytes": compared_bytes,
                "skipped_bytes": skipped_bytes, "skipped_sectors": skipped_sectors,
                "compare_s": compare_s, "program_s": program_s,
                "verify_s": perf_counter() - verify_started, "total_s": perf_counter() - started,
            }
            if not wrote:
                progress(1.0)
        finally:
            self._clear_read_plans()

    def _read_block(self, address: int, size: int) -> bytes:
        from pyocd.core.exceptions import Error

        try:
            return super()._read_block(address, size)
        except Error as error:
            raise _memory_read_error(address, size, error) from error

    def _read_blocks(self, plan):
        from pyocd.core.exceptions import Error

        target = self._require_target()
        # A native memory interface may return deferred-looking callbacks after
        # already performing synchronous I/O. Keep its accelerated block reads.
        core = getattr(target, "selected_core", target)
        accelerated = getattr(getattr(core, "ap", None), "_accelerated_memory_interface", None)
        # Queue single-word scatter reads; never split a coalesced block into
        # scalar operations, which would regress native J-Link/ST-Link paths.
        if (accelerated is not None or len(plan) < 2 or
                not callable(getattr(target, "read_memory", None)) or
                any(block.address % 4 or block.size != 4 for block in plan)):
            yield from super()._read_blocks(plan)
            return
        for start in range(0, len(plan), 32):
            queued = deque()
            data = []
            try:
                for block in plan[start:start + 32]:
                    callback = target.read_memory(block.address, transfer_size=32, now=False)
                    queued.append((block, callback))
                while queued:
                    block, callback = queued.popleft()
                    value = callback() if callable(callback) else callback
                    data.append(struct.pack("<I", value))
            except Error as error:
                raise _memory_read_error(block.address, block.size, error) from error
            finally:
                # Deferred DP callbacks own probe locks until consumed. Drain
                # every issued read even after a queue/resolve failure, keeping
                # the original error and never retrying a hardware operation.
                for _block, callback in queued:
                    if callable(callback):
                        try:
                            callback()
                        except Exception:
                            pass
            # Resolve the complete chunk before yielding so consumer/decoder
            # failures cannot leave pending callbacks behind in this generator.
            yield from data

    def set_breakpoint(self, address: int) -> bool:
        target = self._require_target()
        if not target.set_breakpoint(address):
            return False
        self._flush_breakpoints()
        breakpoint = target.find_breakpoint(address & ~1)
        return breakpoint is not None and breakpoint.enabled

    def remove_breakpoint(self, address: int) -> None:
        self._require_target().remove_breakpoint(address)
        self._flush_breakpoints()

    def _flush_breakpoints(self) -> None:
        target = self._require_target()
        # pyOCD queues breakpoint changes until the next PRE_RUN notification.
        # A running target may never resume again, so commit changes now and
        # drain probe writes before reporting the breakpoint as verified.
        target.selected_core.bp_manager.flush()
        target.flush()

    def _require_target(self) -> Any:
        if self.target is None:
            raise RuntimeError("pyOCD 后端尚未连接。")
        return self.target



def _memory_read_error(address: int, size: int, error: Exception) -> ProtocolError:
    return ProtocolError("memory_read_failed", f"读取内存失败（地址 0x{address:08X}，{size} 字节）：{error}")


def _matches_probe_filter(probe: Any, probe_filter: str) -> bool:
    from pyocd.probe.aggregator import PROBE_CLASSES

    normalized = probe_filter.strip().casefold()
    plugin_name = {"j-link": "jlink", "st-link": "stlink", "cmsis-dap": "cmsisdap"}.get(normalized)
    if plugin_name is not None:
        # OEM products such as SAM-ICE use the J-Link driver without putting
        # "J-Link" in their description. Product names do not identify drivers.
        probe_class = PROBE_CLASSES.get(plugin_name)
        return probe_class is not None and isinstance(probe, probe_class)
    return normalized in probe.description.casefold()


def _firmware_segments(path: str, target: Any) -> list[tuple[int, bytes]]:
    """Validate every load address before allowing any erase or write."""
    from elftools.elf.elffile import ELFFile

    segments = []
    flash_bytes = 0
    memory_map = target.memory_map
    core_name = target.selected_core.node_name
    with open(path, "rb") as stream:
        elf = ELFFile(stream)
        if elf.header.e_machine != "EM_ARM":
            raise ProtocolError("invalid_firmware", "请选择适用于 ARM 目标的 ELF / AXF 固件。")
        for segment in elf.iter_segments():
            if segment.header.p_type != "PT_LOAD" or not segment.header.p_filesz:
                continue
            address = int(segment.header.p_paddr)
            data = segment.data()
            if len(data) != segment.header.p_filesz or address + len(data) > 0x100000000:
                raise ProtocolError("invalid_firmware", "固件段不完整或地址超出范围。")
            cursor = address
            while cursor < address + len(data):
                region = memory_map.get_region_for_address(cursor, core_name)
                if region is None:
                    raise ProtocolError("firmware_address_invalid", "固件地址不在所选芯片的内存范围内，请检查芯片型号。",
                                        f"地址 0x{cursor:08X}")
                size = min(address + len(data), region.end + 1) - cursor
                if region.is_flash:
                    if region.flash is None:
                        raise ProtocolError("flash_algorithm_missing", "所选芯片缺少可用的 Flash 烧录算法，请选择正确芯片或导入芯片包。",
                                            f"地址 0x{cursor:08X}")
                    flash_bytes += size
                elif not (region.is_ram and region.is_writable):
                    raise ProtocolError("firmware_address_invalid", "固件段必须位于 Flash 或可写 RAM 中。",
                                        f"地址 0x{cursor:08X}")
                cursor += size
            segments.append((address, data))
    if not segments:
        raise ProtocolError("firmware_empty", "固件中没有可下载的数据段。")
    if not flash_bytes:
        raise ProtocolError("flash_algorithm_missing", "固件未匹配到 Flash 区域；通用 Cortex-M 不支持固件烧录，请选择具体芯片型号。")
    return segments
