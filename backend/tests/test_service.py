from __future__ import annotations

import csv
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from pathlib import Path

from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex, SourceLocation


class _FakeMemory:
    def __init__(self) -> None:
        self.target = object()
        self.probe = object()
        self.last_read_metrics = {"block_count": 0, "byte_count": 0}
        self.connected: PyOcdConnectionConfig | None = None
        self.values: dict[str, object] = {}
        self.reset_calls: list[bool] = []
        self.execution_state = "running"
        self.breakpoints: set[int] = set()
        self.registers = {"pc": 0x08000100, "sp": 0x20001000, "lr": 0x08000081}

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

    def halt(self) -> None:
        self.execution_state = "halted"

    def resume(self) -> None:
        self.execution_state = "running"

    def step(self) -> None:
        self.execution_state = "halted"
        self.registers["pc"] += 4

    def debug_state(self) -> str:
        return self.execution_state

    def set_breakpoint(self, address: int) -> bool:
        self.breakpoints.add(address)
        return True

    def remove_breakpoint(self, address: int) -> None:
        self.breakpoints.discard(address)

    def read_core_registers(self) -> dict[str, int]:
        return dict(self.registers)


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
        self.recording_directory = tempfile.TemporaryDirectory(prefix="tal_recording_")
        self.symbols = [
            SymbolInfo("counter", 0x20000000, 4, "uint32_t", ".data", "main.c"),
            SymbolInfo("readonly", 0x08000000, 4, "uint32_t", ".rodata", "main.c"),
        ]
        self.service = BackendService(
            self._event,
            recording_directory=Path(self.recording_directory.name),
            memory_backend=self.memory,  # type: ignore[arg-type]
            normal_rtt_backend=_FakeRtt(),  # type: ignore[arg-type]
            plus_rtt_backend=_FakeRtt(),  # type: ignore[arg-type]
            symbol_loader=lambda _path, **_kwargs: list(self.symbols),
            debug_info_loader=lambda _path, **_kwargs: DebugInfoIndex(
                [
                    SourceLocation("C:/firmware/main.c", 10, 0x08000100),
                    SourceLocation("C:/firmware/main.c", 12, 0x08000108),
                ]
            ),
        )

    def tearDown(self) -> None:
        self.service.close()
        self.recording_directory.cleanup()

    def test_pending_recording_survives_watch_removal_and_clear(self) -> None:
        key = self.symbols[0].key
        with self.service._lock:
            self.service._watches[key] = WatchedVariable(self.symbols[0], "#00ff00")
            self.service._queue_samples_locked([(1.0, {key: 41}), (1.1, {key: 42})])
            self.service._watches.clear()
            self.service._flush_pending_samples_locked()
            old_path = self.service._recording.path
            self.assertEqual(self.service._recording.sample_count, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "complete.csv"
            self.service.handle(RpcMethod.EXPORT_CSV, {"path": str(path)})
            with path.open(encoding="utf-8-sig", newline="") as stream:
                self.assertEqual(list(csv.reader(stream)), [
                    ["elapsed_seconds", "counter"], ["1.000000000", "41"], ["1.100000000", "42"]])
        self.service.handle(RpcMethod.CLEAR_SAMPLES, {})
        self.assertTrue(old_path.exists())
        self.assertEqual(self.service._recording.sample_count, 0)

    def test_recording_io_does_not_hold_the_hardware_lock(self) -> None:
        entered, release = threading.Event(), threading.Event()
        original = self.service._recording.append
        def slow_append(frames, labels):
            entered.set()
            self.assertTrue(release.wait(2))
            original(frames, labels)
        key = self.symbols[0].key
        try:
            with patch.object(self.service._recording, "append", side_effect=slow_append):
                with self.service._lock:
                    self.service._watches[key] = WatchedVariable(self.symbols[0], "#00ff00")
                    self.service._queue_samples_locked([(1.0, {key: 41})])
                    self.assertTrue(self.service._flush_pending_samples_locked(wait=False))
                self.assertTrue(entered.wait(1))
                # The writer is still blocked, but hardware/control state is available.
                self.assertTrue(self.service._lock.acquire(timeout=0.2))
                self.service._lock.release()
                release.set()
                self.service._pipeline.drain()
            self.assertEqual(self.service._recording.sample_count, 1)
        finally:
            release.set()

    def test_pending_explicit_write_precedes_the_next_high_frequency_read(self) -> None:
        entered, release, written = threading.Event(), threading.Event(), threading.Event()
        sequence = []
        original_read, original_write = self.memory.read_symbols, self.memory.write_symbol
        def read(symbols):
            sequence.append("read")
            if len(sequence) == 1:
                entered.set()
                self.assertTrue(release.wait(2))
            return original_read(symbols)
        def write(symbol, value):
            sequence.append("write")
            return original_write(symbol, value)
        key = self.symbols[0].key
        with self.service._lock:
            self.service._symbols = {item.key: item for item in self.symbols}
        self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": key}]})
        self.service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": 10000})
        def command():
            try:
                self.service.handle(RpcMethod.WRITE_WATCH, {"key": key, "value": "42"})
            finally:
                written.set()
        worker = threading.Thread(target=command)
        try:
            with patch.object(self.memory, "read_symbols", side_effect=read), \
                 patch.object(self.memory, "write_symbol", side_effect=write):
                self.service.handle(RpcMethod.CONNECT, {})
                self.assertTrue(self.service.state_snapshot()["samplingPaused"])
                self.service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": False})
                self.assertTrue(entered.wait(1))
                worker.start()
                deadline = time.perf_counter() + 1
                while self.service._controls_idle.is_set() and time.perf_counter() < deadline:
                    time.sleep(.001)
                self.assertFalse(self.service._controls_idle.is_set())
                release.set()
                self.assertTrue(written.wait(1))
                self.service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
            self.assertEqual(sequence[:2], ["read", "write"])
        finally:
            release.set()
            if worker.ident is not None:
                worker.join(2)

    def test_export_fence_survives_later_samples_and_clear(self) -> None:
        key = self.symbols[0].key
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.csv"
            with self.service._lock:
                self.service._watches[key] = WatchedVariable(self.symbols[0], "#00ff00")
                self.service._queue_samples_locked([(1.0, {key: 1}), (1.0, {key: 2})])
            prepared = self.service.prepare_csv_export({"path": str(path)})
            with self.service._lock:
                self.service._queue_samples_locked([(2.0, {key: 3})])
            self.service.handle(RpcMethod.CLEAR_SAMPLES, {})
            result = self.service.finish_csv_export(prepared)
            self.assertEqual(result["sampleCount"], 2)
            with path.open(encoding="utf-8-sig", newline="") as stream:
                self.assertEqual(list(csv.reader(stream))[1:], [
                    ["1.000000000", "1"], ["1.000000000", "2"]])

    def test_recording_failure_pauses_acquisition_and_blocks_resume(self) -> None:
        key = self.symbols[0].key
        with self.service._lock:
            self.service._watches[key] = WatchedVariable(self.symbols[0], "#00ff00")
            self.service._queue_samples_locked([(1.0, {key: 41})])
            with patch.object(self.service._recording, "append", side_effect=OSError("disk full")):
                self.service._flush_pending_samples_locked()
            self.assertTrue(self.service._sampling_paused)
            self.assertEqual(self.service._recording.sample_count, 0)
        with self.assertRaises(ProtocolError):
            self.service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": False})
        self.assertTrue(any(event == EventName.ERROR and value["code"] == "raw_recording_failed"
                            for event, value in self.events))

    def test_connect_starts_a_new_time_axis_and_preserves_the_old_journal(self) -> None:
        with self.service._lock:
            self.service._recording.append([(70.0, {"old": 12})], {"old": "previous"})
            previous = self.service._recording.path
        self.service.handle(RpcMethod.CONNECT, {})
        self.assertTrue(previous.exists())
        self.assertNotEqual(self.service._recording.path, previous)
        self.assertEqual(self.service._recording.sample_count, 0)
        self.assertTrue(any(event == EventName.SAMPLES_CLEARED for event, _ in self.events))

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
            loaded = self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(symbol_path)})
            key = self.symbols[0].key
            self.assertEqual(len(loaded["state"]["symbols"]), 2)  # type: ignore[index]
            self.assertEqual(loaded["state"]["symbols"][0]["section"], ".data")  # type: ignore[index]

            watch_result = self.service.handle(
                RpcMethod.SET_WATCHES, {"watches": [{"key": key, "color": "#00ff00", "plotted": True}]}
            )
            self.assertNotIn("symbols", watch_result["state"])  # type: ignore[operator]
            connected = self.service.handle(RpcMethod.CONNECT, {"targetName": "STM32F407", "swdClock": "2 MHz"})
            self.assertEqual(connected["state"]["connectionStatus"], "connected")  # type: ignore[index]
            self.assertTrue(connected["state"]["samplingPaused"])  # type: ignore[index]
            self.assertEqual(self.memory.connected.frequency_hz, 2_000_000)  # type: ignore[union-attr]
            self.service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": False})

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
            self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(symbol_path)})
            with self.assertRaisesRegex(ProtocolError, "unknown symbol"):
                self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": "missing"}]})
            readonly = self.symbols[1].key
            self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": readonly}]})
            with self.assertRaisesRegex(ProtocolError, "read-only"):
                self.service.handle(RpcMethod.WRITE_WATCH, {"key": readonly, "value": "1"})

    def test_symbol_progress_precedes_atomic_state_and_is_throttled(self) -> None:
        def symbols(_path, *, progress):
            progress("debug", 0, 1000)
            for count in range(1, 1001):
                progress("debug", count, 1000)
            progress("scan", 0, 0)
            progress("variables", 0, 2)
            progress("variables", 2, 2)
            return self.symbols

        def debug(_path, *, progress):
            progress("source", 0, 2)
            progress("source", 2, 2)
            self.assertEqual(self.service.state_snapshot()["symbols"], [])
            return DebugInfoIndex()

        self.service._symbol_loader = symbols
        self.service._debug_info_loader = debug
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.elf"
            path.touch()
            result = self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path), "loadId": "load-1"})
        progress = [payload for event, payload in self.events if event == EventName.SYMBOL_LOAD_PROGRESS]
        self.assertEqual(progress[0]["phase"], "check")
        self.assertEqual(progress[-1]["phase"], "ui")
        self.assertTrue(all(item["loadId"] == "load-1" for item in progress))
        self.assertLess(len(progress), 20)
        self.assertIn((1000, 1000), [(p["current"], p["total"]) for p in progress if p["phase"] == "debug"])
        self.assertEqual(len(result["state"]["symbols"]), 2)
        self.assertEqual(self.events[-1][0], EventName.STATE)

    def test_failed_or_expired_load_keeps_previous_symbols_and_watches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.elf"
            path.touch()
            self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path)})
            self.service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": self.symbols[0].key}]})
            before = self.service.state_snapshot()

            def fail(_path, **_kwargs):
                raise ValueError("bad ELF header")

            self.service._symbol_loader = fail
            with self.assertRaises(ProtocolError) as caught:
                self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path), "loadId": "bad"})
            self.assertEqual(caught.exception.code, "symbol_load_failed")

            def slow(_path, **_kwargs):
                time.sleep(0.03)
                return []

            self.service._symbol_loader = slow
            with patch("take_a_look_backend.services.firmware.SYMBOL_LOAD_TIMEOUT_SECONDS", 0.01):
                with self.assertRaises(ProtocolError) as caught:
                    self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path), "loadId": "slow"})
            self.assertEqual(caught.exception.code, "symbol_load_timeout")
            after = self.service.state_snapshot()
            for key in ("symbols", "watches", "firmware", "sourceProject", "debug"):
                self.assertEqual(after[key], before[key])

    def test_source_index_failure_remains_a_warning_and_load_completes(self) -> None:
        def fail(_path, **_kwargs):
            raise ValueError("bad line information")

        self.service._debug_info_loader = fail
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "firmware.axf"
            path.touch()
            result = self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(path)})
        self.assertEqual(len(result["state"]["symbols"]), 2)
        self.assertEqual(result["state"]["debug"]["sourceFiles"], [])
        self.assertTrue(any(name == EventName.LOG and payload.get("level") == "warning" for name, payload in self.events))

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

    def test_source_breakpoints_and_run_control_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            symbol_path = Path(directory) / "firmware.elf"
            symbol_path.touch()
            loaded = self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(symbol_path)})
            self.assertEqual(loaded["state"]["debug"]["sourceFiles"], ["C:/firmware/main.c"])  # type: ignore[index]
            self.assertEqual(
                loaded["state"]["debug"]["executableLines"],  # type: ignore[index]
                {"C:/firmware/main.c": [10, 12]},
            )

            pending = self.service.handle(
                RpcMethod.SET_BREAKPOINTS,
                {"path": "C:/firmware/main.c", "lines": [12]},
            )["debug"]
            self.assertFalse(pending["breakpoints"][0]["verified"])  # type: ignore[index]

            self.service.handle(RpcMethod.CONNECT, {})
            self.assertEqual(self.memory.breakpoints, {0x08000108})
            self.service.handle(RpcMethod.DEBUG_CONTROL, {"action": "halt"})
            debug = self.service.handle(RpcMethod.GET_DEBUG_INFO, {})["debug"]
            self.assertEqual(debug["executionState"], "halted")  # type: ignore[index]
            self.assertEqual(debug["stoppedLocation"]["line"], 10)  # type: ignore[index]
            self.assertEqual(debug["registers"]["sp"], 0x20001000)  # type: ignore[index]

            self.service.handle(
                RpcMethod.SET_BREAKPOINTS,
                {"path": "C:/firmware/main.c", "lines": [10]},
            )
            self.service.handle(RpcMethod.DEBUG_CONTROL, {"action": "resume"})
            self.assertEqual(self.memory.execution_state, "running")
            self.assertEqual(self.memory.registers["pc"], 0x08000104)
            self.assertEqual(self.memory.breakpoints, {0x08000100})

    def test_breakpoint_can_be_removed_through_canonical_path_after_alias_add(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            symbol_path = Path(directory) / "firmware.elf"
            symbol_path.touch()
            self.service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(symbol_path)})
            self.service.handle(RpcMethod.CONNECT, {})

            added = self.service.handle(
                RpcMethod.SET_BREAKPOINTS,
                {"path": "D:/checkout/main.c", "lines": [12]},
            )["debug"]
            self.assertEqual(added["breakpoints"][0]["path"], "C:/firmware/main.c")  # type: ignore[index]
            self.assertEqual(self.memory.breakpoints, {0x08000108})

            removed = self.service.handle(
                RpcMethod.SET_BREAKPOINTS,
                {"path": "C:/firmware/main.c", "lines": []},
            )["debug"]
            self.assertEqual(removed["breakpoints"], [])  # type: ignore[index]
            self.assertEqual(self.memory.breakpoints, set())
