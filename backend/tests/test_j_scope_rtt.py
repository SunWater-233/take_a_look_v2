from __future__ import annotations

import struct
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from take_a_look_backend.backends.j_scope_rtt import (
    JScopeRttBackend,
    JScopeStreamDecoder,
    _connect_native_jlink_target,
    _symbols_for_format,
    parse_j_scope_channel_name,
)


class _ChunkChannel:
    def __init__(self, *chunks: bytes, name: str = "") -> None:
        self.chunks = list(chunks)
        self.name = name

    def read(self) -> bytes:
        return self.chunks.pop(0) if self.chunks else b""


class _NativeDescriptor:
    def __init__(self, name: str, size: int = 4096) -> None:
        self.name = name
        self.SizeOfBuffer = size


class _NativeJLink:
    def __init__(self, payload: bytes) -> None:
        self.payload = payload
        self.started_at: int | None = None
        self.stopped = 0

    def rtt_start(self, address: int | None = None) -> None:
        self.started_at = address

    def rtt_stop(self) -> None:
        self.stopped += 1

    def rtt_get_num_up_buffers(self) -> int:
        return 2

    def rtt_get_buf_descriptor(self, channel_index: int, up: bool) -> _NativeDescriptor:
        self.assert_up = up
        return _NativeDescriptor("Terminal" if channel_index == 0 else "JScope_t4f4")

    def rtt_read(self, channel_index: int, max_bytes: int) -> list[int]:
        self.read_args = (channel_index, max_bytes)
        payload, self.payload = self.payload, b""
        return list(payload)


class _NativeProbe:
    def __init__(self, link: _NativeJLink) -> None:
        self._link = link


class JScopeFormatTests(unittest.TestCase):
    def test_parses_supported_j_scope_fields_case_insensitively(self) -> None:
        data_format = parse_j_scope_channel_name("JScope_T4F4I2U1B1")

        self.assertTrue(data_format.has_timestamp)
        self.assertEqual(data_format.packet_size, 12)
        self.assertEqual(
            [(field.type_code, field.size) for field in data_format.data_fields],
            [("f", 4), ("i", 2), ("u", 1), ("b", 1)],
        )

    def test_rejects_invalid_sizes_timestamp_positions_and_empty_data(self) -> None:
        for name in ("Terminal", "JScope_f2", "JScope_i4t4", "JScope_t4"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                parse_j_scope_channel_name(name)

    def test_rejects_more_than_twelve_fields(self) -> None:
        with self.assertRaises(ValueError):
            parse_j_scope_channel_name("JScope_" + "u1" * 13)

    def test_decoder_preserves_partial_packet_and_decodes_multiple_packets(self) -> None:
        data_format = parse_j_scope_channel_name("JScope_t4f4i2u1b1")
        decoder = JScopeStreamDecoder(data_format)
        payload = struct.pack("<IfhB?", 100, 1.25, -7, 250, True)
        payload += struct.pack("<IfhB?", 200, -2.5, 8, 3, False)

        self.assertEqual(decoder.feed(payload[:5]), [])
        packets = decoder.feed(payload[5:])

        self.assertEqual([packet.timestamp_us for packet in packets], [100, 200])
        self.assertEqual(packets[0].values, (1.25, -7, 250, True))
        self.assertEqual(packets[1].values, (-2.5, 8, 3, False))


class JScopeBackendTimeTests(unittest.TestCase):
    def _backend(self, channel_name: str, payload: bytes) -> JScopeRttBackend:
        data_format = parse_j_scope_channel_name(channel_name)
        backend = JScopeRttBackend()
        backend.data_format = data_format
        backend.decoder = JScopeStreamDecoder(data_format)
        backend.up_channel = _ChunkChannel(payload)
        backend.channel_index = 1
        backend.symbols = _symbols_for_format(1, data_format)
        return backend

    def test_target_timestamp_is_relative_and_handles_uint32_wrap(self) -> None:
        payload = struct.pack("<IB", 0xFFFFFFF0, 1) + struct.pack("<IB", 0x00000010, 2)
        backend = self._backend("JScope_t4u1", payload)

        frames = backend.read_frames(5.0)

        self.assertAlmostEqual(frames[0][0], 5.0)
        self.assertAlmostEqual(frames[1][0], 5.000032)
        self.assertEqual(list(frames[0][1].values()), [1])
        self.assertEqual(list(frames[1][1].values()), [2])

    def test_untimed_packets_use_independent_nominal_rate(self) -> None:
        backend = self._backend("JScope_f4", struct.pack("<ff", 1.0, 2.0))
        backend.set_nominal_rate_hz(200.0)

        frames = backend.read_frames(3.0)

        self.assertAlmostEqual(frames[0][0], 3.0)
        self.assertAlmostEqual(frames[1][0], 3.005)
        self.assertTrue(all(symbol.is_rtt for symbol in backend.symbols))
        self.assertEqual(len({symbol.key for symbol in backend.symbols}), len(backend.symbols))

    def test_start_selects_first_j_scope_channel_and_uses_known_control_block_address(self) -> None:
        class _ControlBlock:
            def __init__(self) -> None:
                self.up_channels = [
                    _ChunkChannel(name="Terminal"),
                    _ChunkChannel(struct.pack("<f", 3.5), name="JScope_f4"),
                ]

            def start(self) -> None:
                pass

        target = object()
        control_block = _ControlBlock()
        with patch("pyocd.debug.rtt.RTTControlBlock.from_target", return_value=control_block) as factory:
            backend = JScopeRttBackend()
            symbols = backend.start(target, 0x20001000)

        factory.assert_called_once_with(target, address=0x20001000)
        self.assertEqual(backend.channel_index, 1)
        self.assertEqual(backend.data_format.channel_name, "JScope_f4")
        self.assertEqual(len(symbols), 1)
        self.assertEqual(list(backend.read_frames(0.0)[0][1].values()), [3.5])

    def test_jlink_probe_uses_native_rtt_transport(self) -> None:
        link = _NativeJLink(struct.pack("<If", 1234, 6.5))
        backend = JScopeRttBackend()
        backend.NATIVE_START_DRAIN_S = 0.0

        symbols = backend.start(object(), 0x20001000, _NativeProbe(link))
        frames = backend.read_frames(2.0)

        self.assertEqual(link.started_at, 0x20001000)
        self.assertEqual(backend.transport_name, "J-Link 原生 RTT")
        self.assertEqual(backend.channel_index, 1)
        self.assertEqual(len(symbols), 1)
        self.assertEqual(list(frames[0][1].values()), [6.5])
        self.assertEqual(link.read_args[0], 1)

        backend.stop()
        self.assertEqual(link.stopped, 1)

    def test_native_jlink_connects_using_selected_core_name(self) -> None:
        class _DisconnectedLink:
            connected_name = ""

            @staticmethod
            def target_connected() -> bool:
                return False

            def connect(self, name: str) -> None:
                self.connected_name = name

        link = _DisconnectedLink()
        target = SimpleNamespace(selected_core=SimpleNamespace(name="Cortex-M7"))

        _connect_native_jlink_target(link, target)

        self.assertEqual(link.connected_name, "Cortex-M7")


if __name__ == "__main__":
    unittest.main()
