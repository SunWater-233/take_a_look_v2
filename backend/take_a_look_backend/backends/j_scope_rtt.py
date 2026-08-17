from __future__ import annotations

import re
import struct
import time
from dataclasses import dataclass
from numbers import Real
from typing import Any, Literal, cast

from take_a_look_backend.models import SymbolInfo


_CHANNEL_PATTERN = re.compile(r"^JScope_((?:[tbfiu][124])+)$", re.IGNORECASE)
_FIELD_PATTERN = re.compile(r"([tbfiu])([124])", re.IGNORECASE)
_SUPPORTED_SIZES = {
    "t": {4},
    "b": {1},
    "f": {4},
    "i": {1, 2, 4},
    "u": {1, 2, 4},
}


@dataclass(frozen=True)
class JScopeField:
    type_code: str
    size: int

    @property
    def kind(self) -> str:
        if self.type_code == "b":
            return "bool"
        if self.type_code == "f":
            return "float"
        if self.type_code == "i":
            return f"int{self.size * 8}_t"
        if self.type_code == "u":
            return f"uint{self.size * 8}_t"
        return "timestamp_us"


@dataclass(frozen=True)
class JScopeFormat:
    channel_name: str
    fields: tuple[JScopeField, ...]

    @property
    def packet_size(self) -> int:
        return sum(field.size for field in self.fields)

    @property
    def has_timestamp(self) -> bool:
        return bool(self.fields) and self.fields[0].type_code == "t"

    @property
    def data_fields(self) -> tuple[JScopeField, ...]:
        return self.fields[1:] if self.has_timestamp else self.fields


@dataclass(frozen=True)
class JScopePacket:
    timestamp_us: int | None
    values: tuple[object, ...]


def parse_j_scope_channel_name(name: str) -> JScopeFormat:
    match = _CHANNEL_PATTERN.fullmatch(name.strip())
    if match is None:
        raise ValueError(f"RTT 通道名不是受支持的 J-Scope 格式：{name}")

    encoded = match.group(1)
    fields = tuple(JScopeField(type_code.lower(), int(size)) for type_code, size in _FIELD_PATTERN.findall(encoded))
    if not fields or "".join(f"{field.type_code}{field.size}" for field in fields).casefold() != encoded.casefold():
        raise ValueError(f"J-Scope RTT 格式不完整：{name}")
    if len(fields) > 12:
        raise ValueError("J-Scope RTT 每包最多支持 12 个字段（含时间戳）。")
    if any(field.size not in _SUPPORTED_SIZES[field.type_code] for field in fields):
        raise ValueError(f"J-Scope RTT 通道包含不受支持的字段：{name}")
    if any(field.type_code == "t" for field in fields[1:]):
        raise ValueError("J-Scope RTT 时间戳 t4 只能是数据包的第一个字段。")
    data_format = JScopeFormat(channel_name=name, fields=fields)
    if not data_format.data_fields:
        raise ValueError("J-Scope RTT 数据包至少需要一个数据字段。")
    return data_format


class JScopeStreamDecoder:
    def __init__(self, data_format: JScopeFormat, *, byte_order: str = "little") -> None:
        if byte_order not in {"little", "big"}:
            raise ValueError(f"不支持的字节序：{byte_order}")
        self.data_format = data_format
        self.byte_order: Literal["little", "big"] = cast(Literal["little", "big"], byte_order)
        self._buffer = bytearray()

    def clear(self) -> None:
        self._buffer.clear()

    def feed(self, data: bytes) -> list[JScopePacket]:
        if data:
            self._buffer.extend(data)
        packet_size = self.data_format.packet_size
        packets: list[JScopePacket] = []
        while len(self._buffer) >= packet_size:
            raw = bytes(self._buffer[:packet_size])
            del self._buffer[:packet_size]
            packets.append(self._decode_packet(raw))
        return packets

    def _decode_packet(self, raw: bytes) -> JScopePacket:
        offset = 0
        timestamp_us: int | None = None
        values: list[object] = []
        for field in self.data_format.fields:
            field_data = raw[offset : offset + field.size]
            offset += field.size
            value = _decode_field(field, field_data, self.byte_order)
            if field.type_code == "t":
                timestamp_us = int(value)
            else:
                values.append(value)
        return JScopePacket(timestamp_us=timestamp_us, values=tuple(values))


