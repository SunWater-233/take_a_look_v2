from __future__ import annotations

import threading
import struct
import zipfile
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from time import perf_counter
from typing import Any

from take_a_look_backend.models import SampleFrame, SymbolInfo
from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.backends.pyocd_compat import (
    close_pyocd_session, guard_dap_error_recovery, normalise_pack_svd,
)
from take_a_look_backend.backends.probe_presence import ProbePresence, ProbePresenceMonitor
from take_a_look_backend.backends.local_firmware import firmware_segments as _firmware_segments
from take_a_look_backend.backends.target_backend import capabilities_for_connection
# Re-export the existing codec entry points for external callers.
from take_a_look_backend.backends.typed_memory import (
    TypedMemoryBackend, _build_coalesced_read_plan, decode_symbol_value, encode_symbol_value,
)


_TARGET_REGISTRY_LOCK = threading.Lock()
_MAX_PIPELINE_PACKETS = 4
_PIPELINE_BATCH_SECONDS = 0.002


@dataclass(frozen=True)
class PyOcdConnectionConfig:
    target: str | None
    frequency_hz: int
    unique_id: str | None = None
    probe_filter: str | None = None
    connect_mode: str = "attach"
    pack_path: str | None = None
    part_number: str | None = None


class PyOcdMemoryBackend(TypedMemoryBackend):
    capabilities = capabilities_for_connection("local")

    def __init__(self) -> None:
        super().__init__()
        self.session: Any | None = None
        self._owns_target_registry = False
        self._pack_archive: zipfile.ZipFile | None = None
        self._presence = ProbePresenceMonitor()
        self.last_flash_stats: dict[str, int | float | str] | None = None
        self._config: PyOcdConnectionConfig | None = None
        self._burst_sequence = 0

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
        self._config = config
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
        self._config = None
        self.target = None
        self._presence.reset()
        self._clear_read_plans()
        self._burst_sequence = 0
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
        from pyocd.probe.jlink_probe import JLinkProbe
        from .jlink_flash import program_jlink
        from .pyocd_flash import program_pyocd

        self.last_flash_stats = None
        target = self._require_target()
        native = isinstance(self.probe, JLinkProbe)
        try:
            segments = _firmware_segments(path, target, require_flash_algorithm=not native)
            if native:
                config = self._config
                self.last_flash_stats = program_jlink(
                    self.session, segments, progress,
                    part_number=config.part_number if config else None,
                    target_name=config.target if config else None,
                    frequency_hz=config.frequency_hz if config else 1_000_000,
                )
            else:
                self.last_flash_stats = program_pyocd(self.session, segments, progress)
        finally:
            self._clear_read_plans()

    def _read_block(self, address: int, size: int) -> bytes:
        from pyocd.core.exceptions import Error

        try:
            return super()._read_block(address, size)
        except Error as error:
            raise _memory_read_error(address, size, error) from error

    def _cmsis_dap_link(self) -> Any | None:
        from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
        from pyocd.probe.debug_probe import DebugProbe

        probe = self.probe
        if not isinstance(probe, CMSISDAPProbe) or probe.wire_protocol != DebugProbe.Protocol.SWD:
            return None
        link = probe._link  # pyOCD 0.46 keeps the deferred packet queue here.
        return link if link._deferred_transfer else None

    @property
    def memory_pipeline_depth(self) -> int:
        link = self._cmsis_dap_link()
        return min(_MAX_PIPELINE_PACKETS, link._interface.get_packet_count()) if link else 0

    def read_sample_burst(
        self, symbols: tuple[SymbolInfo, ...], rate_hz: float, acquisition_time: Callable[[], float],
        *, overclock: bool = False, controls_idle: Callable[[], bool] | None = None,
    ) -> list[SampleFrame] | None:
        """Batch running RAM reads using the driver's deferred DAP_Transfer."""
        if not symbols or (not overclock and rate_hz < 4_000):
            return None

        from pyocd.core.exceptions import Error
        from pyocd.coresight.ap import CSW_SIZE32, MEM_AP, MEM_AP_CSW, MEM_AP_DRW, MEM_AP_TAR
        from pyocd.probe.pydapaccess.dap_access_api import DAPAccessIntf

        link = self._cmsis_dap_link()
        if link is None or (not overclock and not link._interface.is_bulk):
            return None
        depth = min(_MAX_PIPELINE_PACKETS, link._interface.get_packet_count()) if overclock else 1
        if depth < 1:
            return None

        target = self._require_target()
        ap = getattr(target.selected_core, "ap", None)
        if not isinstance(ap, MEM_AP) or ap._accelerated_memory_interface is not None:
            return None

        plan = self._read_plan_for(symbols)
        page_size = ap.auto_increment_page_size
        total_bytes = 0
        for block in plan:
            region = target.memory_map.get_region_for_address(block.address)
            if (block.address % 4 or block.size % 4
                    or block.address % page_size + block.size > page_size
                    or region is None or not region.is_ram
                    or not region.contains_range(start=block.address, length=block.size)):
                return None
            total_bytes += block.size
        words = total_bytes // 4
        # DAP_Transfer carries a three-byte header and one TAR write per block.
        # Reserve request space for both the SELECT and CSW setup writes.
        repeat = min(8, (link._packet_size - 13) // (5 * len(plan) + words),
                     (link._packet_size - 3) // total_bytes)
        if overclock:
            # The sampler spaces groups by the number of reads they contain.
            # Bound each group to about 2 ms of the configured sample budget.
            sample_budget = int(rate_hz * _PIPELINE_BATCH_SECONDS)
            repeat = min(repeat, sample_budget // min(depth, 2))
        if repeat < 2:
            return None
        if overclock:
            depth = min(depth, sample_budget // repeat)

        codecs = [struct.Struct(f"<{block.size // 4}I") for block in plan]
        pending = deque()
        completed = []
        started = perf_counter()
        block = plan[0]

        ap.lock()
        try:
            if overclock:
                # Finish any deferred writes from a previous user/RTT operation.
                link.flush()
            ap.write_reg(ap._reg_offset + MEM_AP_CSW, ap._csw | CSW_SIZE32)
            for _ in range(depth):
                if pending and controls_idle is not None and not controls_idle():
                    break
                reads = deque()
                pending.append((acquisition_time(), reads))
                for _ in range(repeat):
                    for block in plan:
                        ap.write_reg(ap._reg_offset + MEM_AP_TAR, block.address)
                        read = ap.dp.read_ap_multiple(
                            ap.address.address + ap._reg_offset + MEM_AP_DRW,
                            block.size // 4, now=False,
                        )
                        reads.append((block, read))
                if overclock:
                    link._send_packet()
            while pending:
                start, reads = pending[0]
                data = []
                while reads:
                    block, read = reads.popleft()
                    data.append(read())
                completed.append((start, acquisition_time(), data))
                pending.popleft()
        except (Error, DAPAccessIntf.Error) as error:
            raise _memory_read_error(block.address, block.size, error) from error
        finally:
            # Every callback owns a DP SELECT lock. Finish outstanding replies
            # before releasing the probe to pause, debug controls or monitoring.
            try:
                for _, reads in pending:
                    for _, read in reads:
                        try:
                            read()
                        except Exception:
                            pass
            finally:
                ap.unlock()
        duration = perf_counter() - started
        frames = []
        for start, end, data in completed:
            self._burst_sequence += 1
            words = iter(data)
            for index in range(repeat):
                values = {}
                for block, codec in zip(plan, codecs, strict=True):
                    block.decode(codec.pack(*next(words)), values)
                frames.append(SampleFrame.from_transaction(
                    values, start=start, end=end,
                    sequence=self._burst_sequence, index=index, repeat=repeat,
                ))
        self.last_read_metrics = {
            "symbol_count": len(symbols), "block_count": len(plan) * len(frames),
            "byte_count": total_bytes * len(frames), "duration_us": round(duration * 1e6),
            "burst": repeat, "time_quality": "transaction_window",
            "sampling_mode": "pipeline" if overclock else "timed",
            "packets_in_flight": depth,
        }
        return frames

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
