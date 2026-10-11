from __future__ import annotations

import math
from contextlib import ExitStack
import threading
import time
from collections.abc import Callable, Mapping
from pathlib import Path

from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend
from take_a_look_backend.backends.remote_backend import CONNECTION_KINDS, REMOTE_DEFAULTS, RemoteMemoryBackend
from take_a_look_backend.backends.ember_transport import EmberError
from take_a_look_backend.models import SymbolInfo, WatchedVariable, json_value
from take_a_look_backend.protocol import EventName, PROTOCOL_VERSION, ProtocolError, RpcMethod
from take_a_look_backend.services.sampling import SamplingServiceMixin
from take_a_look_backend.services.ordered_worker import OrderedWorker
from take_a_look_backend.services.recording import RawRecording, export_recording_csv
from take_a_look_backend.services.debug_info import DebugInfoIndex, load_debug_info_from_elf
from take_a_look_backend.services.symbols import load_symbols_from_elf
from take_a_look_backend.services.elf_context import ElfLoadContext


EventSink = Callable[[EventName, object], None]
SymbolLoader = Callable[..., list[SymbolInfo]]
DebugInfoLoader = Callable[..., DebugInfoIndex]
SYMBOL_LOAD_TIMEOUT_SECONDS = 600


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
        remote_backend_factory: Callable[..., RemoteMemoryBackend] = RemoteMemoryBackend,
        recording_directory: Path | None = None,
    ) -> None:
        self._emit_event = event_sink
        self._memory = memory_backend or PyOcdMemoryBackend()
        self._local_memory = self._memory
        self._remote_backend_factory = remote_backend_factory
        self._normal_rtt = normal_rtt_backend or JScopeRttBackend()
        self._plus_rtt = plus_rtt_backend or JScopeRttPlusBackend()
        self._symbol_loader = symbol_loader
        self._debug_info_loader = debug_info_loader
        self._lock = threading.RLock()
        self._perf_lock = threading.Lock()
        self._closed = False
        self._wake = threading.Event()
        self._shutdown = threading.Event()
        self._sampler = threading.Thread(target=self._sampling_loop, name="tal-sampler", daemon=True)

        self._connection_status = "disconnected"
        self._probe_type = "自动发现任意探针"
        self._target_name = "auto"
        self._swd_clock = "4 MHz"
        self._serial_number = ""
        self._connection_kind = "local"
        self._remote_config = dict(REMOTE_DEFAULTS)
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
        self._recording = RawRecording(recording_directory)
        self._recording_worker = OrderedWorker('tal-recording')
        self._pipeline_backpressure = False
        self._recording_error_reported = False
        self._pending_frames: list[tuple[float, dict[str, object]]] = []
        self._pending_recording_frames: list[tuple[float, dict[str, object]]] = []
        self._pending_recording_labels: dict[str, str] = {}
        self._sample_count_since_perf = 0
        self._perf_window_started_at = time.perf_counter()
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
        if self._closed:
            return
        self._closed = True
        self._shutdown.set()
        self._wake.set()
        self._sampler.join(timeout=2.0)
        try:
            with self._lock:
                try:
                    self._flush_pending_samples_locked()
                    self._recording_worker.drain()
                    self._recording.close()
                finally:
                    self._stop_rtt_locked()
                    self._remove_all_breakpoints_locked()
                    self._memory.disconnect()
                    self._connection_status = "disconnected"
        finally:
            self._recording_worker.close()

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
                    "emberMobile",
                    "remoteGdb",
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
            "connectionKind": self._connection_kind,
            "remoteConfig": dict(self._remote_config),
            "gatewayProtocolVersion": getattr(getattr(self._memory, "client", None), "protocol_version", None),
            "connectionCapabilities": {
                "memorySampling": self._connection_kind in {"local", "ember"},
                "memoryWrite": self._connection_kind != "ember",
                "rtt": self._connection_kind != "gdb",
            },
            "sampleRateHz": self._sample_rate_hz,
            "rttSampleRateHz": self._rtt_sample_rate_hz,
            "samplingPaused": self._sampling_paused,
            "rttEnabled": self._rtt_enabled,
            "rttProtocol": self._rtt_protocol,
            "rttControlBlockAddress": self._rtt_control_block_address,
            "symbolFile": self._symbol_file,
            "elapsedSeconds": self._elapsed_locked(),
            "sampleCount": self._recording.sample_count,
            "rawRecording": self._recording.status(),
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
            self._memory = (self._local_memory if self._connection_kind == "local" else
                            self._remote_backend_factory(self._connection_kind, self._remote_config))
            config = PyOcdConnectionConfig(
                target=_target_override(self._target_name),
                frequency_hz=_parse_frequency_hz(self._swd_clock),
                unique_id=self._serial_number.strip() or None,
                probe_filter=_probe_filter(self._probe_type),
            )
            self._memory.connect(config)
            initial_execution_state = self._memory.debug_state()
            # A successful reconnect restarts the time axis. Keep the previous
            # journal on disk and start a fresh plot/recording epoch together.
            self._clear_samples()
            with self._lock:
                self._target_execution_state = initial_execution_state
                self._refresh_debug_state_locked(force=True)
        except Exception as error:
            try:
                self._memory.disconnect()
            except Exception:
                pass
            with self._lock:
                self._connection_status = "disconnected"
                self._target_execution_state = "unavailable"
                self._stopped_location = None
                self._registers = {}
                failed_state = self._runtime_state_locked()
            self._emit(EventName.LOG, {"level": "error", "message": f"连接调试探针失败：{error}"})
            self._emit(EventName.STATE, failed_state)
            raise ProtocolError("connect_failed", "Unable to connect to the debug probe.", str(error)) from error
        with self._lock:
            self._connection_status = "connected"
            self._connection_started_at = time.perf_counter()
            self._sampling_paused = False
            self._target_execution_state = initial_execution_state
            self._apply_all_breakpoints_locked()
            state = self._runtime_state_locked()
        label = {"local": "pyOCD 调试探针", "ember": "EmberMobile 私有协议",
                 "emberGdb": "EmberMobile + GDB", "gdb": "远程 GDB"}[self._connection_kind]
        self._emit(EventName.LOG, {"level": "info", "message": f"已连接 {label}。"})
        self._emit(EventName.STATE, state)
        self._wake.set()
        return {"state": state}

    def _disconnect(self) -> dict[str, object]:
        with self._lock:
            self._flush_pending_samples_locked()
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
        load_id = params.get("loadId")
        deadline = time.perf_counter() + SYMBOL_LOAD_TIMEOUT_SECONDS
        last_phase = ""
        last_report_at = 0.0

        def report_progress(phase: str, current: int = 0, total: int = 0) -> None:
            nonlocal last_phase, last_report_at
            now = time.perf_counter()
            # Also checked before committing, so a late parse cannot replace
            # the previous symbols after the frontend has timed out.
            if now > deadline:
                raise ProtocolError("symbol_load_timeout", "读取 ELF 文件超时，请检查文件后重试。")
            if phase == last_phase and current != total and now - last_report_at < 0.1:
                return
            last_phase, last_report_at = phase, now
            self._emit(EventName.SYMBOL_LOAD_PROGRESS, {
                "loadId": load_id, "path": path_text, "phase": phase,
                "current": current, "total": total,
            })

        report_progress("check")
        path = Path(path_text).expanduser()
        if not path.is_file():
            raise ProtocolError("file_not_found", "Symbol file does not exist.", str(path))
        if path.suffix.lower() not in {".elf", ".axf"}:
            raise ProtocolError("unsupported_symbol_file", "Symbol file must use .elf or .axf.", str(path))
        with ExitStack() as resources:
            try:
                options = {}
                if self._symbol_loader is load_symbols_from_elf and self._debug_info_loader is load_debug_info_from_elf:
                    options["context"] = resources.enter_context(ElfLoadContext(path))
                symbols = self._symbol_loader(path, progress=report_progress, **options)
            except ProtocolError:
                raise
            except Exception as error:
                raise ProtocolError("symbol_load_failed", "Unable to parse the symbol file.", str(error)) from error
            try:
                report_progress("source")
                debug_info = self._debug_info_loader(path, progress=report_progress, **options)
            except ProtocolError:
                raise
            except Exception as error:
                debug_info = DebugInfoIndex()
                self._emit(EventName.LOG, {"level": "warning", "message": f"无法读取源码行调试信息：{error}"})
        with self._lock:
            report_progress("ui")
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
        if getattr(self._memory, "manages_breakpoint_step", False):
            if resume:
                self._memory.resume()
            else:
                self._memory.step()
            return
        if resume and self._memory.debug_state() == "running":
            return
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
        except Exception as error:
            if self._handle_remote_failure_locked(error):
                return
            # Sampling and a temporarily inaccessible target should recover on
            # their next poll without turning a transient status read into a
            # transport-level failure.
            return

    def _handle_remote_failure_locked(self, error: Exception) -> bool:
        fatal = isinstance(error, (ConnectionError, TimeoutError, OSError)) or (
            isinstance(error, EmberError) and error.code in {"unauthorized", "stale_session", "not_attached"})
        if self._connection_kind == "local" or not fatal:
            return False
        self._stop_rtt_locked()
        self._memory.disconnect()
        self._connection_status = "disconnected"
        self._connection_started_at = None
        self._target_execution_state = "unavailable"
        self._stopped_location = None
        self._registers = {}
        self._mark_breakpoints_pending_locked()
        self._emit(EventName.LOG, {"level": "error", "message": f"远程连接已中断：{error}"})
        self._emit(EventName.STATE, self._runtime_state_locked())
        return True

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
            if not getattr(self._memory, "supports_running_memory", True):
                symbols = [watch.symbol for watch in self._watches.values() if not watch.symbol.is_rtt]
                if symbols:
                    for key, value in self._memory.read_symbols(symbols).items():
                        self._watches[key].value = value
                    self._emit(EventName.STATE, {"watches": [self._watch_json(w) for w in self._watches.values()]})
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
                    sampling_enabled=bool(
                        raw.get("sampling", old.sampling_enabled if old else True)
                    ),
                    value=old.value if old else "",
                )
            self._watches = new_watches
            if (self._connection_status == "connected" and self._target_execution_state == "halted"
                    and not getattr(self._memory, "supports_running_memory", True)):
                self._refresh_debug_state_locked(force=True)
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
            if not getattr(self._memory, "supports_memory_write", True):
                raise ProtocolError("unsupported_operation", "EmberMobile 私有协议不支持内存写入，请使用 GDB。")
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
            if not paused and self._recording.failure is not None:
                self._emit(EventName.STATE, {"samplingPaused": True})
                raise ProtocolError("raw_recording_failed", "请解决记录写入错误后清空采样，开启新记录。")
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
            if enabled and self._connection_kind == "gdb":
                raise ProtocolError("unsupported_operation", "独立 GDB 连接不提供 RTT，请使用 EmberMobile + GDB。")
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
            self._flush_pending_samples_locked()
            self._pending_frames.clear()
            self._pending_recording_frames.clear()
            self._pending_recording_labels.clear()
            self._recording_worker.drain()
            self._recording.rotate()
            self._pipeline_backpressure = False
            self._recording_error_reported = False
            self._connection_started_at = time.perf_counter() if self._connection_status == "connected" else None
            self._sample_count_since_perf = 0
            state = {"elapsedSeconds": 0.0, "sampleCount": 0, "rawRecording": self._recording.status()}
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
                self._stop_rtt_locked()
                self._memory.reset(halt=halt)
                self._refresh_debug_state_locked(force=True)
            except Exception as error:
                raise ProtocolError("reset_failed", "Unable to reset target.", str(error)) from error
        self._emit(EventName.LOG, {"level": "info", "message": "目标已复位并暂停。" if halt else "目标已复位并运行。"})
        with self._lock:
            return {"state": self._runtime_state_locked()}

    def prepare_csv_export(self, params: Mapping[str, object]):
        path = Path(_required_string(params, "path")).expanduser()
        if path.suffix.lower() != ".csv":
            path = path.with_suffix(".csv")
        with self._lock:
            self._flush_pending_samples_locked(wait=False, block=True)
            # This ordered fence captures the click's committed prefix. Later
            # batches, clear, or reconnect cannot move the export boundary.
            snapshot = self._recording_worker.submit(self._recording.snapshot)
        return path, snapshot

    def finish_csv_export(self, prepared) -> dict[str, object]:
        path, snapshot = prepared
        try:
            source, boundary, expected_count = snapshot.result()
        except ValueError as error:
            raise ProtocolError("no_samples", "There are no samples to export.") from error
        count = export_recording_csv(source, path, boundary)
        if count != expected_count:
            raise ProtocolError("recording_incomplete", "Raw recording row count mismatch.")
        self._emit(EventName.LOG, {"level": "info", "message": f"已导出 {count} 帧完整原始采样 CSV：{path}"})
        return {"path": str(path), "sampleCount": count}

    def _export_csv(self, params: Mapping[str, object]) -> dict[str, object]:
        return self.finish_csv_export(self.prepare_csv_export(params))

    def _apply_config_locked(self, params: Mapping[str, object]) -> None:
        kind = params.get("connectionKind", self._connection_kind)
        if not isinstance(kind, str) or kind not in CONNECTION_KINDS:
            raise ProtocolError("invalid_request", "Unknown connectionKind.")
        remote = params.get("remoteConfig", {})
        if not isinstance(remote, Mapping) or any(key not in REMOTE_DEFAULTS for key in remote):
            raise ProtocolError("invalid_request", "Invalid remoteConfig fields.")
        if any(not isinstance(value, str) for value in remote.values()):
            raise ProtocolError("invalid_request", "remoteConfig values must be strings.")
        merged = {**self._remote_config, **remote}
        if self._connection_status != "disconnected" and (kind != self._connection_kind or merged != self._remote_config):
            raise ProtocolError("already_connected", "请先断开连接，再修改远程连接设置。")
        self._connection_kind = kind
        self._remote_config = merged
        if kind == "gdb":
            self._rtt_enabled = False
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
            "sampling": watch.sampling_enabled,
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
