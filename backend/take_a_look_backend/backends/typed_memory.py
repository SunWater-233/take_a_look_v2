"""Typed memory codecs and coalesced reads shared by local and remote targets."""
from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field
from functools import lru_cache
from collections.abc import Sequence
from typing import Any

from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.backends.target_backend import RttBinding, TargetCapabilities


class TypedMemoryBackend:
    MAX_COALESCED_READ_BYTES = 512
    MAX_COALESCED_GAP_BYTES = 16
    capabilities = TargetCapabilities()

    def __init__(self) -> None:
        self.target: Any | None = None
        self.last_connect_timings: dict[str, float] = {}
        self.last_read_metrics: dict[str, int] = {
            "symbol_count": 0, "block_count": 0, "byte_count": 0,
        }
        self._read_plan_signature: tuple[SymbolInfo, ...] | None = None
        self._read_plan: tuple[_ReadBlock, ...] = ()
        self._read_keys: tuple[str, ...] = ()
        self._read_plans: list[tuple[tuple[SymbolInfo, ...], tuple[_ReadBlock, ...]]] = []

    @property
    def probe(self) -> Any | None:
        return None

    @property
    def rtt_binding(self) -> RttBinding:
        return RttBinding(getattr(self, "rtt_target", self.target), self.probe)

    @property
    def supports_running_memory(self) -> bool:
        return self.capabilities.memory_sampling

    @property
    def supports_memory_write(self) -> bool:
        return self.capabilities.memory_write

    @property
    def supports_rtt(self) -> bool:
        return self.capabilities.rtt

    @property
    def manages_breakpoint_step(self) -> bool:
        return self.capabilities.manages_breakpoint_step

    def _require_target(self) -> Any:
        if self.target is None:
            raise RuntimeError("目标后端尚未连接。")
        return self.target

    def program_firmware(self, path: str, progress) -> None:
        raise ProtocolError("download_unsupported", "当前连接不支持固件下载。")

    def read_symbol(self, symbol: SymbolInfo) -> object:
        target = self._require_target()
        size = _access_size(symbol)
        data = bytes(target.read_memory_block8(symbol.address, size))
        _check_read_size(data, size)
        return decode_symbol_value(symbol, data)

    def read_symbols(self, symbols: Sequence[SymbolInfo]) -> dict[str, object]:
        self._require_target()
        if not symbols:
            self.last_read_metrics = {
                "symbol_count": 0,
                "block_count": 0,
                "byte_count": 0,
            }
            return {}

        plan = self._read_plan_for(symbols)
        # Seeding once preserves caller order without rebuilding a second dict.
        values_by_key = dict.fromkeys(self._read_keys)
        byte_count = 0
        for block, data in zip(plan, self._read_blocks(plan), strict=True):
            _check_read_size(data, block.size)
            byte_count += len(data)
            block.decode(data, values_by_key)

        self.last_read_metrics = {
            "symbol_count": len(symbols),
            "block_count": len(plan),
            "byte_count": byte_count,
        }
        return values_by_key

    def _read_blocks(self, plan: tuple[_ReadBlock, ...]):
        target = self._require_target()
        for block in plan:
            yield bytes(target.read_memory_block8(block.address, block.size))

    def write_symbol(self, symbol: SymbolInfo, value_text: str) -> object:
        if _is_readonly_symbol(symbol):
            raise ValueError(f"{symbol.name} 位于 {symbol.section}，默认按只读变量处理。")

        target = self._require_target()
        data = encode_symbol_value(symbol, value_text)
        target.write_memory_block8(symbol.address, list(data))
        return self.read_symbol(symbol)

    def write_symbols(self, writes: Sequence[tuple[SymbolInfo, str]]) -> dict[str, object]:
        """Validate first; merge only adjacent bytes in the requested write order."""
        prepared = []
        keys = set()
        for symbol, value_text in writes:
            if _is_readonly_symbol(symbol):
                raise ValueError(f"{symbol.name} 位于 {symbol.section}，默认按只读变量处理。")
            if symbol.key in keys:
                raise ValueError("一次批量写入不能包含重复变量。")
            keys.add(symbol.key)
            prepared.append((symbol, encode_symbol_value(symbol, value_text)))
        target = self._require_target()
        address = 0
        data = bytearray()
        for symbol, encoded in prepared:
            if data and (address + len(data) != symbol.address or
                         len(data) + len(encoded) > self.MAX_COALESCED_READ_BYTES):
                target.write_memory_block8(address, list(data))
                data.clear()
            if not data:
                address = symbol.address
            data.extend(encoded)
        if data:
            target.write_memory_block8(address, list(data))
        return self.read_symbols(tuple(symbol for symbol, _ in prepared))

    def reset(self, halt: bool = False) -> None:
        target = self._require_target()
        if halt:
            target.reset_and_halt()
        else:
            target.reset()

    def halt(self) -> None:
        self._require_target().halt()

    def resume(self) -> None:
        self._require_target().resume()

    def step(self) -> None:
        self._require_target().step()

    def debug_state(self) -> str:
        state = self._require_target().get_state()
        return str(getattr(state, "name", state)).lower()

    def read_core_registers(self) -> dict[str, int]:
        target = self._require_target()
        names = ["r0", "r1", "r2", "r3", "r12", "sp", "lr", "pc", "xpsr"]
        values = target.read_core_registers_raw(names)
        return {name: int(value) for name, value in zip(names, values)}

    def _clear_read_plans(self) -> None:
        self._read_plan_signature = None
        self._read_plan = ()
        self._read_keys = ()
        self._read_plans.clear()

    def _read_plan_for(self, symbols: Sequence[SymbolInfo]) -> tuple[_ReadBlock, ...]:
        signature = tuple(symbols)
        if signature != self._read_plan_signature:
            self._read_plan_signature = signature
            self._read_keys = tuple(symbol.key for symbol in signature)
            for index, (cached, plan) in enumerate(self._read_plans):
                if signature == cached:
                    self._read_plan = plan
                    self._read_plans.insert(0, self._read_plans.pop(index))
                    break
            else:
                self._read_plan = _build_coalesced_read_plan(
                    signature, max_gap_bytes=self.MAX_COALESCED_GAP_BYTES,
                    max_block_bytes=self.MAX_COALESCED_READ_BYTES,
                    can_merge=self._can_merge_read_range)
                self._read_plans.insert(0, (signature, self._read_plan))
                del self._read_plans[8:]
        return self._read_plan

    def _can_merge_read_range(self, address: int, end: int) -> bool:
        return True


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
    _codec: struct.Struct | None = field(init=False, repr=False, compare=False)
    _fields: tuple = field(init=False, repr=False, compare=False)

    def __post_init__(self):
        formats, fields, cursor = [], [], 0
        overlap = False
        for part in self.slices:
            codec, conversion = _value_codec(part.symbol, part.size)
            if part.offset < cursor:
                overlap = True
            formats.append(f"{max(0, part.offset - cursor)}x" + codec.format[1:])
            cursor = part.offset + part.size
            fields.append((part.symbol.key, part.offset, codec, conversion))
        formats.append(f"{max(0, self.size - cursor)}x")
        object.__setattr__(self, "_codec", None if overlap else struct.Struct("<" + "".join(formats)))
        object.__setattr__(self, "_fields", tuple(fields))

    def decode(self, data: bytes, values: dict) -> None:
        if self._codec is not None:
            decoded = self._codec.unpack(data)
            for (key, _, _, conversion), value in zip(self._fields, decoded):
                values[key] = conversion(value) if conversion else value
        else:
            for key, offset, codec, conversion in self._fields:
                value = codec.unpack_from(data, offset)[0]
                values[key] = conversion(value) if conversion else value


