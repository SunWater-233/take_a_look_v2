from __future__ import annotations

import struct
import time
from dataclasses import dataclass
from numbers import Real
from typing import Any

from take_a_look_backend.backends.j_scope_rtt import _connect_native_jlink_target, _find_native_jlink
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

    def __init__(self) -> None:
        self.control_block: Any | None = None
        self.up_channel: Any | None = None
        self.down_channel: Any | None = None
        self.channel_index = -1
        self.data_channel_name = ""
        self.decoder: RttPlusStreamDecoder | None = None
        self.symbols: tuple[SymbolInfo, ...] = ()
        self.nominal_rate_hz = 1000.0
        self.transport_name = "pyOCD 内存 RTT"
        self._native_jlink: Any | None = None
        self._pending_data = b""
        self._previous_packet_size: int | None = None
        self._first_target_timestamp_us: int | None = None
        self._last_target_timestamp_us: int | None = None
        self._timestamp_wraps = 0
        self._host_time_origin_s: float | None = None
        self._next_untimed_elapsed_s: float | None = None

    @property
    def is_started(self) -> bool:
        return self.up_channel is not None and self.down_channel is not None and self.decoder is not None

    def start(
        self,
        target: Any,
        control_block_address: int | None,
        probe: Any | None,
        variables: list[WatchedVariable],
    ) -> tuple[SymbolInfo, ...]:
        self.stop()
        symbols = self._symbols_for_variables(variables)
        open_remote = getattr(target, "open_rtt", None)
        if callable(open_remote):
            control_block = open_remote(control_block_address)
            try:
                up_index, up_channel = self._find_up_channel(control_block.up_channels)
                down_index, down_channel = self._find_down_channel(control_block.down_channels)
                if up_channel is None or down_channel is None:
                    raise RuntimeError("手机 RTT-Plus 需要 JScope_Config 和 JScope_Data[_t] 通道。")
                self.transport_name = control_block.transport_name
                return self._activate(control_block, up_channel.number, up_channel,
                                      down_channel.number, down_channel, symbols)
            except Exception:
                control_block.close()
                self.stop()
                raise
        native_jlink = _find_native_jlink(probe, require_down=True)
        if native_jlink is not None:
            try:
                return self._start_native_jlink(native_jlink, target, control_block_address, symbols)
            except Exception:
                self.stop()
                raise

        from pyocd.debug.rtt import RTTControlBlock

        if control_block_address is None:
            control_block = RTTControlBlock.from_target(target)
        else:
            control_block = RTTControlBlock.from_target(target, address=control_block_address)
        control_block.start()
        up_index, up_channel = self._find_up_channel(control_block.up_channels)
        down_index, down_channel = self._find_down_channel(control_block.down_channels)
        if up_channel is None or down_channel is None:
            raise RuntimeError("RTT-Plus 需要 JScope_Config Down 通道和 JScope_Data[_t] Up 通道。")
        self.transport_name = "pyOCD 内存 RTT"
        return self._activate(control_block, up_index, up_channel, down_index, down_channel, symbols)

    def stop(self) -> None:
        close_remote = getattr(self.control_block, "close", None)
        if callable(close_remote):
            close_remote()
        if self.decoder is not None and self.decoder.packet_size > 0:
            self._previous_packet_size = self.decoder.packet_size
        native_jlink = self._native_jlink
        self._native_jlink = None
        if native_jlink is not None:
            try:
                native_jlink.rtt_stop()
            except Exception:
                pass
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

    def _start_native_jlink(
        self,
        native_jlink: Any,
        target: Any,
        control_block_address: int | None,
        symbols: tuple[SymbolInfo, ...],
    ) -> tuple[SymbolInfo, ...]:
        _connect_native_jlink_target(native_jlink, target)
        native_jlink.rtt_start(control_block_address)
        self._native_jlink = native_jlink
        deadline = time.perf_counter() + self.START_TIMEOUT_S
        last_error: Exception | None = None
        while True:
            try:
                up_count = int(native_jlink.rtt_get_num_up_buffers())
                down_count = int(native_jlink.rtt_get_num_down_buffers())
                if up_count > 0 and down_count > 0:
                    break
            except Exception as exc:
                last_error = exc
            if time.perf_counter() >= deadline:
                self.stop()
                raise RuntimeError("J-Link 原生 RTT 尚未找到 RTT-Plus 通道。") from last_error
            time.sleep(self.POLL_INTERVAL_S)

        up_index = -1
        up_channel: Any | None = None
        for channel_index in range(up_count):
            descriptor = native_jlink.rtt_get_buf_descriptor(channel_index, True)
            channel_name = str(getattr(descriptor, "name", "") or "")
            if channel_name in {RTT_PLUS_DATA_CHANNEL, RTT_PLUS_TIMESTAMP_CHANNEL}:
                up_index = channel_index
                up_channel = _NativeJLinkUpChannelPlus(
                    native_jlink,
                    channel_index,
                    channel_name,
                    int(getattr(descriptor, "SizeOfBuffer", 0)),
                    self.NATIVE_READ_MAX_BYTES,
                )
                break

        down_index = -1
        down_channel: Any | None = None
        for channel_index in range(down_count):
            descriptor = native_jlink.rtt_get_buf_descriptor(channel_index, False)
            channel_name = str(getattr(descriptor, "name", "") or "")
            if channel_name == RTT_PLUS_CONFIG_CHANNEL:
                down_index = channel_index
                down_channel = _NativeJLinkDownChannelPlus(native_jlink, channel_index)
                break

        if up_channel is None or down_channel is None:
            self.stop()
            raise RuntimeError("J-Link 原生 RTT 已连接，但没有 JScope_Config/JScope_Data[_t] 通道。")
        self.transport_name = "J-Link 原生 RTT"
        return self._activate(native_jlink, up_index, up_channel, down_index, down_channel, symbols)

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


class _NativeJLinkUpChannelPlus:
    def __init__(self, link: Any, channel_index: int, name: str, size: int, max_read_bytes: int) -> None:
        self._link = link
        self._channel_index = channel_index
        self.name = name
        self.size = size
        self._max_read_bytes = max(max_read_bytes, size, 1)

    def read(self) -> bytes:
        return bytes(self._link.rtt_read(self._channel_index, self._max_read_bytes))


class _NativeJLinkDownChannelPlus:
    def __init__(self, link: Any, channel_index: int) -> None:
        self._link = link
        self._channel_index = channel_index
        self.name = RTT_PLUS_CONFIG_CHANNEL

    def write(self, data: bytes, blocking: bool = False) -> int | None:
        if not blocking:
            return int(self._link.rtt_write(self._channel_index, list(data)))
        remaining = data
        total = 0
        deadline = time.perf_counter() + 2.0
        while remaining:
            written = int(self._link.rtt_write(self._channel_index, list(remaining)))
            if written > 0:
                total += written
                remaining = remaining[written:]
                continue
            if time.perf_counter() >= deadline:
                return total
            time.sleep(0.005)
        return total
