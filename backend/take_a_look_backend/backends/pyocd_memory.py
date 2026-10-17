from __future__ import annotations

import math
import struct
import threading
import zipfile
from dataclasses import dataclass
from time import perf_counter
from typing import Any

from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import ProtocolError


_TARGET_REGISTRY_LOCK = threading.Lock()


@dataclass(frozen=True)
class PyOcdConnectionConfig:
    target: str | None
    frequency_hz: int
    unique_id: str | None = None
    probe_filter: str | None = None
    connect_mode: str = "attach"
    pack_path: str | None = None


class PyOcdMemoryBackend:
    MAX_COALESCED_READ_BYTES = 512
    MAX_COALESCED_GAP_BYTES = 16

    def __init__(self) -> None:
        self.session: Any | None = None
        self.target: Any | None = None
        self.last_connect_timings: dict[str, float] = {}
        self.last_read_metrics: dict[str, int] = {
            "symbol_count": 0,
            "block_count": 0,
            "byte_count": 0,
        }
        self._read_plan_signature: tuple[tuple[int, int, str], ...] | None = None
        self._read_plan: tuple[_ReadBlock, ...] = ()
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

    def read_symbol(self, symbol: SymbolInfo) -> object:
        target = self._require_target()
        size = _access_size(symbol)
        data = bytes(target.read_memory_block8(symbol.address, size))
        return decode_symbol_value(symbol, data)

    def read_symbols(self, symbols: list[SymbolInfo]) -> dict[str, object]:
        target = self._require_target()
        if not symbols:
            self.last_read_metrics = {
                "symbol_count": 0,
                "block_count": 0,
                "byte_count": 0,
            }
            return {}

        plan = self._read_plan_for(symbols)
        values_by_key: dict[str, object] = {}
        byte_count = 0
        for block in plan:
            data = bytes(target.read_memory_block8(block.address, block.size))
            byte_count += len(data)
            for block_slice in block.slices:
                start = block_slice.offset
                end = start + block_slice.size
                values_by_key[block_slice.symbol.key] = decode_symbol_value(block_slice.symbol, data[start:end])

        self.last_read_metrics = {
            "symbol_count": len(symbols),
            "block_count": len(plan),
            "byte_count": byte_count,
        }
        return {symbol.key: values_by_key[symbol.key] for symbol in symbols if symbol.key in values_by_key}

    def write_symbol(self, symbol: SymbolInfo, value_text: str) -> object:
        if _is_readonly_symbol(symbol):
            raise ValueError(f"{symbol.name} 位于 {symbol.section}，默认按只读变量处理。")

        target = self._require_target()
        data = encode_symbol_value(symbol, value_text)
        target.write_memory_block8(symbol.address, list(data))
        return self.read_symbol(symbol)

    def reset(self, halt: bool = False) -> None:
        target = self._require_target()
        if halt:
            target.reset_and_halt()
        else:
            target.reset()

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

    def halt(self) -> None:
        self._require_target().halt()

    def resume(self) -> None:
        self._require_target().resume()

    def step(self) -> None:
        self._require_target().step()

    def debug_state(self) -> str:
        state = self._require_target().get_state()
        return str(getattr(state, "name", state)).lower()

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

    def read_core_registers(self) -> dict[str, int]:
        target = self._require_target()
        names = ["r0", "r1", "r2", "r3", "r12", "sp", "lr", "pc", "xpsr"]
        values = target.read_core_registers_raw(names)
        return {name: int(value) for name, value in zip(names, values)}

    def _require_target(self) -> Any:
        if self.target is None:
            raise RuntimeError("pyOCD 后端尚未连接。")
        return self.target

    def _read_plan_for(self, symbols: list[SymbolInfo]) -> tuple[_ReadBlock, ...]:
        signature = _read_plan_signature(symbols)
        if signature != self._read_plan_signature:
            self._read_plan_signature = signature
            self._read_plan = _build_coalesced_read_plan(
                symbols,
                max_gap_bytes=self.MAX_COALESCED_GAP_BYTES,
                max_block_bytes=self.MAX_COALESCED_READ_BYTES,
            )
        return self._read_plan


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


@dataclass(frozen=True)
class _ReadSlice:
    symbol: SymbolInfo
    offset: int
    size: int


@dataclass(frozen=True)
class _ReadBlock:
    address: int
    size: int
    slices: tuple[_ReadSlice, ...]


def _read_plan_signature(symbols: list[SymbolInfo]) -> tuple[tuple[int, int, str], ...]:
    return tuple(sorted((symbol.address, _access_size(symbol), symbol.key) for symbol in symbols))


