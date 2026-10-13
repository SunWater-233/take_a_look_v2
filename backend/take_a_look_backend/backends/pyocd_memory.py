from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from time import perf_counter
from typing import Any

from take_a_look_backend.models import SymbolInfo


@dataclass(frozen=True)
class PyOcdConnectionConfig:
    target: str | None
    frequency_hz: int
    unique_id: str | None = None
    probe_filter: str | None = None
    connect_mode: str = "attach"


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
        session = Session(probe, auto_open=False, options=options)
        open_started = perf_counter()
        try:
            session.open()
            timings["session_open_s"] = perf_counter() - open_started
        except Exception:
            timings["session_open_s"] = perf_counter() - open_started
            timings["total_s"] = perf_counter() - total_started
            self.last_connect_timings = timings
            session.close()
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
        if session is not None:
            session.close()

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
        from pyocd.flash.file_programmer import FileProgrammer
        self._require_target()
        FileProgrammer(self.session, progress=progress, chip_erase="sector", trust_crc=False).program(path, file_format="elf")
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