class JScopeRttBackend:
    NATIVE_START_TIMEOUT_S = 0.5
    NATIVE_START_POLL_S = 0.01
    NATIVE_START_DRAIN_S = 0.25
    NATIVE_READ_MAX_BYTES = 1024 * 1024

    def __init__(self) -> None:
        self.control_block: Any | None = None
        self.up_channel: Any | None = None
        self.channel_index = -1
        self.data_format: JScopeFormat | None = None
        self.decoder: JScopeStreamDecoder | None = None
        self.symbols: tuple[SymbolInfo, ...] = ()
        self.nominal_rate_hz = 1000.0
        self.transport_name = "pyOCD 内存 RTT"
        self._native_jlink: Any | None = None
        self._first_target_timestamp_us: int | None = None
        self._last_target_timestamp_us: int | None = None
        self._timestamp_wraps = 0
        self._host_time_origin_s: float | None = None
        self._next_untimed_elapsed_s: float | None = None

    @property
    def is_started(self) -> bool:
        return self.up_channel is not None and self.decoder is not None

    def start(
        self,
        target: Any,
        control_block_address: int | None = None,
        probe: Any | None = None,
    ) -> tuple[SymbolInfo, ...]:
        self.stop()
        native_jlink = _find_native_jlink(probe)
        if native_jlink is not None:
            return self._start_native_jlink(native_jlink, target, control_block_address)

        from pyocd.debug.rtt import RTTControlBlock

        if control_block_address is None:
            control_block = RTTControlBlock.from_target(target)
        else:
            control_block = RTTControlBlock.from_target(target, address=control_block_address)
        control_block.start()
        for channel_index, channel in enumerate(control_block.up_channels):
            channel_name = channel.name or ""
            try:
                data_format = parse_j_scope_channel_name(channel_name)
            except ValueError:
                continue
            self.transport_name = "pyOCD 内存 RTT"
            return self._activate_channel(control_block, channel, channel_index, data_format)
        raise RuntimeError("已找到 RTT 控制块，但没有名为 JScope_<FORMAT> 的 Up Channel。")

    def stop(self) -> None:
        native_jlink = self._native_jlink
        self._native_jlink = None
        if native_jlink is not None:
            try:
                native_jlink.rtt_stop()
            except Exception:
                pass
        self.control_block = None
        self.up_channel = None
        self.channel_index = -1
        self.data_format = None
        self.decoder = None
        self.symbols = ()
        self.transport_name = "pyOCD 内存 RTT"
        self.reset_timing()

    def _start_native_jlink(
        self,
        native_jlink: Any,
        target: Any,
        control_block_address: int | None,
    ) -> tuple[SymbolInfo, ...]:
        _connect_native_jlink_target(native_jlink, target)
        native_jlink.rtt_start(control_block_address)
        self._native_jlink = native_jlink
        deadline = time.perf_counter() + self.NATIVE_START_TIMEOUT_S
        last_error: Exception | None = None
        while True:
            try:
                channel_count = int(native_jlink.rtt_get_num_up_buffers())
                if channel_count > 0:
                    break
            except Exception as exc:
                last_error = exc
            if time.perf_counter() >= deadline:
                self.stop()
                detail = f"：{last_error}" if last_error is not None else ""
                raise RuntimeError(f"J-Link 原生 RTT 尚未找到控制块{detail}") from last_error
            time.sleep(self.NATIVE_START_POLL_S)

        for channel_index in range(channel_count):
            descriptor = native_jlink.rtt_get_buf_descriptor(channel_index, True)
            channel_name = str(getattr(descriptor, "name", "") or "")
            try:
                data_format = parse_j_scope_channel_name(channel_name)
            except ValueError:
                continue
            channel = _NativeJLinkUpChannel(
                native_jlink,
                channel_index,
                channel_name,
                int(getattr(descriptor, "SizeOfBuffer", 0)),
                self.NATIVE_READ_MAX_BYTES,
            )
            self.transport_name = "J-Link 原生 RTT"
            symbols = self._activate_channel(native_jlink, channel, channel_index, data_format)
            self._discard_native_startup_backlog(channel)
            return symbols

        self.stop()
        raise RuntimeError("J-Link 原生 RTT 已连接，但没有名为 JScope_<FORMAT> 的 Up Channel。")

    def _activate_channel(
        self,
        control_block: Any,
        channel: Any,
        channel_index: int,
        data_format: JScopeFormat,
    ) -> tuple[SymbolInfo, ...]:
        self.control_block = control_block
        self.up_channel = channel
        self.channel_index = channel_index
        self.data_format = data_format
        self.decoder = JScopeStreamDecoder(data_format)
        self.symbols = _symbols_for_format(channel_index, data_format)
        self.reset_timing()
        return self.symbols

    def _discard_native_startup_backlog(self, channel: Any) -> None:
        deadline = time.perf_counter() + self.NATIVE_START_DRAIN_S
        while time.perf_counter() < deadline:
            channel.read()
            time.sleep(self.NATIVE_START_POLL_S)
        self.reset_timing()

    def set_nominal_rate_hz(self, rate_hz: float) -> None:
        if isinstance(rate_hz, Real) and not isinstance(rate_hz, bool):
            self.nominal_rate_hz = max(1.0, float(rate_hz))

    def reset_timing(self) -> None:
        if self.decoder is not None:
            self.decoder.clear()
        self._first_target_timestamp_us = None
        self._last_target_timestamp_us = None
        self._timestamp_wraps = 0
        self._host_time_origin_s = None
        self._next_untimed_elapsed_s = None

    def read_frames(self, host_elapsed_s: float) -> list[tuple[float, dict[str, object]]]:
        if self.up_channel is None or self.decoder is None:
            return []
        packets = self.decoder.feed(self.up_channel.read())
        frames: list[tuple[float, dict[str, object]]] = []
        for packet in packets:
            elapsed_s = self._elapsed_for_packet(packet, host_elapsed_s)
            values = {
                symbol.key: value
                for symbol, value in zip(self.symbols, packet.values, strict=True)
            }
            frames.append((elapsed_s, values))
        return frames

    def discard_available(self) -> None:
        if self.up_channel is not None:
            self.up_channel.read()
        if self.decoder is not None:
            self.decoder.clear()

    def _elapsed_for_packet(self, packet: JScopePacket, host_elapsed_s: float) -> float:
        if packet.timestamp_us is not None:
            timestamp_us = packet.timestamp_us
            if self._last_target_timestamp_us is not None and timestamp_us < self._last_target_timestamp_us:
                if self._last_target_timestamp_us - timestamp_us > 0x80000000:
                    self._timestamp_wraps += 1
            self._last_target_timestamp_us = timestamp_us
            unwrapped = timestamp_us + self._timestamp_wraps * 0x100000000
            if self._first_target_timestamp_us is None:
                self._first_target_timestamp_us = unwrapped
                self._host_time_origin_s = host_elapsed_s
            assert self._host_time_origin_s is not None
            return self._host_time_origin_s + (unwrapped - self._first_target_timestamp_us) / 1_000_000.0

        if self._next_untimed_elapsed_s is None:
            self._next_untimed_elapsed_s = host_elapsed_s
        elapsed_s = self._next_untimed_elapsed_s
        self._next_untimed_elapsed_s += 1.0 / max(1.0, self.nominal_rate_hz)
        return elapsed_s


