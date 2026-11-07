from __future__ import annotations

import struct
import time
from dataclasses import dataclass
from .sample_timebase import SampleTimebase
from typing import Any

from take_a_look_backend.backends.typed_memory import decode_symbol_value
from take_a_look_backend.models import SymbolInfo, WatchedVariable


RTT_PLUS_CONFIG_CHANNEL = "JScope_Config"
RTT_PLUS_DATA_CHANNEL = "JScope_Data"
RTT_PLUS_TIMESTAMP_CHANNEL = "JScope_Data_t"
RTT_PLUS_RESPONSE_SIZE = 256
RTT_PLUS_RECORD = struct.Struct("<QI")
RTT_PLUS_SUPPORTED_SIZES = frozenset({1, 2, 4})


@dataclass(frozen=True)
class RttPlusPacket:
    timestamp_us: int | None
    values: tuple[object, ...]


class RttPlusStreamDecoder:
    def __init__(self, symbols: tuple[SymbolInfo, ...], *, timestamped: bool) -> None:
        self.symbols = symbols
        self.timestamped = timestamped
        self.packet_size = (4 if timestamped else 0) + sum(symbol.size for symbol in symbols)
        self._buffer = bytearray()

    def clear(self) -> None:
        self._buffer.clear()

    def feed(self, data: bytes) -> list[RttPlusPacket]:
        if data:
            self._buffer.extend(data)
        packets: list[RttPlusPacket] = []
        while len(self._buffer) >= self.packet_size:
            raw = bytes(self._buffer[: self.packet_size])
            del self._buffer[: self.packet_size]
            packets.append(self._decode_packet(raw))
        return packets

    def _decode_packet(self, raw: bytes) -> RttPlusPacket:
        offset = 0
        timestamp_us: int | None = None
        if self.timestamped:
            timestamp_us = int.from_bytes(raw[:4], "little", signed=False)
            offset = 4

        values: list[object] = []
        for symbol in self.symbols:
            field_data = raw[offset : offset + symbol.size]
            offset += symbol.size
            values.append(decode_symbol_value(symbol, field_data))
        return RttPlusPacket(timestamp_us=timestamp_us, values=tuple(values))


def build_rtt_plus_config(variables: list[WatchedVariable] | tuple[WatchedVariable, ...]) -> bytes:
    records = bytearray()
    for variable in variables:
        symbol = variable.symbol
        if symbol.is_rtt:
            continue
        if symbol.address <= 0:
            raise ValueError(f"RTT-Plus 变量 {symbol.name} 没有有效地址。")
        if symbol.size not in RTT_PLUS_SUPPORTED_SIZES:
            raise ValueError(f"RTT-Plus 变量 {symbol.name} 的大小为 {symbol.size}，仅支持 1、2、4 字节。")
        records.extend(RTT_PLUS_RECORD.pack(symbol.address, symbol.size))
    if not records:
        raise ValueError("RTT-Plus 至少需要一个已加入实时调参的 ELF 变量。")
    return bytes(records) + RTT_PLUS_RECORD.pack(0, 0)


