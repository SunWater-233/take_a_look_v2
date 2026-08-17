from __future__ import annotations

import struct
import unittest

from take_a_look_backend.backends.rtt_plus import (
    JScopeRttPlusBackend,
    RTT_PLUS_RECORD,
    RTT_PLUS_RESPONSE_SIZE,
    RTT_PLUS_TIMESTAMP_CHANNEL,
    RttPlusStreamDecoder,
    build_rtt_plus_config,
)
from take_a_look_backend.models import SymbolInfo, WatchedVariable


class _UpChannel:
    def __init__(self, *chunks: bytes, name: str = RTT_PLUS_TIMESTAMP_CHANNEL) -> None:
        self.name = name
        self._chunks = list(chunks)

    def read(self) -> bytes:
        return self._chunks.pop(0) if self._chunks else b""


class _DownChannel:
    name = "JScope_Config"

    def __init__(self) -> None:
        self.writes: list[tuple[bytes, bool]] = []

    def write(self, data: bytes, blocking: bool = False) -> int:
        self.writes.append((bytes(data), blocking))
        return len(data)


class _Descriptor:
    def __init__(self, name: str, size: int = 2048) -> None:
        self.name = name
        self.SizeOfBuffer = size


class _NativeLink:
    def __init__(self, response: bytes) -> None:
        self._reads = [b"", response]
        self.writes: list[tuple[int, bytes]] = []
        self.started = False

    def target_connected(self) -> bool:
        return True

    def rtt_start(self, _address: int | None) -> None:
        self.started = True

    def rtt_stop(self) -> None:
        self.started = False

    def rtt_get_num_up_buffers(self) -> int:
        return 1

    def rtt_get_num_down_buffers(self) -> int:
        return 1

    def rtt_get_buf_descriptor(self, _index: int, up: bool) -> _Descriptor:
        return _Descriptor(RTT_PLUS_TIMESTAMP_CHANNEL if up else "JScope_Config")

    def rtt_read(self, _index: int, _max_bytes: int) -> bytes:
        return self._reads.pop(0) if self._reads else b""

    def rtt_write(self, index: int, data: list[int]) -> int:
        payload = bytes(data)
        self.writes.append((index, payload))
        return len(payload)


class _Probe:
    def __init__(self, link: _NativeLink) -> None:
        self._link = link


class RttPlusFormatTests(unittest.TestCase):
    def test_config_contains_address_size_records_and_zero_terminator(self) -> None:
        variables = [
            self._variable("speed", 0x20000100, 4, "float"),
            self._variable("enabled", 0x20000200, 1, "bool"),
        ]

        config = build_rtt_plus_config(variables)

        self.assertEqual(
            config,
            RTT_PLUS_RECORD.pack(0x20000100, 4)
            + RTT_PLUS_RECORD.pack(0x20000200, 1)
            + RTT_PLUS_RECORD.pack(0, 0),
        )

    def test_decoder_preserves_partial_packets_and_uses_elf_types(self) -> None:
        symbols = (
            self._variable("speed", 0x20000100, 4, "float").symbol,
            self._variable("level", 0x20000200, 2, "int16_t").symbol,
        )
        decoder = RttPlusStreamDecoder(symbols, timestamped=True)
        payload = struct.pack("<Ifh", 2500, 12.5, -7)

        self.assertEqual(decoder.feed(payload[:5]), [])
        packets = decoder.feed(payload[5:])

        self.assertEqual(len(packets), 1)
        self.assertEqual(packets[0].timestamp_us, 2500)
        self.assertEqual(packets[0].values, (12.5, -7))

    def test_backend_sends_config_consumes_response_and_keeps_first_data_packet(self) -> None:
        variables = [self._variable("speed", 0x20000100, 4, "float")]
        packet = struct.pack("<If", 1000, 3.25)
        up_channel = _UpChannel(b"", bytes(RTT_PLUS_RESPONSE_SIZE) + packet)
        down_channel = _DownChannel()
        backend = JScopeRttPlusBackend()

        symbols = backend._activate(
            object(),
            1,
            up_channel,
            2,
            down_channel,
            (variables[0].symbol,),
        )
        frames = backend.read_frames(0.5)

        self.assertEqual(symbols, (variables[0].symbol,))
        self.assertEqual(down_channel.writes, [(build_rtt_plus_config(variables), True)])
        self.assertEqual(frames, [(0.5, {variables[0].symbol.key: 3.25})])

    def test_backend_surfaces_target_configuration_error(self) -> None:
        variable = self._variable("speed", 0x20000100, 4, "float")
        response = b"Increase variable buffer!\0".ljust(RTT_PLUS_RESPONSE_SIZE, b"\0")
        backend = JScopeRttPlusBackend()

        with self.assertRaisesRegex(RuntimeError, "Increase variable buffer"):
            backend._activate(
                object(),
                1,
                _UpChannel(b"", response),
                2,
                _DownChannel(),
                (variable.symbol,),
            )

    def test_backend_skips_stale_data_before_configuration_response(self) -> None:
        variable = self._variable("speed", 0x20000100, 4, "float")
        stale_packet = struct.pack("<II", 500, 2)
        first_packet = struct.pack("<If", 1000, 3.25)
        up_channel = _UpChannel(b"", stale_packet + bytes(RTT_PLUS_RESPONSE_SIZE) + first_packet)
        backend = JScopeRttPlusBackend()
        backend._previous_packet_size = len(stale_packet)

        backend._activate(
            object(),
            1,
            up_channel,
            2,
            _DownChannel(),
            (variable.symbol,),
        )

        self.assertEqual(backend.read_frames(0.5), [(0.5, {variable.symbol.key: 3.25})])

    def test_native_jlink_uses_named_up_and_down_channels(self) -> None:
        variable = self._variable("speed", 0x20000100, 4, "float")
        link = _NativeLink(bytes(RTT_PLUS_RESPONSE_SIZE))
        backend = JScopeRttPlusBackend()

        symbols = backend.start(object(), None, _Probe(link), [variable])

        self.assertEqual(symbols, (variable.symbol,))
        self.assertEqual(backend.transport_name, "J-Link 原生 RTT")
        self.assertEqual(link.writes, [(0, build_rtt_plus_config([variable]))])
        backend.stop()
        self.assertFalse(link.started)

    def test_native_jlink_stops_rtt_when_target_rejects_configuration(self) -> None:
        variable = self._variable("speed", 0x20000100, 4, "float")
        response = b"Invalid configuration\0".ljust(RTT_PLUS_RESPONSE_SIZE, b"\0")
        link = _NativeLink(response)
        backend = JScopeRttPlusBackend()

        with self.assertRaisesRegex(RuntimeError, "Invalid configuration"):
            backend.start(object(), None, _Probe(link), [variable])

        self.assertFalse(link.started)
        self.assertFalse(backend.is_started)

    @staticmethod
    def _variable(name: str, address: int, size: int, kind: str) -> WatchedVariable:
        return WatchedVariable(
            SymbolInfo(name, address, size, kind, ".bss", "../Core/Src/main.c"),
            "#ffffff",
        )


if __name__ == "__main__":
    unittest.main()
