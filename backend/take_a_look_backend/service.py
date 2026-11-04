from __future__ import annotations

import math
from contextlib import ExitStack
import threading
import time
from collections.abc import Callable, Mapping
from pathlib import Path

from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.backends.target_backend import TargetBackend, backend_capabilities, capabilities_for_connection
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend
from take_a_look_backend.backends.remote_backend import CONNECTION_KINDS, REMOTE_DEFAULTS, RemoteMemoryBackend
from take_a_look_backend.backends.ember_transport import EmberError
from take_a_look_backend.backends.ember_pairing import PairingManager
from take_a_look_backend.models import SymbolInfo, WatchedVariable, json_value
from take_a_look_backend.protocol import EventName, PROTOCOL_VERSION, ProtocolError, RpcMethod
from take_a_look_backend.services.sampling import SamplingServiceMixin
from take_a_look_backend.services.sample_pipeline import SamplePipeline
from take_a_look_backend.services.recording import RawRecording, export_recording_csv
from take_a_look_backend.services.debug_info import DebugInfoIndex, load_debug_info_from_elf
from take_a_look_backend.services.debug_session import DebugSession
from take_a_look_backend.services.symbols import load_symbols_from_elf
from take_a_look_backend.services.elf_context import ElfLoadContext
from take_a_look_backend.services.source_project import SourceProjects
from take_a_look_backend.services.source_tasks import SourceTasks
from take_a_look_backend.services.target_catalog import TargetCatalog
from take_a_look_backend.services.online_packs import OnlinePacks
from take_a_look_backend.services.freertos import FreeRtosInspector
from take_a_look_backend.services.freertos_layout import FreeRtosLayout
from take_a_look_backend.services.freertos_service import FreeRtosServiceMixin
from take_a_look_backend.backends.rtt_session import RttSessionManager


EventSink = Callable[[EventName, object], None]
SymbolLoader = Callable[..., list[SymbolInfo]]
DebugInfoLoader = Callable[..., DebugInfoIndex]
SYMBOL_LOAD_TIMEOUT_SECONDS = 600


