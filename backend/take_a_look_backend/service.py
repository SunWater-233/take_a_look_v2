from __future__ import annotations

import csv
import math
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import PROTOCOL_VERSION, ProtocolError
from take_a_look_backend.services.symbols import load_symbols_from_elf


EventSink = Callable[[str, object], None]
SymbolLoader = Callable[[Path], list[SymbolInfo]]


class BackendService:
    """Owns hardware state and exposes it through a small command surface.

    pyOCD access is serialized by ``_lock``. The sampler runs on one worker
    thread so blocking a probe never blocks JSON-RPC input or Flutter's UI.
    """

    def __init__(
        self,
        event_sink: EventSink,
        *,
        memory_backend: PyOcdMemoryBackend | None = None,
        normal_rtt_backend: JScopeRttBackend | None = None,
        plus_rtt_backend: JScopeRttPlusBackend | None = None,
        symbol_loader: SymbolLoader = load_symbols_from_elf,
    ) -> None:
        self._emit_event = event_sink
        self._memory = memory_backend or PyOcdMemoryBackend()
        self._normal_rtt = normal_rtt_backend or JScopeRttBackend()
        self._plus_rtt = plus_rtt_backend or JScopeRttPlusBackend()
        self._symbol_loader = symbol_loader
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._shutdown = threading.Event()
        self._sampler = threading.Thread(target=self._sampling_loop, name="tal-sampler", daemon=True)

        self._connection_status = "disconnected"
        self._probe_type = "自动发现任意探针"
        self._target_name = "auto"
        self._swd_clock = "4 MHz"
        self._serial_number = ""
        self._sample_rate_hz = 50.0
        self._rtt_sample_rate_hz = 1000.0
        self._sampling_paused = False
        self._rtt_enabled = False
        self._rtt_protocol = "normal"
        self._rtt_control_block_address: int | None = None
        self._symbol_file = ""
        self._connection_started_at: float | None = None
        self._symbols: dict[str, SymbolInfo] = {}
        self._watches: dict[str, WatchedVariable] = {}
        self._samples: deque[tuple[float, dict[str, object]]] = deque(maxlen=600_000)
        self._sample_count_since_perf = 0
        self._perf_window_started_at = time.monotonic()
        self._last_perf_at = self._perf_window_started_at
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0
        self._sampler.start()

    def close(self) -> None:
        self._shutdown.set()
        self._wake.set()
        self._sampler.join(timeout=2.0)
        with self._lock:
            self._stop_rtt_locked()
            self._memory.disconnect()
            self._connection_status = "disconnected"

    def handle(self, method: str, params: Mapping[str, object]) -> dict[str, object]:
        if method == "handshake":
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": [
                    "symbols",
                    "memorySampling",
                    "memoryWrite",
                    "rttNormal",
                    "rttPlus",
                    "csvExport",
                    "targetReset",
                ],
                "state": self.state_snapshot(),
            }
        if method == "getState":
            return {"state": self.state_snapshot()}
        if method == "connect":
            return self._connect(params)
        if method == "toggleConnection":
            return self._disconnect() if self._connection_status == "connected" else self._connect(params)
        if method == "disconnect":
            return self._disconnect()
        if method == "loadSymbols":
            return self._load_symbols(params)
        if method == "setConfig":
            return self._set_config(params)
        if method == "setWatches":
            return self._set_watches(params)
        if method == "writeWatch":
            return self._write_watch(params)
        if method == "setSamplingPaused":
            return self._set_sampling_paused(params)
        if method == "setRtt":
            return self._set_rtt(params)
        if method == "clearSamples":
            return self._clear_samples()
        if method == "resetTarget":
            return self._reset_target(params)
        if method == "exportCsv":
            return self._export_csv(params)
        if method == "shutdown":
            self.close()
            return {"state": self.state_snapshot()}
        raise ProtocolError("unknown_method", f"Unknown backend method: {method}")

    def state_snapshot(self) -> dict[str, object]:
        with self._lock:
            return {
                **self._runtime_state_locked(),
                "symbols": [self._symbol_json(symbol) for symbol in self._symbols.values()],
                "watches": [self._watch_json(watch) for watch in self._watches.values()],
            }

    def _runtime_state_locked(self) -> dict[str, object]:
        return {
            "connectionStatus": self._connection_status,
            "probeType": self._probe_type,
            "targetName": self._target_name,
            "swdClock": self._swd_clock,
            "serialNumber": self._serial_number,
            "sampleRateHz": self._sample_rate_hz,
            "rttSampleRateHz": self._rtt_sample_rate_hz,
            "samplingPaused": self._sampling_paused,
            "rttEnabled": self._rtt_enabled,
            "rttProtocol": self._rtt_protocol,
            "rttControlBlockAddress": self._rtt_control_block_address,
            "symbolFile": self._symbol_file,
            "elapsedSeconds": self._elapsed_locked(),
            "sampleCount": len(self._samples),
        }

    def _connect(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            if self._connection_status == "connected":
                return {"state": self._runtime_state_locked()}
            self._apply_config_locked(params)
            self._connection_status = "connecting"
            connecting_state = self._runtime_state_locked()
        self._emit("state", connecting_state)
        try:
            config = PyOcdConnectionConfig(
                target=_target_override(self._target_name),
                frequency_hz=_parse_frequency_hz(self._swd_clock),
                unique_id=self._serial_number.strip() or None,
                probe_filter=_probe_filter(self._probe_type),
            )
            self._memory.connect(config)
        except Exception as error:
            with self._lock:
                self._connection_status = "disconnected"
                failed_state = self._runtime_state_locked()
            self._emit("log", {"level": "error", "message": f"连接调试探针失败：{error}"})
            self._emit("state", failed_state)
            raise ProtocolError("connect_failed", "Unable to connect to the debug probe.", str(error)) from error
        with self._lock:
            self._connection_status = "connected"
            self._connection_started_at = time.monotonic()
            self._sampling_paused = False
            state = self._runtime_state_locked()
        self._emit("log", {"level": "info", "message": "已连接 pyOCD 调试探针。"})
        self._emit("state", state)
        self._wake.set()
        return {"state": state}

    def _disconnect(self) -> dict[str, object]:
        with self._lock:
            self._stop_rtt_locked()
            self._memory.disconnect()
            self._connection_status = "disconnected"
            self._connection_started_at = None
            self._sampling_paused = False
            state = self._runtime_state_locked()
        self._emit("log", {"level": "info", "message": "已断开调试探针。"})
        self._emit("state", state)
        return {"state": state}

    def _load_symbols(self, params: Mapping[str, object]) -> dict[str, object]:
        path_text = _required_string(params, "path")
        path = Path(path_text).expanduser()
        if not path.is_file():
            raise ProtocolError("file_not_found", "Symbol file does not exist.", str(path))
        if path.suffix.lower() not in {".elf", ".axf"}:
            raise ProtocolError("unsupported_symbol_file", "Symbol file must use .elf or .axf.", str(path))
        try:
            symbols = self._symbol_loader(path)
        except Exception as error:
            raise ProtocolError("symbol_load_failed", "Unable to parse the symbol file.", str(error)) from error
        with self._lock:
            self._symbols = {symbol.key: symbol for symbol in symbols}
            self._symbol_file = str(path)
            # Watches are only valid for symbols in the current file. RTT symbols
            # are recreated after a connection is established.
            self._watches = {
                key: watch for key, watch in self._watches.items() if key in self._symbols
            }
        self._emit("log", {"level": "info", "message": f"已读取符号文件：{path.name}，变量 {len(symbols)} 个。"})
        state = self.state_snapshot()
        self._emit("state", state)
        return {"state": state, "symbolFile": str(path)}

    def _set_config(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            self._apply_config_locked(params)
            state = self._runtime_state_locked()
        self._emit("state", state)
        self._wake.set()
        return {"state": state}

    def _set_watches(self, params: Mapping[str, object]) -> dict[str, object]:
        raw_watches = params.get("watches")
        if not isinstance(raw_watches, list):
            raise ProtocolError("invalid_request", "watches must be an array.")
        with self._lock:
            new_watches: dict[str, WatchedVariable] = {}
            for raw in raw_watches:
                if not isinstance(raw, Mapping):
                    raise ProtocolError("invalid_request", "Each watch must be an object.")
                key = _required_string(raw, "key")
                symbol = self._symbols.get(key)
                if symbol is None:
                    raise ProtocolError("unknown_symbol", "Watch references an unknown symbol.", key)
                old = self._watches.get(key)
                new_watches[key] = WatchedVariable(
                    symbol=symbol,
                    color=_optional_string(raw, "color") or (old.color if old else "#5EEAD4"),
                    plot_enabled=bool(raw.get("plotted", old.plot_enabled if old else True)),
                    value=old.value if old else "",
                )
            self._watches = new_watches
            if self._rtt_protocol == "plus":
                self._stop_rtt_locked()
            state = {"watches": [self._watch_json(watch) for watch in self._watches.values()]}
        self._emit("state", state)
        self._wake.set()
        return {"state": state}

    def _write_watch(self, params: Mapping[str, object]) -> dict[str, object]:
        key = _required_string(params, "key")
        value_text = _required_string(params, "value")
        with self._lock:
            watch = self._watches.get(key)
            if watch is None:
                raise ProtocolError("unknown_watch", "Watch does not exist.", key)
            if not watch.symbol.is_writable:
                raise ProtocolError("readonly_symbol", "This symbol is read-only.", watch.symbol.name)
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "Connect a debug probe before writing variables.")
            try:
                watch.value = self._memory.write_symbol(watch.symbol, value_text)
            except Exception as error:
                raise ProtocolError("write_failed", "Unable to write and verify the variable.", str(error)) from error
            state = {"watches": [self._watch_json(item) for item in self._watches.values()]}
        self._emit("log", {"level": "info", "message": f"已写入 {watch.symbol.name} 并完成回读验证。"})
        self._emit("state", state)
        return {"state": state}

    def _set_sampling_paused(self, params: Mapping[str, object]) -> dict[str, object]:
        paused = params.get("paused")
        if not isinstance(paused, bool):
            raise ProtocolError("invalid_request", "paused must be a boolean.")
        with self._lock:
            self._sampling_paused = paused
            state = {
                "samplingPaused": self._sampling_paused,
                "elapsedSeconds": self._elapsed_locked(),
            }
        self._emit("log", {"level": "info", "message": "采样已暂停。" if paused else "采样已继续。"})
        self._emit("state", state)
        self._wake.set()
        return {"state": state}

    def _set_rtt(self, params: Mapping[str, object]) -> dict[str, object]:
        enabled = params.get("enabled")
        if not isinstance(enabled, bool):
            raise ProtocolError("invalid_request", "enabled must be a boolean.")
        protocol = params.get("protocol", self._rtt_protocol)
        if protocol not in {"normal", "plus"}:
            raise ProtocolError("invalid_request", "RTT protocol must be normal or plus.")
        with self._lock:
            self._rtt_enabled = enabled
            self._rtt_protocol = str(protocol)
            if "rateHz" in params:
                self._rtt_sample_rate_hz = _positive_number(params["rateHz"], "rateHz")
            if "controlBlockAddress" in params:
                self._rtt_control_block_address = _optional_address(params["controlBlockAddress"])
            self._stop_rtt_locked()
            state = self._runtime_state_locked()
        self._emit("state", state)
        self._wake.set()
        return {"state": state}

    def _clear_samples(self) -> dict[str, object]:
        with self._lock:
            self._samples.clear()
            self._connection_started_at = time.monotonic() if self._connection_status == "connected" else None
            self._sample_count_since_perf = 0
            state = {"elapsedSeconds": 0.0, "sampleCount": 0}
        self._emit("samplesCleared", {})
        self._emit("state", state)
        return {"state": state}

    def _reset_target(self, params: Mapping[str, object]) -> dict[str, object]:
        halt = params.get("halt", False)
        if not isinstance(halt, bool):
            raise ProtocolError("invalid_request", "halt must be a boolean.")
        with self._lock:
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "Connect a debug probe before resetting the target.")
            try:
                self._memory.reset(halt=halt)
            except Exception as error:
                raise ProtocolError("reset_failed", "Unable to reset target.", str(error)) from error
        self._emit("log", {"level": "info", "message": "目标已复位并暂停。" if halt else "目标已复位并运行。"})
        with self._lock:
            return {"state": self._runtime_state_locked()}

    def _export_csv(self, params: Mapping[str, object]) -> dict[str, object]:
        path_text = _required_string(params, "path")
        path = Path(path_text).expanduser()
        if path.suffix.lower() != ".csv":
            path = path.with_suffix(".csv")
        with self._lock:
            frames = list(self._samples)
            symbols = dict(self._symbols)
        if not frames:
            raise ProtocolError("no_samples", "There are no samples to export.")
        path.parent.mkdir(parents=True, exist_ok=True)
        keys = sorted({key for _elapsed, values in frames for key in values})
        labels = [symbols.get(key).name if key in symbols else key for key in keys]
        with path.open("w", newline="", encoding="utf-8-sig") as handle:
            writer = csv.writer(handle)
            writer.writerow(["elapsed_seconds", *labels])
            for elapsed, values in frames:
                writer.writerow([f"{elapsed:.9f}", *[_csv_value(values.get(key)) for key in keys]])
        self._emit("log", {"level": "info", "message": f"已导出 {len(frames)} 帧原始采样 CSV：{path}"})
        return {"path": str(path), "sampleCount": len(frames)}

    def _apply_config_locked(self, params: Mapping[str, object]) -> None:
        if "probeType" in params:
            self._probe_type = _required_string(params, "probeType")
        if "targetName" in params:
            self._target_name = _required_string(params, "targetName")
        if "swdClock" in params:
            self._swd_clock = _required_string(params, "swdClock")
            _parse_frequency_hz(self._swd_clock)
        if "serialNumber" in params:
            self._serial_number = _required_string(params, "serialNumber")
        if "sampleRateHz" in params:
            self._sample_rate_hz = _positive_number(params["sampleRateHz"], "sampleRateHz")
        if "rttSampleRateHz" in params:
            self._rtt_sample_rate_hz = _positive_number(params["rttSampleRateHz"], "rttSampleRateHz")

    def _sampling_loop(self) -> None:
        next_memory_at = time.monotonic()
        next_rtt_at = time.monotonic()
        pending_frames: list[tuple[float, dict[str, object]]] = []
        last_emit_at = time.monotonic()
        while not self._shutdown.is_set():
            now = time.monotonic()
            try:
                with self._lock:
                    connected = self._connection_status == "connected"
                    paused = self._sampling_paused
                    memory_period = 1.0 / self._sample_rate_hz
                    rtt_period = 1.0 / self._rtt_sample_rate_hz
                    elapsed = self._elapsed_locked(now)
                    has_watches = bool(self._watches)
                    rtt_enabled = self._rtt_enabled
                    rtt_protocol = self._rtt_protocol
                    if connected and not paused and has_watches and now >= next_memory_at:
                        values = self._read_memory_locked(rtt_enabled, rtt_protocol)
                        if values:
                            pending_frames.append((elapsed, values))
                        next_memory_at = now + memory_period
                    if connected and not paused and rtt_enabled and now >= next_rtt_at:
                        pending_frames.extend(self._read_rtt_locked(elapsed, now))
                        next_rtt_at = now + max(rtt_period, 0.002)
            except Exception as error:
                self._emit("log", {"level": "error", "message": f"采样失败：{error}"})
                next_memory_at = time.monotonic() + 0.25

            now = time.monotonic()
            if pending_frames and (len(pending_frames) >= 64 or now - last_emit_at >= 0.006):
                self._publish_samples(pending_frames)
                pending_frames = []
                last_emit_at = now
            if now - self._last_perf_at >= 1.0:
                self._publish_perf(now)
            wait_s = min(max(next_memory_at - now, 0.001), max(next_rtt_at - now, 0.001), 0.05)
            self._wake.wait(wait_s)
            self._wake.clear()

    def _read_memory_locked(self, rtt_enabled: bool, rtt_protocol: str) -> dict[str, object]:
        if rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started:
            return {}
        symbols = [watch.symbol for watch in self._watches.values() if not watch.symbol.is_rtt]
        if not symbols:
            return {}
        values = self._memory.read_symbols(symbols)
        for key, value in values.items():
            if key in self._watches:
                self._watches[key].value = value
        return values

    def _read_rtt_locked(self, elapsed: float, now: float) -> list[tuple[float, dict[str, object]]]:
        backend: Any = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
        if not backend.is_started:
            if now < self._next_rtt_retry_at:
                return []
            try:
                if self._rtt_protocol == "normal":
                    symbols = self._normal_rtt.start(
                        self._memory.target,
                        self._rtt_control_block_address,
                        self._memory.probe,
                    )
                else:
                    symbols = self._plus_rtt.start(
                        self._memory.target,
                        self._rtt_control_block_address,
                        self._memory.probe,
                        list(self._watches.values()),
                    )
                if self._rtt_protocol == "normal":
                    for symbol in symbols:
                        self._symbols[symbol.key] = symbol
                    self._emit("state", self.state_snapshot())
                self._emit("log", {"level": "info", "message": f"RTT 已启动：{backend.transport_name}。"})
                self._last_rtt_error = ""
            except Exception as error:
                text = str(error)
                self._next_rtt_retry_at = now + 1.0
                if text != self._last_rtt_error:
                    self._last_rtt_error = text
                    self._emit("log", {"level": "error", "message": f"RTT 启动失败：{text}"})
                return []
        frames = backend.read_frames(elapsed)
        for _frame_elapsed, values in frames:
            for key, value in values.items():
                if key in self._watches:
                    self._watches[key].value = value
        return frames

    def _publish_samples(self, frames: list[tuple[float, dict[str, object]]]) -> None:
        with self._lock:
            normalized = [
                {"elapsed": elapsed, "values": {key: _json_value(value) for key, value in values.items()}}
                for elapsed, values in frames
            ]
            self._samples.extend((frame["elapsed"], frame["values"]) for frame in normalized)
            self._sample_count_since_perf += len(normalized)
        self._emit("samples", {"frames": normalized})

    def _publish_perf(self, now: float) -> None:
        with self._lock:
            interval = max(now - self._last_perf_at, 0.001)
            metrics = self._memory.last_read_metrics
            payload = {
                "effectiveHz": self._sample_count_since_perf / interval,
                "sampleCount": self._sample_count_since_perf,
                "watchCount": len(self._watches),
                "readBlockCount": metrics.get("block_count", 0),
                "readByteCount": metrics.get("byte_count", 0),
                "rttTransport": (
                    self._normal_rtt.transport_name if self._rtt_protocol == "normal" else self._plus_rtt.transport_name
                ),
            }
            self._sample_count_since_perf = 0
            self._last_perf_at = now
        self._emit("perf", payload)

    def _stop_rtt_locked(self) -> None:
        self._normal_rtt.stop()
        self._plus_rtt.stop()
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0

    def _elapsed_locked(self, now: float | None = None) -> float:
        if self._connection_started_at is None:
            return 0.0
        return max(0.0, (now if now is not None else time.monotonic()) - self._connection_started_at)

    @staticmethod
    def _symbol_json(symbol: SymbolInfo) -> dict[str, object]:
        return {
            "key": symbol.key,
            "source": symbol.source_file,
            "name": symbol.name,
            "address": symbol.address,
            "type": symbol.kind,
            "size": symbol.size,
            "section": symbol.section,
            "writable": symbol.is_writable,
            "dataSource": symbol.data_source,
        }

    @staticmethod
    def _watch_json(watch: WatchedVariable) -> dict[str, object]:
        return {
            "key": watch.symbol.key,
            "color": watch.color,
            "plotted": watch.plot_enabled,
            "value": _json_value(watch.value),
        }

    def _emit(self, name: str, params: object) -> None:
        self._emit_event(name, params)