class JScopeRttPlusBackend:
    START_TIMEOUT_S = 0.5
    RESPONSE_TIMEOUT_S = 1.0
    POLL_INTERVAL_S = 0.01
    NATIVE_READ_MAX_BYTES = 1024 * 1024

    def __init__(self, session_manager=None) -> None:
        from .rtt_session import RttSessionManager
        self._sessions = session_manager or RttSessionManager()
        self.control_block: Any | None = None
        self.up_channel: Any | None = None
        self.down_channel: Any | None = None
        self.channel_index = -1
        self.data_channel_name = ""
        self.decoder: RttPlusStreamDecoder | None = None
        self.symbols: tuple[SymbolInfo, ...] = ()
        self._timebase = SampleTimebase()
        self.transport_name = "pyOCD 内存 RTT"
        self._pending_data = b""
        self._previous_packet_size: int | None = None

    @property
    def is_started(self) -> bool:
        return self.up_channel is not None and self.down_channel is not None and self.decoder is not None

    def start(self, target: Any, control_block_address: int | None, probe: Any | None,
              variables: list[WatchedVariable]) -> tuple[SymbolInfo, ...]:
        self.stop()
        symbols = self._symbols_for_variables(variables)
        lease = self._sessions.open(target, control_block_address, probe)
        try:
            _, up = self._find_up_channel(lease.up_channels)
            _, down = self._find_down_channel(lease.down_channels)
            if up is None or down is None:
                raise RuntimeError("RTT-Plus 需要 JScope_Config 和 JScope_Data[_t] 通道。")
            up.claim()
            down.claim()
            self.transport_name = lease.transport_name
            return self._activate(lease, up.number, up, down.number, down, symbols)
        except BaseException:
            lease.close()
            self.stop()
            raise

    def stop(self) -> None:
        close_remote = getattr(self.control_block, "close", None)
        if callable(close_remote):
            close_remote()
        if self.decoder is not None and self.decoder.packet_size > 0:
            self._previous_packet_size = self.decoder.packet_size
        self.control_block = None
        self.up_channel = None
        self.down_channel = None
        self.channel_index = -1
        self.data_channel_name = ""
        self.decoder = None
        self.symbols = ()
        self._pending_data = b""
        self.transport_name = "pyOCD 内存 RTT"
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
        data = self._pending_data + bytes(self.up_channel.read())
        self._pending_data = b""
        frames: list[tuple[float, dict[str, object]]] = []
        for packet in self.decoder.feed(data):
            elapsed_s = self._elapsed_for_packet(packet, host_elapsed_s)
            values = {
                symbol.key: value
                for symbol, value in zip(self.symbols, packet.values, strict=True)
            }
            frames.append((elapsed_s, values))
        return frames

    def discard_available(self) -> None:
        self._pending_data = b""
        if self.up_channel is not None:
            self.up_channel.read()
        if self.decoder is not None:
            self.decoder.clear()

    def _activate(
        self,
        control_block: Any,
        up_index: int,
        up_channel: Any,
        down_index: int,
        down_channel: Any,
        symbols: tuple[SymbolInfo, ...],
    ) -> tuple[SymbolInfo, ...]:
        self.control_block = control_block
        self.channel_index = up_index
        self.up_channel = up_channel
        self.down_channel = down_channel
        self.data_channel_name = str(getattr(up_channel, "name", "") or "")
        self.symbols = symbols
        up_channel.read()
        config = build_rtt_plus_config([WatchedVariable(symbol, "") for symbol in symbols])
        self._write_config(config)
        response = bytearray()
        deadline = time.perf_counter() + self.RESPONSE_TIMEOUT_S
        response_offset: int | None = None
        while response_offset is None and time.perf_counter() < deadline:
            chunk = bytes(up_channel.read())
            if chunk:
                response.extend(chunk)
                response_offset = self._find_response_offset(response, self._previous_packet_size)
            else:
                time.sleep(self.POLL_INTERVAL_S)
        if response_offset is None:
            raise RuntimeError("RTT-Plus 等待目标端配置响应超时。")
        response_data = bytes(response[response_offset : response_offset + RTT_PLUS_RESPONSE_SIZE])
        if any(response_data):
            message = response_data.split(b"\0", 1)[0].decode("utf-8", "replace").strip()
            raise RuntimeError(message or "目标端拒绝 RTT-Plus 配置。")
        self._pending_data = bytes(response[response_offset + RTT_PLUS_RESPONSE_SIZE :])
        self.decoder = RttPlusStreamDecoder(symbols, timestamped=self.data_channel_name == RTT_PLUS_TIMESTAMP_CHANNEL)
        self.reset_timing()
        return symbols

    @staticmethod
    def _find_response_offset(data: bytearray, previous_packet_size: int | None = None) -> int | None:
        """Find the target response after any stale fixed-size data packets."""
        if len(data) < RTT_PLUS_RESPONSE_SIZE:
            return None
        alignment = max(1, previous_packet_size or 1)
        candidate_offsets = range(0, len(data) - RTT_PLUS_RESPONSE_SIZE + 1, alignment)
        for offset in candidate_offsets:
            candidate = bytes(data[offset : offset + RTT_PLUS_RESPONSE_SIZE])
            if not any(candidate):
                return offset
        for offset in range(0, len(data) - RTT_PLUS_RESPONSE_SIZE + 1, alignment):
            candidate = bytes(data[offset : offset + RTT_PLUS_RESPONSE_SIZE])
            if JScopeRttPlusBackend._is_error_response(candidate):
                return offset
        return None

    @staticmethod
    def _is_error_response(response: bytes) -> bool:
        first_nul = response.find(b"\0")
        if first_nul < 4:
            return False
        message = response[:first_nul]
        return all(byte in {9, 10, 13} or 32 <= byte < 127 for byte in message) and not any(
            response[first_nul:]
        )

    def _write_config(self, data: bytes) -> None:
        assert self.down_channel is not None
        result = self.down_channel.write(data, blocking=True)
        if result is not None and result < len(data):
            raise RuntimeError(f"RTT-Plus 配置只写入了 {result}/{len(data)} 字节。")

    @staticmethod
    def _symbols_for_variables(variables: list[WatchedVariable]) -> tuple[SymbolInfo, ...]:
        symbols = tuple(variable.symbol for variable in variables if not variable.symbol.is_rtt)
        if not symbols:
            raise ValueError("RTT-Plus 至少需要一个已加入实时调参的 ELF 变量。")
        if len({symbol.key for symbol in symbols}) != len(symbols):
            raise ValueError("RTT-Plus 配置中存在重复变量。")
        for symbol in symbols:
            if symbol.address <= 0 or symbol.size not in RTT_PLUS_SUPPORTED_SIZES:
                raise ValueError(f"RTT-Plus 不支持变量 {symbol.name}（地址或大小无效）。")
        return symbols

    @staticmethod
    def _find_up_channel(channels: Any) -> tuple[int, Any | None]:
        for index, channel in enumerate(channels):
            if getattr(channel, "name", "") in {RTT_PLUS_DATA_CHANNEL, RTT_PLUS_TIMESTAMP_CHANNEL}:
                return index, channel
        return -1, None

    @staticmethod
    def _find_down_channel(channels: Any) -> tuple[int, Any | None]:
        for index, channel in enumerate(channels):
            if getattr(channel, "name", "") == RTT_PLUS_CONFIG_CHANNEL:
                return index, channel
        return -1, None

    def _elapsed_for_packet(self, packet: RttPlusPacket, host_elapsed_s: float) -> float:
        return self._timebase.elapsed(packet.timestamp_us, host_elapsed_s)
