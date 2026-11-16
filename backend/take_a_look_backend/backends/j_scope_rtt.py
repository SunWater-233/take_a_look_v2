from __future__ import annotations

import re
import struct
import time
from dataclasses import dataclass
from .sample_timebase import SampleTimebase
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

    def __init__(self, session_manager=None) -> None:
        from .rtt_session import RttSessionManager
        self._sessions = session_manager or RttSessionManager()
        self.control_block: Any | None = None
        self.up_channel: Any | None = None
        self.channel_index = -1
        self.data_format: JScopeFormat | None = None
        self.decoder: JScopeStreamDecoder | None = None
        self.symbols: tuple[SymbolInfo, ...] = ()
        self._timebase = SampleTimebase()
        self.transport_name = "pyOCD 内存 RTT"

    @property
    def is_started(self) -> bool:
        return self.up_channel is not None and self.decoder is not None

    def start(self, target: Any, control_block_address: int | None = None,
              probe: Any | None = None) -> tuple[SymbolInfo, ...]:
        self.stop()
        lease = self._sessions.open(target, control_block_address, probe)
        try:
            for channel in lease.up_channels:
                try:
                    data_format = parse_j_scope_channel_name(channel.name or "")
                except ValueError:
                    continue
                channel.claim()
                self.transport_name = lease.transport_name
                symbols = self._activate_channel(lease, channel, channel.number, data_format)
                if lease.native:
                    self._discard_native_startup_backlog(channel)
                return symbols
            raise RuntimeError("已找到 RTT 控制块，但没有名为 JScope_<FORMAT> 的 Up Channel。")
        except BaseException:
            lease.close()
            self.stop()
            raise

    def stop(self) -> None:
        close_remote = getattr(self.control_block, "close", None)
        if callable(close_remote):
            close_remote()
        self.control_block = None
        self.up_channel = None
        self.channel_index = -1
        self.data_format = None
        self.decoder = None
        self.symbols = ()
        self.transport_name = "pyOCD 内存 RTT"
        self.reset_timing()

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
        configure = getattr(channel, "set_frame_bytes", None)
        if callable(configure):
            configure(data_format.packet_size)
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

    @property
    def nominal_rate_hz(self) -> float:
        return self._timebase.nominal_rate_hz

    def set_nominal_rate_hz(self, rate_hz: float) -> None:
        self._timebase.set_rate(rate_hz)

    def reset_timing(self) -> None:
        if self.decoder is not None:
            self.decoder.clear()
        self._timebase.reset()

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
        return self._timebase.elapsed(packet.timestamp_us, host_elapsed_s)


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