def _build_coalesced_read_plan(
    symbols: list[SymbolInfo],
    *,
    max_gap_bytes: int,
    max_block_bytes: int,
) -> tuple[_ReadBlock, ...]:
    if not symbols:
        return ()

    sorted_symbols = sorted(symbols, key=lambda symbol: (symbol.address, symbol.key))
    blocks: list[_ReadBlock] = []
    current_address: int | None = None
    current_end = 0
    current_slices: list[_ReadSlice] = []

    def flush_current() -> None:
        nonlocal current_address, current_end, current_slices
        if current_address is None:
            return
        blocks.append(
            _ReadBlock(
                address=current_address,
                size=current_end - current_address,
                slices=tuple(current_slices),
            )
        )
        current_address = None
        current_end = 0
        current_slices = []

    for symbol in sorted_symbols:
        size = max(1, _access_size(symbol))
        start = symbol.address
        end = start + size
        if current_address is None:
            current_address = start
            current_end = end
            current_slices = [_ReadSlice(symbol=symbol, offset=0, size=size)]
            continue

        gap = start - current_end
        next_end = max(current_end, end)
        next_size = next_end - current_address
        if gap > max_gap_bytes or next_size > max_block_bytes:
            flush_current()
            current_address = start
            current_end = end
            current_slices = [_ReadSlice(symbol=symbol, offset=0, size=size)]
            continue

        current_slices.append(_ReadSlice(symbol=symbol, offset=start - current_address, size=size))
        current_end = next_end

    flush_current()
    return tuple(blocks)


def decode_symbol_value(symbol: SymbolInfo, data: bytes) -> object:
    type_name = _normalized_type(symbol)
    size = len(data)
    if _is_float_type(type_name, size):
        return struct.unpack("<f", data)[0]
    if _is_double_type(type_name, size):
        return struct.unpack("<d", data)[0]
    if _is_bool_type(type_name) and size == 1:
        return bool(data[0])
    if symbol.is_pointer or _is_integer_like_type(type_name, size):
        signed = False if symbol.is_pointer else _is_signed_integer_type(type_name)
        return int.from_bytes(data, "little", signed=signed)
    return " ".join(f"{byte:02X}" for byte in data)


def encode_symbol_value(symbol: SymbolInfo, value_text: str) -> bytes:
    type_name = _normalized_type(symbol)
    size = _access_size(symbol)
    text = value_text.strip()
    if not text:
        raise ValueError("写入值不能为空。")

    if _is_float_type(type_name, size):
        return struct.pack("<f", _finite_float(text))
    if _is_double_type(type_name, size):
        return struct.pack("<d", _finite_float(text))
    if _is_bool_type(type_name) and size == 1:
        return bytes([_parse_bool(text)])
    if symbol.is_pointer or _is_integer_like_type(type_name, size):
        value = _parse_int(text)
        signed = False if symbol.is_pointer else _is_signed_integer_type(type_name)
        min_value = -(1 << (size * 8 - 1)) if signed else 0
        max_value = (1 << (size * 8 - 1)) - 1 if signed else (1 << (size * 8)) - 1
        if not min_value <= value <= max_value:
            raise ValueError(f"写入值超出 {size} 字节变量范围：{value}")
        return int(value).to_bytes(size, "little", signed=signed)

    parsed_bytes = _parse_byte_sequence(text)
    if len(parsed_bytes) != size:
        raise ValueError(f"{symbol.name} 需要 {size} 字节，当前提供 {len(parsed_bytes)} 字节。")
    return parsed_bytes


def _access_size(symbol: SymbolInfo) -> int:
    if symbol.size > 0:
        return symbol.size
    type_name = _normalized_type(symbol)
    if "double" in type_name:
        return 8
    if "float" in type_name:
        return 4
    return 4


def _normalized_type(symbol: SymbolInfo) -> str:
    return symbol.kind.replace("volatile ", "").replace("const ", "").strip().lower()


def _is_float_type(type_name: str, size: int) -> bool:
    return size == 4 and type_name == "float"


def _is_double_type(type_name: str, size: int) -> bool:
    return size == 8 and ("double" in type_name)


def _is_bool_type(type_name: str) -> bool:
    return type_name in {"bool", "_bool", "boolean", "boolean_t"}


def _is_signed_integer_type(type_name: str) -> bool:
    if not type_name or type_name == "stt_object":
        return False
    if "unsigned" in type_name or type_name.startswith("u") or "uint" in type_name:
        return False
    if "char" in type_name and "signed" not in type_name:
        return False
    return any(token in type_name for token in ("int", "long", "short", "signed"))


def _is_integer_like_type(type_name: str, size: int) -> bool:
    if size not in (1, 2, 4, 8):
        return False
    if not type_name or type_name == "stt_object":
        return True
    if type_name.endswith("[]") or type_name.startswith(("struct ", "union ")):
        return False
    if type_name.endswith("*") or type_name.startswith("enum "):
        return True
    return any(token in type_name for token in ("int", "long", "short", "char", "size_t"))


def _is_readonly_symbol(symbol: SymbolInfo) -> bool:
    return symbol.section.startswith(".rodata")


def _finite_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("浮点写入值必须是有限数。")
    return value


def _parse_bool(text: str) -> int:
    lowered = text.lower()
    if lowered in {"1", "true", "on", "yes"}:
        return 1
    if lowered in {"0", "false", "off", "no"}:
        return 0
    raise ValueError(f"无法解析布尔值：{text}")


def _parse_int(text: str) -> int:
    return int(text.replace("_", ""), 0)


def _parse_byte_sequence(text: str) -> bytes:
    cleaned = text.replace(",", " ").replace(";", " ")
    values = []
    for part in cleaned.split():
        values.append(int(part, 0))
    if not all(0 <= value <= 0xFF for value in values):
        raise ValueError("字节序列中的每一项都必须在 0..255 范围内。")
    return bytes(values)