def _required_string(values: Mapping[str, object], name: str) -> str:
    value = values.get(name)
    if not isinstance(value, str):
        raise ProtocolError("invalid_request", f"{name} must be a string.")
    return value


def _optional_string(values: Mapping[str, object], name: str) -> str | None:
    value = values.get(name)
    return value if isinstance(value, str) else None


def _positive_number(value: object, name: str) -> float:
    if isinstance(value, bool):
        raise ProtocolError("invalid_request", f"{name} must be a number.")
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise ProtocolError("invalid_request", f"{name} must be a number.") from error
    if not math.isfinite(number) or number <= 0:
        raise ProtocolError("invalid_request", f"{name} must be a positive finite number.")
    return number


def _optional_address(value: object) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError as error:
            raise ProtocolError("invalid_request", "controlBlockAddress must be a valid integer address.") from error
    raise ProtocolError("invalid_request", "controlBlockAddress must be an integer address.")


def _target_override(target_name: str) -> str | None:
    normalized = target_name.strip()
    return None if not normalized or normalized.casefold() == "auto" else normalized


def _probe_filter(probe_type: str) -> str | None:
    value = probe_type.strip().casefold()
    if not value or "自动" in probe_type or "auto" in value:
        return None
    if "cmsis" in value or "dap" in value:
        return "cmsis-dap"
    if "st-link" in value or "stlink" in value:
        return "st-link"
    if "j-link" in value or "jlink" in value:
        return "j-link"
    return probe_type.strip()


def _parse_frequency_hz(text: str) -> int:
    normalized = text.strip().lower().replace(" ", "")
    factors = {"mhz": 1_000_000, "khz": 1_000, "hz": 1}
    for suffix, factor in factors.items():
        if normalized.endswith(suffix):
            normalized = normalized[: -len(suffix)]
            try:
                value = float(normalized) * factor
            except ValueError as error:
                raise ProtocolError("invalid_request", "swdClock must be a valid frequency.") from error
            if not math.isfinite(value) or not 1_000 <= value <= 100_000_000:
                raise ProtocolError("invalid_request", "swdClock must be between 1 kHz and 100 MHz.")
            return int(round(value))
    raise ProtocolError("invalid_request", "swdClock must include Hz, kHz, or MHz.")


def _json_value(value: object) -> object:
    if isinstance(value, bool | int | str) or value is None:
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    return str(value)


def _csv_value(value: object | None) -> object:
    return "" if value is None else value