def _symbols_for_format(channel_index: int, data_format: JScopeFormat) -> tuple[SymbolInfo, ...]:
    symbols: list[SymbolInfo] = []
    for field_index, field in enumerate(data_format.data_fields, start=1):
        source_id = f"{channel_index}:{data_format.channel_name}:{field_index}"
        symbols.append(
            SymbolInfo(
                name=f"RTT Data {field_index} ({field.kind})",
                address=0,
                size=field.size,
                kind=field.kind,
                section="RTT",
                source_file=f"RTT 数据/{data_format.channel_name}",
                data_source="rtt",
                source_id=source_id,
            )
        )
    return tuple(symbols)


class _NativeJLinkUpChannel:
    def __init__(
        self,
        link: Any,
        channel_index: int,
        name: str,
        size: int,
        max_read_bytes: int,
    ) -> None:
        self._link = link
        self._channel_index = channel_index
        self.name = name
        self.size = size
        self._max_read_bytes = max(max_read_bytes, size, 1)

    def read(self) -> bytes:
        return bytes(self._link.rtt_read(self._channel_index, self._max_read_bytes))


def _find_native_jlink(probe: Any | None, *, require_down: bool = False) -> Any | None:
    candidate = probe
    seen: set[int] = set()
    while candidate is not None and id(candidate) not in seen:
        seen.add(id(candidate))
        link = getattr(candidate, "_link", None)
        required_methods = (
            "rtt_start",
            "rtt_stop",
            "rtt_get_num_up_buffers",
            "rtt_get_buf_descriptor",
            "rtt_read",
        )
        if require_down:
            required_methods += ("rtt_get_num_down_buffers", "rtt_write")
        if link is not None and all(callable(getattr(link, method, None)) for method in required_methods):
            return link
        nested = getattr(candidate, "probe", None)
        candidate = nested if nested is not candidate else None
    return None


def _connect_native_jlink_target(link: Any, target: Any) -> None:
    target_connected = getattr(link, "target_connected", None)
    if not callable(target_connected) or target_connected():
        return

    selected_core = getattr(target, "selected_core", None)
    core_name = str(getattr(selected_core, "name", "") or "").strip()
    connect = getattr(link, "connect", None)
    if not core_name or not callable(connect):
        raise RuntimeError("J-Link 原生 RTT 无法确定目标核心型号。")
    connect(core_name)


def _decode_field(
    field: JScopeField,
    data: bytes,
    byte_order: Literal["little", "big"],
) -> bool | float | int:
    if field.type_code == "b":
        return bool(data[0])
    if field.type_code == "f":
        return struct.unpack("<f" if byte_order == "little" else ">f", data)[0]
    if field.type_code == "i":
        return int.from_bytes(data, byte_order, signed=True)
    return int.from_bytes(data, byte_order, signed=False)
