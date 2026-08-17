from __future__ import annotations

import csv
import tempfile
import threading
import time
import unittest
from pathlib import Path

from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService


class _FakeMemory:
    def __init__(self) -> None:
        self.target = object()
        self.probe = object()
        self.last_read_metrics = {"block_count": 0, "byte_count": 0}
        self.connected: PyOcdConnectionConfig | None = None
        self.values: dict[str, object] = {}
        self.reset_calls: list[bool] = []

    def connect(self, config: PyOcdConnectionConfig) -> None:
        self.connected = config

    def disconnect(self) -> None:
        self.connected = None

    def read_symbols(self, symbols: list[SymbolInfo]) -> dict[str, object]:
        self.last_read_metrics = {"block_count": 1 if symbols else 0, "byte_count": sum(item.size for item in symbols)}
        result = {}
        for symbol in symbols:
            next_value = int(self.values.get(symbol.key, 0)) + 1
            self.values[symbol.key] = next_value
            result[symbol.key] = next_value
        return result

    def write_symbol(self, symbol: SymbolInfo, value: str) -> object:
        parsed = int(value, 0)
        self.values[symbol.key] = parsed
        return parsed

    def reset(self, halt: bool = False) -> None:
        self.reset_calls.append(halt)


class _FakeRtt:
    is_started = False
    transport_name = "fake RTT"

    def stop(self) -> None:
        self.is_started = False


class BackendServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events: list[tuple[EventName, object]] = []
        self.events_lock = threading.Lock()
        self.memory = _FakeMemory()
        self.symbols = [
            SymbolInfo("counter", 0x20000000, 4, "uint32_t", ".data", "main.c"),
            SymbolInfo("readonly", 0x08000000, 4, "uint32_t", ".rodata", "main.c"),
        ]
        self.service = BackendService(
            self._event,
            memory_backend=self.memory,  # type: ignore[arg-type]
            normal_rtt_backend=_FakeRtt(),  # type: ignore[arg-type]
            plus_rtt_backend=_FakeRtt(),  # type: ignore[arg-type]
            symbol_loader=lambda _path: list(self.symbols),
        )

    def tearDown(self) -> None:
        self.service.close()

    def _event(self, name: EventName, params: object) -> None:
        with self.events_lock:
            self.events.append((name, params))

    def _eventually(self, name: EventName, timeout_s: float = 1.0) -> object:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            with self.events_lock:
                for event_name, payload in self.events:
                    if event_name == name:
                        return payload
            time.sleep(0.01)
        self.fail(f"Did not receive {name} event")

    def test_load_watch_connect_sample_write_reset_and_export(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            symbol_path = Path(directory) / "firmware.axf"
            symbol_path.write_bytes(b"not parsed by injected loader")
            loaded = self.service.handle(RpcMethod.LOAD_SYMBOLS, {"path": str(symbol_path)})
            key = self.symbols[0].key
            self.assertEqual(len(loaded["state"]["symbols"]), 2)  # type: ignore[index]
            self.assertEqual(loaded["state"]["symbols"][0]["section"], ".data")  # type: ignore[index]

            watch_result = self.service.handle(
                RpcMethod.SET_WATCHES, {"watches": [{"key": key, "color": "#00ff00", "plotted": True}]}
            )
            self.assertNotIn("symbols", watch_result["state"])  # type: ignore[operator]
            connected = self.service.handle(RpcMethod.CONNECT, {"targetName": "STM32F407", "swdClock": "2 MHz"})
            self.assertEqual(connected["state"]["connectionStatus"], "connected")  # type: ignore[index]
            self.assertEqual(self.memory.connected.frequency_hz, 2_000_000)  # type: ignore[union-attr]

            samples = self._eventually(EventName.SAMPLES)
            self.assertGreaterEqual(len(samples["frames"]), 1)  # type: ignore[index]
            self.service.handle(RpcMethod.CLEAR_SAMPLES, {})
            self._eventually(EventName.SAMPLES_CLEARED)
            with self.events_lock:
                self.events.clear()
            self._eventually(EventName.SAMPLES)
            self.service.handle(RpcMethod.WRITE_WATCH, {"key": key, "value": "0x2A"})
            self.assertEqual(self.memory.values[key], 42)
            self.service.handle(RpcMethod.RESET_TARGET, {"halt": True})
            self.assertEqual(self.memory.reset_calls, [True])

            export_path = Path(directory) / "samples"
            exported = self.service.handle(RpcMethod.EXPORT_CSV, {"path": str(export_path)})
            self.assertEqual(Path(exported["path"]).suffix, ".csv")
            with Path(exported["path"]).open(encoding="utf-8-sig") as handle:
                rows = list(csv.reader(handle))
            self.assertEqual(rows[0], ["elapsed_seconds", "counter"])
            self.assertGreaterEqual(len(rows), 2)

    def test_validation_keeps_read_only_symbols_and_unknown_watches_safe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            symbol_path = Path(directory) / "firmware.elf"
            symbol_path.touch()
            self.service.handle(RpcMethod.LOAD_SYMBOLS, {"path": str(symbol_path)})
            with self.assertRaisesRegex(ProtocolError, "unknown symbol"):
                self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": "missing"}]})
            readonly = self.symbols[1].key
            self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": readonly}]})
            with self.assertRaisesRegex(ProtocolError, "read-only"):
                self.service.handle(RpcMethod.WRITE_WATCH, {"key": readonly, "value": "1"})

    def test_config_and_pause_round_trip_in_state(self) -> None:
        state = self.service.handle(
            RpcMethod.SET_CONFIG,
            {"probeType": "J-Link", "serialNumber": "123", "sampleRateHz": 200, "rttSampleRateHz": 500},
        )["state"]
        self.assertEqual(state["probeType"], "J-Link")
        self.assertEqual(state["sampleRateHz"], 200.0)
        paused = self.service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})["state"]
        self.assertTrue(paused["samplingPaused"])
        self.assertNotIn("symbols", paused)
        self.assertNotIn("watches", paused)
