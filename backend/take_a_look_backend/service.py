from __future__ import annotations

import csv
import math
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from pathlib import Path

from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend
from take_a_look_backend.models import SymbolInfo, WatchedVariable, json_value
from take_a_look_backend.protocol import EventName, PROTOCOL_VERSION, ProtocolError, RpcMethod
from take_a_look_backend.services.sampling import SamplingServiceMixin
from take_a_look_backend.services.debug_info import DebugInfoIndex, load_debug_info_from_elf
from take_a_look_backend.services.symbols import load_symbols_from_elf


EventSink = Callable[[EventName, object], None]
SymbolLoader = Callable[[Path], list[SymbolInfo]]
DebugInfoLoader = Callable[[Path], DebugInfoIndex]


class BackendService(SamplingServiceMixin):
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
        debug_info_loader: DebugInfoLoader = load_debug_info_from_elf,
    ) -> None:
        self._emit_event = event_sink
        self._memory = memory_backend or PyOcdMemoryBackend()
        self._normal_rtt = normal_rtt_backend or JScopeRttBackend()
        self._plus_rtt = plus_rtt_backend or JScopeRttPlusBackend()
        self._symbol_loader = symbol_loader
        self._debug_info_loader = debug_info_loader
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
        self._debug_info = DebugInfoIndex()
        self._requested_breakpoints: dict[str, set[int]] = {}
        self._resolved_breakpoints: list[dict[str, object]] = []
        self._target_execution_state = "unavailable"
        self._stopped_location: dict[str, object] | None = None
        self._registers: dict[str, int] = {}
        self._next_debug_poll_at = 0.0
        self._sampler.start()

    def close(self) -> None:
        self._shutdown.set()
        self._wake.set()
        self._sampler.join(timeout=2.0)
        with self._lock:
            self._stop_rtt_locked()
            self._remove_all_breakpoints_locked()
            self._memory.disconnect()
            self._connection_status = "disconnected"

    def handle(self, method: RpcMethod, params: Mapping[str, object]) -> dict[str, object]:
        if method is RpcMethod.HANDSHAKE:
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
                    "sourceDebug",
                    "breakpoints",
                    "runControl",
                ],
                "state": self.state_snapshot(),
            }
        if method is RpcMethod.GET_STATE:
            return {"state": self.state_snapshot()}
        if method is RpcMethod.CONNECT:
            return self._connect(params)
        if method is RpcMethod.TOGGLE_CONNECTION:
            return self._disconnect() if self._connection_status == "connected" else self._connect(params)
        if method is RpcMethod.DISCONNECT:
            return self._disconnect()
        if method is RpcMethod.LOAD_SYMBOLS:
            return self._load_symbols(params)
        if method is RpcMethod.SET_CONFIG:
            return self._set_config(params)
        if method is RpcMethod.SET_WATCHES:
            return self._set_watches(params)
        if method is RpcMethod.WRITE_WATCH:
            return self._write_watch(params)
        if method is RpcMethod.SET_SAMPLING_PAUSED:
            return self._set_sampling_paused(params)
        if method is RpcMethod.SET_RTT:
            return self._set_rtt(params)
        if method is RpcMethod.CLEAR_SAMPLES:
            return self._clear_samples()
        if method is RpcMethod.RESET_TARGET:
            return self._reset_target(params)
        if method is RpcMethod.GET_DEBUG_INFO:
            return self._get_debug_info()
        if method is RpcMethod.SET_BREAKPOINTS:
            return self._set_breakpoints(params)
        if method is RpcMethod.DEBUG_CONTROL:
            return self._debug_control(params)
        if method is RpcMethod.EXPORT_CSV:
            return self._export_csv(params)
        if method is RpcMethod.SHUTDOWN:
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
            "debug": self._debug_state_locked(),
        }

    def _connect(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            if self._connection_status == "connected":
                return {"state": self._runtime_state_locked()}
            self._apply_config_locked(params)
            self._connection_status = "connecting"
            connecting_state = self._runtime_state_locked()
        self._emit(EventName.STATE, connecting_state)
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
            self._emit(EventName.LOG, {"level": "error", "message": f"连接调试探针失败：{error}"})
            self._emit(EventName.STATE, failed_state)
            raise ProtocolError("connect_failed", "Unable to connect to the debug probe.", str(error)) from error
        with self._lock:
            self._connection_status = "connected"
            self._connection_started_at = time.monotonic()
            self._sampling_paused = False
            self._target_execution_state = "running"
            self._apply_all_breakpoints_locked()
            state = self._runtime_state_locked()
        self._emit(EventName.LOG, {"level": "info", "message": "已连接 pyOCD 调试探针。"})
        self._emit(EventName.STATE, state)
        self._wake.set()
        return {"state": state}

    def _disconnect(self) -> dict[str, object]:
        with self._lock:
            self._stop_rtt_locked()
            self._remove_all_breakpoints_locked()
            self._memory.disconnect()
            self._connection_status = "disconnected"
            self._connection_started_at = None
            self._sampling_paused = False
            self._target_execution_state = "unavailable"
            self._stopped_location = None
            self._registers = {}
            self._mark_breakpoints_pending_locked()
            state = self._runtime_state_locked()
        self._emit(EventName.LOG, {"level": "info", "message": "已断开调试探针。"})
        self._emit(EventName.STATE, state)
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
        try:
            debug_info = self._debug_info_loader(path)
        except Exception as error:
            debug_info = DebugInfoIndex()
            self._emit(EventName.LOG, {"level": "warning", "message": f"无法读取源码行调试信息：{error}"})
        with self._lock:
            self._remove_all_breakpoints_locked()
            self._symbols = {symbol.key: symbol for symbol in symbols}
            self._symbol_file = str(path)
            self._debug_info = debug_info
            # Watches are only valid for symbols in the current file. RTT symbols
            # are recreated after a connection is established.
            self._watches = {
                key: watch for key, watch in self._watches.items() if key in self._symbols
            }
            self._apply_all_breakpoints_locked()
        self._emit(EventName.LOG, {"level": "info", "message": f"已读取符号文件：{path.name}，变量 {len(symbols)} 个。"})
        state = self.state_snapshot()
        self._emit(EventName.STATE, state)
        return {"state": state, "symbolFile": str(path)}

    def _get_debug_info(self) -> dict[str, object]:
        with self._lock:
            return {
                "sourceFiles": self._debug_info.source_files,
                "executableLines": self._debug_info.executable_lines,
                "debug": self._debug_state_locked(),
            }

    def _set_breakpoints(self, params: Mapping[str, object]) -> dict[str, object]:
        path = _required_string(params, "path")
        raw_lines = params.get("lines")
        if not isinstance(raw_lines, list) or any(
            isinstance(line, bool) or not isinstance(line, int) or line <= 0 for line in raw_lines
        ):
            raise ProtocolError("invalid_request", "lines must contain positive integers.")
        with self._lock:
            canonical_path = self._debug_info.canonical_source_path(path) or path
            canonical_key = canonical_path.replace("\\", "/").rstrip("/").casefold()
            # Source-root mappings and DWARF can name one file with different
            # absolute paths. Keep one authoritative breakpoint set so a
            # removal cannot reveal a stale alias on the next state event.
            for existing_path in list(self._requested_breakpoints):
                existing_canonical = (
                    self._debug_info.canonical_source_path(existing_path)
                    or existing_path
                )
                existing_key = (
                    existing_canonical.replace("\\", "/").rstrip("/").casefold()
                )
                if existing_key == canonical_key:
                    del self._requested_breakpoints[existing_path]
            if raw_lines:
                self._requested_breakpoints[canonical_path] = set(raw_lines)
            self._apply_all_breakpoints_locked()
            payload = self._debug_state_locked()
        self._emit(EventName.DEBUG, payload)
        return {"debug": payload}

    def _debug_control(self, params: Mapping[str, object]) -> dict[str, object]:
        action = _required_string(params, "action")
        if action not in {"halt", "resume", "step"}:
            raise ProtocolError("invalid_request", "action must be halt, resume, or step.")
        with self._lock:
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "Connect a debug probe before controlling the target.")
            try:
                if action == "halt":
                    self._memory.halt()
                elif action == "resume":
                    self._continue_or_step_locked(resume=True)
                else:
                    self._continue_or_step_locked(resume=False)
                self._refresh_debug_state_locked(force=True)
            except Exception as error:
                raise ProtocolError("debug_control_failed", "Unable to control the target.", str(error)) from error
            payload = self._debug_state_locked()
        return {"debug": payload}

    def _continue_or_step_locked(self, *, resume: bool) -> None:
        registers = self._registers or self._memory.read_core_registers()
        pc = registers.get("pc")
        current_breakpoint = next(
            (
                item
                for item in self._resolved_breakpoints
                if item.get("verified") is True
                and isinstance(item.get("address"), int)
                and pc is not None
                and (item["address"] & ~1) == (pc & ~1)
            ),
            None,
        )
        if current_breakpoint is None:
            if resume:
                self._memory.resume()
            else:
                self._memory.step()
            return

        address = int(current_breakpoint["address"])
        self._memory.remove_breakpoint(address)
        try:
            self._memory.step()
        finally:
            restored = self._memory.set_breakpoint(address)
            if not restored:
                current_breakpoint["verified"] = False
                current_breakpoint["message"] = "跨过断点后无法重新设置该断点。"
        if resume:
            self._memory.resume()

    def _debug_state_locked(self) -> dict[str, object]:
        return {
            "executionState": self._target_execution_state,
            "sourceFiles": self._debug_info.source_files,
            "executableLines": self._debug_info.executable_lines,
            "breakpoints": list(self._resolved_breakpoints),
            "registers": dict(self._registers),
            "stoppedLocation": self._stopped_location,
        }

    def _poll_debug_state_locked(self) -> None:
        try:
            self._refresh_debug_state_locked(force=False)
        except Exception:
            # Sampling and a temporarily inaccessible target should recover on
            # their next poll without turning a transient status read into a
            # transport-level failure.
            return

    def _refresh_debug_state_locked(self, *, force: bool) -> None:
        next_state = self._memory.debug_state()
        if not force and next_state == self._target_execution_state:
            return
        self._target_execution_state = next_state
        if next_state == "halted":
            self._registers = self._memory.read_core_registers()
            pc = self._registers.get("pc", 0)
            location = self._debug_info.resolve_address(pc)
            self._stopped_location = {"address": pc}
            if location is not None:
                self._stopped_location.update({"path": location.path, "line": location.line})
        else:
            self._registers = {}
            self._stopped_location = None
        self._emit(EventName.DEBUG, self._debug_state_locked())

    def _remove_all_breakpoints_locked(self) -> None:
        if self._connection_status == "connected":
            for item in self._resolved_breakpoints:
                if item.get("verified") is True and isinstance(item.get("address"), int):
                    try:
                        self._memory.remove_breakpoint(item["address"])
                    except Exception:
                        pass
        self._resolved_breakpoints = []

    def _mark_breakpoints_pending_locked(self) -> None:
        self._resolved_breakpoints = [
            {
                "path": path,
                "requestedLine": line,
                "actualLine": line,
                "verified": False,
                "message": "连接调试探针后设置断点。",
            }
            for path, lines in self._requested_breakpoints.items()
            for line in sorted(lines)
        ]

    def _apply_all_breakpoints_locked(self) -> None:
        self._remove_all_breakpoints_locked()
        resolved: list[dict[str, object]] = []
        for path, lines in self._requested_breakpoints.items():
            for requested_line in sorted(lines):
                location = self._debug_info.resolve_breakpoint(path, requested_line)
                item: dict[str, object] = {
                    "path": path,
                    "requestedLine": requested_line,
                    "actualLine": location.line if location is not None else requested_line,
                    "verified": False,
                }
                if location is None:
                    item["message"] = "该行没有可执行指令，不能设置断点。"
                else:
                    item["path"] = location.path
                    item["address"] = location.address
                    if self._connection_status != "connected":
                        item["message"] = "连接调试探针后设置断点。"
                    else:
                        try:
                            item["verified"] = self._memory.set_breakpoint(location.address)
                            if not item["verified"]:
                                item["message"] = "目标拒绝了断点，可能已用完硬件断点资源。"
                        except Exception as error:
                            item["message"] = str(error)
                resolved.append(item)
        self._resolved_breakpoints = resolved

    def _set_config(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            self._apply_config_locked(params)
            state = self._runtime_state_locked()
        self._emit(EventName.STATE, state)
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
        self._emit(EventName.STATE, state)
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
        self._emit(EventName.LOG, {"level": "info", "message": f"已写入 {watch.symbol.name} 并完成回读验证。"})
        self._emit(EventName.STATE, state)
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
        self._emit(EventName.LOG, {"level": "info", "message": "采样已暂停。" if paused else "采样已继续。"})
        self._emit(EventName.STATE, state)
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
        self._emit(EventName.STATE, state)
        self._wake.set()
        return {"state": state}

    def _clear_samples(self) -> dict[str, object]:
        with self._lock:
            self._samples.clear()
            self._connection_started_at = time.monotonic() if self._connection_status == "connected" else None
            self._sample_count_since_perf = 0
            state = {"elapsedSeconds": 0.0, "sampleCount": 0}
        self._emit(EventName.SAMPLES_CLEARED, {})
        self._emit(EventName.STATE, state)
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
        self._emit(EventName.LOG, {"level": "info", "message": "目标已复位并暂停。" if halt else "目标已复位并运行。"})
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
        self._emit(EventName.LOG, {"level": "info", "message": f"已导出 {len(frames)} 帧原始采样 CSV：{path}"})
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
            "value": json_value(watch.value),
        }

    def _emit(self, name: EventName, params: object) -> None:
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


def _csv_value(value: object | None) -> object:
    return "" if value is None else value
