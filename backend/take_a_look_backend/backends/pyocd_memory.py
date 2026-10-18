from __future__ import annotations

import threading
import zipfile
from dataclasses import dataclass
from time import perf_counter
from typing import Any

from take_a_look_backend.protocol import ProtocolError
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

    @property
    def is_connected(self) -> bool:
        return self.session is not None and self.target is not None

    @property
    def probe(self) -> Any | None:
        return self.session.probe if self.session is not None else None

    def connect(self, config: PyOcdConnectionConfig) -> None:
        if self.is_connected:
            return

        from pyocd.core.helpers import ConnectHelper
        from pyocd.core.session import Session

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
            probe_filter = config.probe_filter.lower()
            probes = [probe for probe in probes if probe_filter in probe.description.lower()]
        if not probes:
            timings["total_s"] = perf_counter() - total_started
            self.last_connect_timings = timings
            raise RuntimeError("没有找到可用的调试探针。")

        probe = probes[0]
        open_started = perf_counter()
        session = None
        try:
            self._prepare_target(config)
            session = Session(probe, auto_open=False, options=options)
            session.open()
            timings["session_open_s"] = perf_counter() - open_started
        except Exception:
            timings["session_open_s"] = perf_counter() - open_started
            timings["total_s"] = perf_counter() - total_started
            self.last_connect_timings = timings
            try:
                if session is not None:
                    session.close()
            finally:
                self._release_target_registry()
            raise

        self.session = session
        self.target = session.target
        timings["total_s"] = perf_counter() - total_started
        self.last_connect_timings = timings

    def disconnect(self) -> None:
        session = self.session
        self.session = None
        self.target = None
        self._read_plan_signature = None
        self._read_plan = ()
        try:
            if session is not None:
                session.close()
        finally:
            self._release_target_registry()

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

        target = self._require_target()
        segments = _firmware_segments(path, target)
        # FileProgrammer catches invalid ELF segment addresses and only logs a
        # warning. Queue validated segments directly so no data can be skipped.
        last_progress = 0.0
        def write_progress(value: float) -> None:
            nonlocal last_progress
            # pyOCD starts its progress range again between erase and program.
            last_progress = max(last_progress, min(0.8, max(0.0, value * 0.8)))
            progress(last_progress)
        loader = MemoryLoader(self.session, progress=write_progress,
                              chip_erase="sector", trust_crc=False)
        for address, data in segments:
            loader.add_data(address, data)
        try:
            loader.commit()
            target.halt()
            target.flush()
            progress(0.8)
            total = sum(len(data) for _, data in segments)
            verified = 0
            for address, data in segments:
                for offset in range(0, len(data), 4096):
                    expected = data[offset:offset + 4096]
                    actual = bytes(target.read_memory_block8(address + offset, len(expected)))
                    if actual != expected:
                        mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                                        min(len(actual), len(expected)))
                        raise ProtocolError("firmware_verify_failed", "固件写后校验失败，未确认下载成功。",
                                            f"地址 0x{address + offset + mismatch:08X}")
                    verified += len(expected)
                    progress(0.8 + 0.2 * verified / total)
        finally:
            self._read_plan_signature = None
            self._read_plan = ()

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