def _read_plan_signature(symbols: list[SymbolInfo]) -> tuple[tuple[int, int, str], ...]:
    return tuple(sorted((symbol.address, _access_size(symbol), symbol.key) for symbol in symbols))


def _build_coalesced_read_plan(
    symbols: Sequence[SymbolInfo],
    *,
    max_gap_bytes: int,
    max_block_bytes: int,
    can_merge=None,
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
        if (gap > max_gap_bytes or next_size > max_block_bytes or
                (gap > 0 and can_merge is not None and not can_merge(current_address, next_end))):
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
    codec, conversion = _value_codec(symbol, len(data))
    value = codec.unpack(data)[0]
    return conversion(value) if conversion else value


def _hex_value(data: bytes) -> str:
    return data.hex(" ").upper()


def _unsigned_value(data: bytes) -> int:
    return int.from_bytes(data, "little")


@lru_cache(maxsize=2048)
def _value_codec(symbol: SymbolInfo, size: int):
    type_name = _normalized_type(symbol)
    if _is_float_type(type_name, size):
        return struct.Struct("<f"), None
    if _is_double_type(type_name, size):
        return struct.Struct("<d"), None
    if _is_bool_type(type_name) and size == 1:
        return struct.Struct("<?"), None
    if symbol.is_pointer or _is_integer_like_type(type_name, size):
        signed = False if symbol.is_pointer else _is_signed_integer_type(type_name)
        if size in (1, 2, 4, 8):
            code = {1: "b", 2: "h", 4: "i", 8: "q"}[size]
            return struct.Struct("<" + (code if signed else code.upper())), None
        return struct.Struct(f"<{size}s"), _unsigned_value
    return struct.Struct(f"<{size}s"), _hex_value


def _check_read_size(data: bytes, expected: int) -> None:
    if len(data) != expected:
        raise ValueError(f"内存读取不完整：需要 {expected} 字节，实际收到 {len(data)} 字节。")


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