class BackendService(SamplingServiceMixin, FreeRtosServiceMixin):
    """Owns hardware state and exposes it through a small command surface.

    pyOCD access is serialized by ``_lock``. The sampler runs on one worker
    thread so blocking a probe never blocks JSON-RPC input or Flutter's UI.
    """

    def __init__(
        self,
        event_sink: EventSink,
        *,
        memory_backend: TargetBackend | None = None,
        normal_rtt_backend: JScopeRttBackend | None = None,
        plus_rtt_backend: JScopeRttPlusBackend | None = None,
        symbol_loader: SymbolLoader = load_symbols_from_elf,
        debug_info_loader: DebugInfoLoader = load_debug_info_from_elf,
        remote_backend_factory: Callable[..., TargetBackend] = RemoteMemoryBackend,
        recording_directory: Path | None = None,
        source_settings_file: Path | None = None,
        target_directory: Path | None = None,
        bundled_target_directory: Path | None = None,
    ) -> None:
        self._emit_event = event_sink
        self._memory: TargetBackend = memory_backend or PyOcdMemoryBackend()
        self._local_memory = self._memory
        self._remote_backend_factory = remote_backend_factory
        self._rtt_sessions = RttSessionManager()
        self._normal_rtt = normal_rtt_backend or JScopeRttBackend(self._rtt_sessions)
        self._plus_rtt = plus_rtt_backend or JScopeRttPlusBackend(self._rtt_sessions)
        self._freertos = FreeRtosInspector()
        self._freertos_snapshot: dict = {}
        self._freertos_enabled = False
        self._freertos_watch_identity = {}
        self._freertos_rate = 2.0
        self._freertos_tick_hz: int | None = None
        self._next_freertos_at = 0.0
        self._symbol_loader = symbol_loader
        self._debug_info_loader = debug_info_loader
        self._lock = threading.RLock()
        self._connection_lock = threading.RLock()
        self._control_lock = threading.Lock()
        self._control_count = 0
        self._controls_idle = threading.Event()
        self._controls_idle.set()
        self._closed = False
        self._wake = threading.Event()
        self._shutdown = threading.Event()
        self._sampler = threading.Thread(target=self._sampling_loop, name="tal-sampler", daemon=True)

        self._connection_status = "disconnected"
        self._probe_type = "自动发现任意探针"
        self._targets = TargetCatalog(target_directory, bundled_directory=bundled_target_directory)
        self._online_packs = OnlinePacks(self._targets, self._publish_target_state)
        self._target_name = str(self._targets.selected["name"])
        self._swd_clock = "4 MHz"
        self._serial_number = ""
        self._connection_kind = "local"
        self._remote_config = dict(REMOTE_DEFAULTS)
        self._ember_pairing = PairingManager()
        self._sample_rate_hz = 50.0
        self._monitor_rate_hz = 10.0
        self._monitor_schedule_revision = 0
        self._latest_rtt_values: dict[str, tuple[object, int]] = {}
        self._rtt_sample_rate_hz = 1000.0
        self._sampling_paused = False
        self._rtt_enabled = False
        self._rtt_protocol = "normal"
        self._rtt_control_block_address: int | None = None
        self._symbol_file = ""
        self._connection_started_at: float | None = None
        self._symbols: dict[str, SymbolInfo] = {}
        self._watches: dict[str, WatchedVariable] = {}
        self._capture_source = None
        self._capture_source_count = -1
        self._capture_symbols: tuple[SymbolInfo, ...] = ()
        self._recording = RawRecording(recording_directory)
        self._pipeline = SamplePipeline(self._recording, self._emit, self._recording_failed, self._wake)
        self._perf_window_started_at = time.perf_counter()
        self._last_perf_at = self._perf_window_started_at
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0
        self._debug = DebugSession()
        self._next_debug_poll_at = 0.0
        self._firmware_busy = False
        self._source_projects = SourceProjects(source_settings_file)
        self._source_tasks = SourceTasks(lambda payload: self._emit(EventName.SOURCE_TASK, payload), self._download_firmware)
        self._sampler.start()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._online_packs.close()
        self._ember_pairing.close()
        self._source_tasks.close()
        self._shutdown.set()
        self._wake.set()
        self._sampler.join(timeout=2.0)
        try:
            with self._lock:
                try:
                    self._flush_pending_samples_locked()
                    self._pipeline.drain()
                    self._recording.close()
                finally:
                    self._stop_rtt_locked()
                    self._rtt_sessions.close()
                    self._debug.remove_breakpoints(self._memory, connected=self._connection_status == "connected")
                    self._memory.disconnect()
                    self._connection_status = "disconnected"
        finally:
            self._pipeline.close()
            self._targets.close()

    def handle(self, method: RpcMethod, params: Mapping[str, object]) -> dict[str, object]:
        priority = method in {
            RpcMethod.WRITE_WATCH, RpcMethod.WRITE_WATCHES, RpcMethod.READ_WATCH,
            RpcMethod.SET_SAMPLING_PAUSED, RpcMethod.DEBUG_CONTROL, RpcMethod.RESET_TARGET,
            RpcMethod.DISCONNECT, RpcMethod.TOGGLE_CONNECTION, RpcMethod.SET_WATCHES,
            RpcMethod.SET_CONFIG, RpcMethod.SET_RTT, RpcMethod.CLEAR_SAMPLES,
            RpcMethod.SELECT_TARGET,
            RpcMethod.SET_MONITOR_VISIBILITY,
            RpcMethod.ADD_FREERTOS_WATCH, RpcMethod.GET_FREERTOS_STACK,
        }
        if not priority:
            return self._handle(method, params)
        with self._control_lock:
            self._control_count += 1
            self._controls_idle.clear()
        self._wake.set()
        try:
            return self._handle(method, params)
        finally:
            with self._control_lock:
                self._control_count -= 1
                if not self._control_count:
                    self._controls_idle.set()

    def _handle(self, method: RpcMethod, params: Mapping[str, object]) -> dict[str, object]:
        # Catalog requests run on a worker while connection controls arrive on
        # stdin. Keep reconnect and configuration changes in one transaction.
        if method in {RpcMethod.CONNECT, RpcMethod.DISCONNECT, RpcMethod.TOGGLE_CONNECTION,
                      RpcMethod.SET_CONFIG, RpcMethod.SELECT_TARGET}:
            with self._connection_lock:
                return self._handle_command(method, params)
        return self._handle_command(method, params)

    def _handle_command(self, method: RpcMethod, params: Mapping[str, object]) -> dict[str, object]:
        if method is RpcMethod.EMBER:
            operation = params.get("operation")
            if operation in {"pair", "forget"} and self._connection_status != "disconnected":
                raise ProtocolError("already_connected", "请先断开目标连接，再管理手机配对。")
            if operation in {"devices", "discover"}:
                return self._ember_pairing.devices(scan=operation == "discover")
            if operation == "status":
                return self._ember_pairing.status()
            if operation == "cancel":
                return self._ember_pairing.cancel()
            if operation == "pair":
                host = _required_string(params, "host").strip()
                port = int(str(params.get("port", "4242")))
                if not host or not 1 <= port <= 65535:
                    raise ProtocolError("invalid_request", "请填写有效的手机地址和端口。")
                import socket
                name = str(params.get("name") or socket.gethostname())
                if not 1 <= len(name.encode()) <= 96 or any(ord(c) < 32 or ord(c) == 127 for c in name):
                    raise ProtocolError("invalid_request", "电脑名称须为 1–96 字节且不含控制字符。")
                return self._ember_pairing.start(host, port, str(params.get("deviceId") or ""), name)
            if operation == "forget":
                result = self._ember_pairing.forget(_required_string(params, "deviceId"))
                if params["deviceId"] == self._remote_config.get("deviceId"):
                    self._remote_config["deviceId"] = ""
                    self._emit(EventName.STATE, {"remoteConfig": dict(self._remote_config)})
                return result
            raise ProtocolError("invalid_request", "未知的 EmberMobile 配对操作。")
        if method is RpcMethod.LIST_TARGETS:
            return {**self._targets.snapshot(), "state": self._targets.selection_state()}
        if method is RpcMethod.ONLINE_TARGET_PACKS:
            return self._online_packs.request(params)
        if method is RpcMethod.INSPECT_TARGET_PACK:
            return self._targets.inspect(_required_string(params, "path"))
        if method is RpcMethod.DISCARD_TARGET_PACK_PREVIEW:
            self._targets.discard_preview(_required_string(params, "previewId"))
            return {}
        if method is RpcMethod.IMPORT_TARGET_PACK:
            result = self._targets.import_pack(_required_string(params, "previewId"))
            return {**result, "state": self._publish_target_state()}
        if method is RpcMethod.REMOVE_TARGET_PACK:
            pack_id = _required_string(params, "packId")
            with self._lock:
                if (self._connection_kind == "local" and self._connection_status != "disconnected"
                        and self._targets.selected.get("packId") == pack_id):
                    raise ProtocolError("pack_in_use", "这个芯片包正在使用，请先断开连接。")
                self._targets.remove(pack_id)
            return {"state": self._publish_target_state()}
        if method is RpcMethod.SELECT_TARGET:
            name = _required_string(params, "name")
            pack_id = params.get("packId", "")
            if not isinstance(pack_id, str):
                raise ProtocolError("invalid_request", "packId must be a string.")
            with self._lock:
                if self._source_tasks.running and self._source_tasks.reserves_probe:
                    raise ProtocolError("source_task_busy", "下载任务执行中，请等待任务完成后更换芯片。")
                previous = self._targets.selected
                self._targets.select(name, pack_id)
                self._target_name = str(self._targets.selected["name"])
                changed = previous != self._targets.selected
                self._publish_target_state()
                if changed:
                    self._reconnect_target_locked()
                return {"state": self._runtime_state_locked()}
        if method is RpcMethod.CANCEL_SOURCE_TASK:
            result = self._source_tasks.cancel()
            self._emit(EventName.SOURCE_TASK, result)
            return {"sourceTask": result}
        if method is RpcMethod.SET_SOURCE_PROJECT:
            if self._source_tasks.running:
                raise ProtocolError("source_task_busy", "任务执行期间不能更换工程配置。")
            project = self._source_projects.select(dict(params))
            self._emit(EventName.STATE, {"sourceProject": project})
            return {"state": {"sourceProject": project}}
        if method is RpcMethod.START_SOURCE_TASK:
            kind = _required_string(params, "kind")
            config = dict(self._source_projects.current)
            if kind != "build":
                if not capabilities_for_connection(self._connection_kind).firmware_download:
                    raise ProtocolError("download_unsupported", "当前连接不支持固件下载，请使用本地 pyOCD 或 EmberMobile 连接。")
                if self._connection_status != "connected":
                    raise ProtocolError("not_connected", "请先连接调试目标。")
                if not str(config["firmwarePath"]).strip():
                    config["firmwarePath"] = self._symbol_file
            return {"sourceTask": self._source_tasks.start(kind, config)}
        if self._source_tasks.running:
            if method is RpcMethod.LOAD_SYMBOLS or (self._source_tasks.reserves_probe and method in {
                RpcMethod.CONNECT, RpcMethod.DISCONNECT, RpcMethod.TOGGLE_CONNECTION, RpcMethod.SET_CONFIG,
            }) or (self._firmware_busy and method in {
                RpcMethod.WRITE_WATCH, RpcMethod.WRITE_WATCHES, RpcMethod.READ_WATCH, RpcMethod.SET_WATCHES, RpcMethod.DEBUG_CONTROL, RpcMethod.SET_BREAKPOINTS,
                RpcMethod.SET_RTT, RpcMethod.SET_SAMPLING_PAUSED, RpcMethod.RESET_TARGET, RpcMethod.CLEAR_SAMPLES,
            }):
                raise ProtocolError("source_task_busy", "编译或下载任务执行中，请等待任务完成。")
        if method is RpcMethod.HANDSHAKE:
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": [
                    "symbols",
                    "memorySampling",
                    "watchReadModes",
                    "memoryWrite",
                    "memoryWriteBatch",
                    "rttNormal",
                    "rttPlus",
                    "csvExport",
                    "targetReset",
                    "sourceDebug",
                    "breakpoints",
                    "runControl",
                    "emberMobile",
                    "remoteGdb",
                    "sourceBuild",
                    "firmwareDownload",
                    "targetCatalog",
                    "freeRtos",
                    "rttSessions",
                ],
                "state": self.state_snapshot(),
            }
        if method is RpcMethod.GET_STATE:
            return {"state": self.state_snapshot()}
        if method is RpcMethod.CONFIGURE_FREERTOS:
            return self._configure_freertos(params)
        if method is RpcMethod.ADD_FREERTOS_WATCH:
            return self._add_freertos_watch(params)
        if method is RpcMethod.GET_FREERTOS_STACK:
            return self._freertos_stack(params)
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
        if method is RpcMethod.SET_MONITOR_VISIBILITY:
            return self._set_monitor_visibility(params)
        if method is RpcMethod.WRITE_WATCH:
            return self._write_watch(params)
        if method is RpcMethod.WRITE_WATCHES:
            return self._write_watches(params)
        if method is RpcMethod.READ_WATCH:
            return self._read_watch(params)
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
                "freeRtos": self._freertos_snapshot,
                "symbols": [self._symbol_json(symbol) for symbol in self._symbols.values()],
                "watches": [self._watch_json(watch) for watch in self._watches.values()],
                "sourceProject": self._source_projects.snapshot(),
                "sourceTask": self._source_tasks.snapshot(),
                "debug": self._debug.snapshot(include_definitions=True),
            }

    def _runtime_state_locked(self) -> dict[str, object]:
        return {
            **self._targets.selection_state(),
            "connectionStatus": self._connection_status,
            "probeType": self._probe_type,
            "targetName": self._target_name,
            "swdClock": self._swd_clock,
            "serialNumber": self._serial_number,
            "connectionKind": self._connection_kind,
            "remoteConfig": dict(self._remote_config),
            "gatewayProtocolVersion": getattr(getattr(self._memory, "client", None), "protocol_version", None),
            "connectionCapabilities": capabilities_for_connection(self._connection_kind, self._remote_config).to_json(),
            "sampleRateHz": self._sample_rate_hz,
            "monitorRateHz": self._monitor_rate_hz,
            "rttSampleRateHz": self._rtt_sample_rate_hz,
            "samplingPaused": self._sampling_paused,
            "rttEnabled": self._rtt_enabled,
            "rttProtocol": self._rtt_protocol,
            "rttControlBlockAddress": self._rtt_control_block_address,
            "symbolFile": self._symbol_file,
            "elapsedSeconds": self._elapsed_locked(),
            "sampleCount": self._recording.sample_count,
            "rawRecording": self._recording.status(),
            "debug": self._debug.snapshot(),
        }

    def _publish_target_state(self) -> dict[str, object]:
        with self._lock:
            state = self._targets.selection_state()
        self._emit(EventName.STATE, state)
        return state

    def _connect(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            if self._connection_status == "connected":
                return {"state": self._runtime_state_locked()}
            self._apply_config_locked(params)
            self._connection_status = "connecting"
            self._invalidate_freertos_locked()
            self._latest_rtt_values.clear()
            self._monitor_schedule_revision += 1
            for watch in self._watches.values():
                watch.next_monitor_at = 0.0
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
                pack_path=self._targets.connection_pack() if self._connection_kind == "local" else None,
            )
            self._memory.connect(config)
            initial_execution_state = self._memory.debug_state()
            # A successful reconnect restarts the time axis. Keep the previous
            # journal on disk and start a fresh plot/recording epoch together.
            self._clear_samples()
            with self._lock:
                self._debug.execution_state = initial_execution_state
                self._refresh_debug_state_locked(force=True)
        except Exception as error:
            try:
                self._memory.disconnect()
            except Exception:
                pass
            with self._lock:
                self._connection_status = "disconnected"
                self._debug.execution_state = "unavailable"
                self._debug.stopped_location = None
                self._debug.registers = {}
                failed_state = self._runtime_state_locked()
            self._emit(EventName.LOG, {"level": "error", "message": f"连接调试探针失败：{error}"})
            self._emit(EventName.STATE, failed_state)
            if isinstance(error, ProtocolError):
                raise
            raise ProtocolError("connect_failed", "Unable to connect to the debug probe.", str(error)) from error
        with self._lock:
            self._connection_status = "connected"
            self._connection_started_at = time.perf_counter()
            self._sampling_paused = True
            self._debug.execution_state = initial_execution_state
            self._debug.apply_breakpoints(self._memory, connected=self._connection_status == "connected")
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
            self._rtt_sessions.close()
            self._debug.remove_breakpoints(self._memory, connected=self._connection_status == "connected")
            self._memory.disconnect()
            self._connection_status = "disconnected"
            self._connection_started_at = None
            self._sampling_paused = False
            self._debug.execution_state = "unavailable"
            self._debug.stopped_location = None
            self._debug.registers = {}
            self._debug.mark_breakpoints_pending()
            state = self._runtime_state_locked()
        self._emit(EventName.LOG, {"level": "info", "message": "已断开调试探针。"})
        self._emit(EventName.STATE, state)
        return {"state": state}

    def _load_symbols(self, params: Mapping[str, object], *, display_path: Path | None = None) -> dict[str, object]:
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
        freertos_layout = None
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
            context = options.get("context")
            if context is not None and any(symbol.name in {'pxCurrentTCB', 'pxCurrentTCBs'} for symbol in symbols):
                try:
                    freertos_layout = FreeRtosLayout.from_context(context, lambda: report_progress("source"))
                except ProtocolError:
                    raise
                except Exception as error:
                    freertos_layout = FreeRtosLayout(problem=f"无法解析 FreeRTOS 类型：{error}")
        with self._lock:
            report_progress("ui")
            self._source_projects.sync_firmware_path(display_path or path)
            self._debug.remove_breakpoints(self._memory, connected=self._connection_status == "connected")
            self._symbols = {symbol.key: symbol for symbol in symbols}
            self._symbol_file = str(display_path or path)
            self._freertos = FreeRtosInspector(freertos_layout)
            self._freertos_watch_identity.clear()
            self._freertos_snapshot = {}
            self._next_freertos_at = 0.0
            self._debug.info = debug_info
            # Watches are only valid for symbols in the current file. RTT symbols
            # are recreated after a connection is established.
            self._watches = self._rebind_watches(self._watches, symbols)
            self._debug.apply_breakpoints(self._memory, connected=self._connection_status == "connected")
        self._emit(EventName.LOG, {"level": "info", "message": f"已读取符号文件：{path.name}，变量 {len(symbols)} 个。"})
        state = self.state_snapshot()
        self._emit(EventName.STATE, state)
        return {"state": state, "symbolFile": str(path)}

    @staticmethod
    def _rebind_watches(previous: dict[str, WatchedVariable], symbols: list[SymbolInfo]) -> dict[str, WatchedVariable]:
        # Addresses change after a rebuild. Match by source/name only when unambiguous.
        result = {}
        for watch in previous.values():
            candidates = [symbol for symbol in symbols if not symbol.is_rtt and
                          symbol.name == watch.symbol.name and symbol.source_file == watch.symbol.source_file]
            if len(candidates) == 1:
                symbol = candidates[0]
                result[symbol.key] = WatchedVariable(
                    symbol, watch.color, watch.plot_enabled, watch.sampling_enabled,
                    read_mode=watch.mode, monitor_rate_hz=watch.monitor_rate_hz,
                    monitor_enabled=watch.monitor_enabled,
                )
        return result

    def _download_firmware(self, staged: Path, original: Path, config: dict[str, object], task: SourceTasks) -> None:
        successful = False
        with self._lock:
            self._firmware_busy = True
            was_paused, was_rtt = self._sampling_paused, self._rtt_enabled
            self._sampling_paused, self._rtt_enabled = True, False
        self._emit(EventName.STATE, {"samplingPaused": True, "rttEnabled": False})
        try:
            with self._lock:
                self._flush_pending_samples_locked()
                self._stop_rtt_locked()
                self._rtt_sessions.close()
                self._memory.halt()
                self._debug.remove_breakpoints(self._memory, connected=self._connection_status == "connected")
            task.log(f"下载文件：{original}")
            last_progress = 0.0
            def progress(value: float) -> None:
                nonlocal last_progress
                now = time.monotonic()
                if now - last_progress >= 0.1 or value >= 1:
                    last_progress = now
                    task.phase("download", f"正在下载与校验固件 {value * 100:.0f}%", max(0.0, min(1.0, value)))
            # The sampler and RPC guards reserve the session without holding the
            # service lock throughout flash; getState and shutdown stay responsive.
            self._memory.program_firmware(str(staged), progress)
            if stats := getattr(self._memory, "last_flash_stats", None):
                task.log(f"本地固件：{stats['data_bytes'] / 1024:.1f} KiB；"
                         f"跳过 {stats['skipped_sectors']} 个相同扇区（{stats['skipped_bytes'] / 1024:.1f} KiB）；"
                         f"比较 {stats['compare_s']:.2f} 秒，擦写 {stats['program_s']:.2f} 秒，"
                         f"写后校验 {stats['verify_s']:.2f} 秒，总计 {stats['total_s']:.2f} 秒。")
            if timings := getattr(self._memory, "last_flash_timings", None):
                task.log(f"固件传输：{timings['upload_bytes'] / 1024:.1f} KiB，"
                         f"{timings['upload_s']:.2f} 秒；手机比较、擦写与校验：{timings['flash_s']:.2f} 秒。")
            self._memory.reset(halt=True)
            task.phase("symbols", "正在加载新符号与断点…")
            self._load_symbols({"path": str(staged)}, display_path=original)
            with self._lock:
                self._symbol_file = str(original)
                self._clear_samples()
                self._debug.stopped_location, self._debug.registers = None, {}
                self._rtt_control_block_address = None
                self._next_rtt_retry_at = 0.0
                if config["afterDownload"] == "run":
                    self._memory.resume()
                self._refresh_debug_state_locked(force=True)
                self._sampling_paused, self._rtt_enabled = was_paused, was_rtt
                successful = True
        finally:
            with self._lock:
                if not successful:
                    self._sampling_paused, self._rtt_enabled = True, False
                    self._debug.execution_state = "unknown"
                    self._debug.stopped_location, self._debug.registers = None, {}
                    self._debug.mark_breakpoints_pending()
                self._firmware_busy = False
                state = self.state_snapshot()
            self._emit(EventName.STATE, state)
            self._wake.set()

    def _get_debug_info(self) -> dict[str, object]:
        with self._lock:
            return {
                "sourceFiles": self._debug.info.source_files,
                "executableLines": self._debug.info.executable_lines,
                "debug": self._debug.snapshot(include_definitions=True),
            }

    def _set_breakpoints(self, params: Mapping[str, object]) -> dict[str, object]:
        path = _required_string(params, "path")
        raw_lines = params.get("lines")
        if not isinstance(raw_lines, list) or any(
            isinstance(line, bool) or not isinstance(line, int) or line <= 0 for line in raw_lines
        ):
            raise ProtocolError("invalid_request", "lines must contain positive integers.")
        with self._lock:
            self._debug.set_breakpoints(path, raw_lines, self._memory,
                                        connected=self._connection_status == "connected")
            payload = self._debug.snapshot()
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
                    self._debug.continue_or_step(self._memory, resume=True)
                else:
                    self._debug.continue_or_step(self._memory, resume=False)
                self._refresh_debug_state_locked(force=True)
            except Exception as error:
                raise ProtocolError("debug_control_failed", "Unable to control the target.", str(error)) from error
            payload = self._debug.snapshot()
        return {"debug": payload}

    def _poll_debug_state_locked(self) -> None:
        try:
            if self._connection_kind == "local":
                check = getattr(self._memory, "check_connection", None)
                if callable(check):
                    check()
            self._refresh_debug_state_locked(force=False)
        except Exception as error:
            if self._handle_connection_failure_locked(error):
                return
            # Sampling and a temporarily inaccessible target should recover on
            # their next poll without turning a transient status read into a
            # transport-level failure.
            return

    def _handle_connection_failure_locked(self, error: Exception) -> bool:
        if self._connection_status != "connected":
            return False
        if self._connection_kind == "local":
            return self._handle_local_probe_failure_locked(error)
        fatal = isinstance(error, (ConnectionError, TimeoutError, OSError)) or (
            isinstance(error, EmberError) and error.code in {"unauthorized", "stale_session", "stale_memory", "not_attached"})
        if not fatal:
            return False
        self._stop_rtt_locked()
        self._rtt_sessions.close()
        self._memory.disconnect()
        self._connection_status = "disconnected"
        self._connection_started_at = None
        self._debug.execution_state = "unavailable"
        self._debug.stopped_location = None
        self._debug.registers = {}
        self._debug.mark_breakpoints_pending()
        self._emit(EventName.LOG, {"level": "error", "message": f"远程连接已中断：{error}"})
        self._emit(EventName.STATE, self._runtime_state_locked())
        return True

    def _handle_local_probe_failure_locked(self, error: Exception) -> bool:
        from pyocd.core.exceptions import ProbeDisconnected

        check = getattr(self._memory, "check_connection", None)
        if not callable(check):
            return False
        try:
            check(error=error, force=True)
        except ProbeDisconnected as disconnected:
            reason = str(disconnected)
        except Exception:
            # Presence checks are advisory unless they confirm transport loss.
            # A failed check must not escape the sampler's error handler.
            return False
        else:
            return False

        self._connection_status = "disconnected"
        self._connection_started_at = None
        self._sampling_paused = True
        self._rtt_enabled = False
        self._debug.execution_state = "unavailable"
        self._debug.stopped_location = None
        self._debug.registers = {}
        self._debug.mark_breakpoints_pending()
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0
        self._latest_rtt_values.clear()
        disconnect = getattr(self._memory, "disconnect_lost_probe", self._memory.disconnect)
        cleanup_errors = []
        for cleanup in (lambda: self._flush_pending_samples_locked(wait=False),
                        self._stop_memory_sampling_locked,
                        self._normal_rtt.stop, self._plus_rtt.stop,
                        self._rtt_sessions.close, disconnect):
            try:
                cleanup()
            except Exception as cleanup_error:
                cleanup_errors.append(str(cleanup_error))
        message = "本地调试探针连接已中断，已停止采样；请重新连接探针。"
        self._emit(EventName.STATE, self._runtime_state_locked())
        # ERROR already creates the frontend log entry and connection feedback.
        self._emit(EventName.ERROR, {"code": "probe_disconnected", "message": message,
                   "details": "；".join([reason, *cleanup_errors])})
        return True

    def _refresh_debug_state_locked(self, *, force: bool) -> None:
        if not self._debug.refresh(self._memory, force=force):
            return
        if self._debug.execution_state == "halted" and not backend_capabilities(self._memory).memory_sampling:
            symbols = [watch.symbol for watch in self._watches.values()
                       if not watch.symbol.is_rtt and watch.mode != "manual"
                       and (watch.mode != "monitor" or watch.monitor_enabled)]
            if symbols:
                self._publish_watch_values_locked(self._memory.read_symbols(symbols))
        self._emit(EventName.DEBUG, self._debug.snapshot())

    def _set_config(self, params: Mapping[str, object]) -> dict[str, object]:
        with self._lock:
            previous = self._targets.selected
            self._apply_config_locked(params)
            if previous != self._targets.selected:
                self._publish_target_state()
                self._reconnect_target_locked()
            state = self._runtime_state_locked()
        self._emit(EventName.STATE, state)
        self._wake.set()
        return {"state": state}

    def _reconnect_target_locked(self) -> None:
        if self._connection_status != "connected":
            return
        paused = self._sampling_paused
        self._disconnect()
        try:
            self._connect({})
        finally:
            self._sampling_paused = paused
            self._emit(EventName.STATE, self._runtime_state_locked())

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
                read_mode = raw.get("readMode")
                if read_mode is None:
                    read_mode = ("capture" if raw["sampling"] else "monitor") if "sampling" in raw else (old.mode if old else "capture")
                if not isinstance(read_mode, str) or read_mode not in {"capture", "monitor", "manual"}:
                    raise ProtocolError("invalid_request", "readMode must be capture, monitor or manual.")
                monitor_rate = raw.get("monitorRateHz", old.monitor_rate_hz if old else None)
                monitor_enabled = raw.get("monitorEnabled", True)
                if not isinstance(monitor_enabled, bool):
                    raise ProtocolError("invalid_request", "monitorEnabled must be a boolean.")
                if monitor_rate is not None:
                    monitor_rate = _monitor_frequency(monitor_rate)
                new_watches[key] = WatchedVariable(
                    symbol=symbol,
                    color=_optional_string(raw, "color") or (old.color if old else "#5EEAD4"),
                    plot_enabled=read_mode == "capture" and bool(raw.get("plotted", old.plot_enabled if old else False)),
                    sampling_enabled=read_mode == "capture",
                    value=old.value if old else "",
                    read_mode=str(read_mode),
                    monitor_rate_hz=monitor_rate,
                    monitor_enabled=monitor_enabled,
                    updated_at_ms=old.updated_at_ms if old else None,
                    next_monitor_at=(old.next_monitor_at if old and old.mode == read_mode
                                     and (old.monitor_enabled or not monitor_enabled)
                                     and old.monitor_rate_hz == monitor_rate else 0.0),
                )
            # Seal the old acquisition policy without waiting for disk I/O.
            self._flush_pending_samples_locked(wait=False)
            membership_changed = set(new_watches) != set(self._watches)
            self._watches = new_watches
            self._latest_rtt_values = {key: value for key, value in self._latest_rtt_values.items() if key in new_watches}
            self._monitor_schedule_revision += 1
            if (self._connection_status == "connected" and self._debug.execution_state == "halted"
                    and not backend_capabilities(self._memory).memory_sampling):
                self._refresh_debug_state_locked(force=True)
            if self._rtt_protocol == "plus" and membership_changed:
                self._stop_rtt_locked()
            state = {"watches": [self._watch_json(watch) for watch in self._watches.values()]}
        self._emit(EventName.STATE, state)
        self._wake.set()
        return {"state": state}

    def _set_monitor_visibility(self, params: Mapping[str, object]) -> dict[str, object]:
        keys = params.get("enabledKeys")
        if not isinstance(keys, list) or any(not isinstance(key, str) or not key for key in keys):
            raise ProtocolError("invalid_request", "enabledKeys must be an array of symbol keys.")
        enabled = set(keys)
        with self._lock:
            changed = False
            for key, watch in self._watches.items():
                # RTT producers keep their existing lifecycle and presentation rate.
                if watch.mode != "monitor":
                    continue
                active = (watch.symbol.is_rtt or (self._rtt_enabled and self._rtt_protocol == "plus")
                          or key in enabled)
                if watch.monitor_enabled == active:
                    continue
                watch.monitor_enabled = active
                if active:
                    watch.next_monitor_at = 0.0
                changed = True
            if changed:
                self._monitor_schedule_revision += 1
        if changed:
            self._wake.set()
        # Visibility never replaces watches, flushes capture, or rebuilds streams.
        return {}

    def _write_watch(self, params: Mapping[str, object]) -> dict[str, object]:
        key = _required_string(params, "key")
        value_text = _required_string(params, "value")
        with self._lock:
            watch = self._watches.get(key)
            if watch is None:
                raise ProtocolError("unknown_watch", "Watch does not exist.", key)
            if not watch.symbol.is_writable:
                raise ProtocolError("readonly_symbol", "This symbol is read-only.", watch.symbol.name)
            if not backend_capabilities(self._memory).memory_write:
                raise ProtocolError("unsupported_operation", "EmberMobile 私有协议不支持内存写入，请使用 GDB。")
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "Connect a debug probe before writing variables.")
            try:
                watch.value = self._memory.write_symbol(watch.symbol, value_text)
                watch.updated_at_ms = time.time_ns() // 1_000_000
            except Exception as error:
                raise ProtocolError("write_failed", "Unable to write and verify the variable.", str(error)) from error
            state = {"watches": [self._watch_json(item) for item in self._watches.values()]}
        self._emit(EventName.LOG, {"level": "info", "message": f"已写入 {watch.symbol.name} 并完成回读验证。"})
        self._emit(EventName.STATE, state)
        return {"state": state}

    def _write_watches(self, params: Mapping[str, object]) -> dict[str, object]:
        raw = params.get("writes")
        if not isinstance(raw, list) or not 1 <= len(raw) <= 64:
            raise ProtocolError("invalid_request", "writes must contain 1..64 entries.")
        with self._lock:
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "Connect a debug probe before writing variables.")
            if not backend_capabilities(self._memory).memory_write:
                raise ProtocolError("unsupported_operation", "当前连接不支持内存写入。")
            watches, writes, keys = [], [], set()
            for entry in raw:
                if not isinstance(entry, Mapping):
                    raise ProtocolError("invalid_request", "Each write must be an object.")
                key, value = _required_string(entry, "key"), _required_string(entry, "value")
                if key in keys:
                    raise ProtocolError("invalid_request", "Batch writes cannot repeat a variable.")
                keys.add(key)
                watch = self._watches.get(key)
                if watch is None:
                    raise ProtocolError("unknown_watch", "Watch does not exist.", key)
                if not watch.symbol.is_writable:
                    raise ProtocolError("readonly_symbol", "This symbol is read-only.", watch.symbol.name)
                watches.append(watch)
                writes.append((watch.symbol, value))
            try:
                writer = getattr(self._memory, "write_symbols", None)
                if callable(writer):
                    values = writer(writes)
                else:
                    # Preserve the injected target adapter contract.
                    from take_a_look_backend.backends.typed_memory import encode_symbol_value
                    for symbol, value in writes:
                        encode_symbol_value(symbol, value)
                    values = {symbol.key: self._memory.write_symbol(symbol, value)
                              for symbol, value in writes}
                if set(values) != keys:
                    raise RuntimeError("批量回读未返回全部变量。")
                stamp = time.time_ns() // 1_000_000
                self._remember_values_locked(values, updated_at_ms=stamp)
                payload = {"values": [self._watch_value_json(watch) for watch in watches]}
            except Exception as error:
                # No retry: a failed batch can have already changed the target.
                raise ProtocolError("write_failed", "Unable to write and verify the variables.", str(error)) from error
        self._emit(EventName.WATCH_VALUES, payload)
        self._emit(EventName.LOG, {"level": "info", "message": f"已写入 {len(watches)} 个变量并完成回读验证。"})
        return payload

    def _read_watch(self, params: Mapping[str, object]) -> dict[str, object]:
        key = _required_string(params, "key")
        with self._lock:
            watch = self._watches.get(key)
            if watch is None:
                raise ProtocolError("unknown_watch", "Watch does not exist.", key)
            if self._connection_status != "connected":
                raise ProtocolError("not_connected", "请先连接调试探针。")
            can_read_memory = (backend_capabilities(self._memory).memory_sampling
                               or self._debug.execution_state == "halted")
            if watch.symbol.is_rtt or (not can_read_memory and self._rtt_enabled and self._rtt_protocol == "plus"):
                latest = self._latest_rtt_values.get(key)
                if latest is None:
                    raise ProtocolError("no_data", "尚未收到此 RTT 变量的数据。")
                self._publish_watch_values_locked({key: latest[0]}, updated_at_ms=latest[1])
            else:
                if not backend_capabilities(self._memory).memory_sampling and self._debug.execution_state != "halted":
                    raise ProtocolError("target_running", "当前 GDB 连接需要暂停目标后读取内存。")
                try:
                    self._publish_watch_values_locked(self._memory.read_symbols([watch.symbol]))
                except Exception as error:
                    self._handle_connection_failure_locked(error)
                    raise ProtocolError("read_failed", "变量读取失败。", str(error)) from error
            return {"values": [self._watch_value_json(watch)]}

    def _set_sampling_paused(self, params: Mapping[str, object]) -> dict[str, object]:
        paused = params.get("paused")
        if not isinstance(paused, bool):
            raise ProtocolError("invalid_request", "paused must be a boolean.")
        with self._lock:
            if not paused and self._recording.failure is not None:
                self._emit(EventName.STATE, {"samplingPaused": True})
                raise ProtocolError("raw_recording_failed", "请解决记录写入错误后清空采样，开启新记录。")
            self._sampling_paused = paused
            if paused:
                self._stop_memory_sampling_locked()
            state = {
                "samplingPaused": self._sampling_paused,
                "elapsedSeconds": self._elapsed_locked(),
            }
        self._emit(EventName.LOG, {"level": "info", "message": "采集已暂停，低频监视继续。" if paused else "采集已继续。"})
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
            self._stop_memory_sampling_locked()
            self._flush_pending_samples_locked()
            self._pipeline.rotate()
            self._connection_started_at = time.perf_counter() if self._connection_status == "connected" else None
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
                self._rtt_sessions.close()
                self._invalidate_freertos_locked()
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
            snapshot = self._pipeline.snapshot()
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
            name = _required_string(params, "targetName")
            if name != self._target_name:
                self._targets.select(name, legacy=True)
                self._target_name = str(self._targets.selected["name"])
        if "swdClock" in params:
            self._swd_clock = _required_string(params, "swdClock")
            _parse_frequency_hz(self._swd_clock)
        if "serialNumber" in params:
            self._serial_number = _required_string(params, "serialNumber")
        if "sampleRateHz" in params:
            self._sample_rate_hz = _positive_number(params["sampleRateHz"], "sampleRateHz")
        if "monitorRateHz" in params:
            self._monitor_rate_hz = _monitor_frequency(params["monitorRateHz"])
            self._monitor_schedule_revision += 1
            for watch in self._watches.values():
                if watch.monitor_rate_hz is None:
                    watch.next_monitor_at = 0.0
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
            "readMode": watch.mode,
            "monitorRateHz": watch.monitor_rate_hz,
            "updatedAtMs": watch.updated_at_ms,
            "value": json_value(watch.value),
        }

    def _emit(self, name: EventName, params: object) -> None:
        if not self._closed:
            self._emit_event(name, params)


def _required_string(values: Mapping[str, object], name: str) -> str:
    value = values.get(name)
    if not isinstance(value, str):
        raise ProtocolError("invalid_request", f"{name} must be a string.")
    return value


def _optional_string(values: Mapping[str, object], name: str) -> str | None:
    value = values.get(name)
    return value if isinstance(value, str) else None


def _monitor_frequency(value: object) -> float:
    number = _positive_number(value, "monitorRateHz")
    if not 0.5 <= number <= 10:
        raise ProtocolError("invalid_request", "监视频率必须在 0.5–10 Hz 之间。")
    return number


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
