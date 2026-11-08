"""Firmware selection, parsing and programming in one state transition.

The only path lives in sourceProject.firmwarePath. Runtime metadata never owns
another path. Missing outputs clear all derived state; failed parses commit nothing.
"""
from __future__ import annotations

from contextlib import ExitStack
from dataclasses import dataclass
import hashlib
from pathlib import Path
import time

from ..models import SymbolInfo, WatchedVariable
from ..protocol import EventName, ProtocolError
from .debug_info import DebugInfoIndex, load_debug_info_from_elf
from .elf_context import ElfLoadContext
from .freertos import FreeRtosInspector
from .freertos_layout import FreeRtosLayout
from .source_project import normalize_config
from .source_tasks import SourceTasks
from .symbols import load_symbols_from_elf

SYMBOL_LOAD_TIMEOUT_SECONDS = 600


def file_fingerprint(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@dataclass(frozen=True)
class FirmwareImage:
    symbols: list[SymbolInfo]
    debug_info: DebugInfoIndex
    freertos_layout: FreeRtosLayout | None
    fingerprint: str


class FirmwareServiceMixin:
    def _load_firmware(self, params) -> dict[str, object]:
        path = params.get("path")
        if not isinstance(path, str) or not path.strip():
            raise ProtocolError("invalid_request", "请选择 ELF / AXF 文件。")
        return self._set_source_project({"firmwarePath": path, "loadId": params.get("loadId")}, require_file=True)

    def _set_source_project(self, values, *, require_file=False):
        with self._firmware_lock:
            if self._source_tasks.running:
                raise ProtocolError("source_task_busy", "编译或下载任务执行中，请等待任务完成。")
            config = normalize_config(self._source_project, dict(values))
            if "firmwarePath" not in values:
                with self._lock:
                    self._source_project = config
                    state = self.state_snapshot()
                self._emit(EventName.STATE, state)
                return {"state": state}
            text = str(config["firmwarePath"])
            path = Path(text) if text else None
            # Saving settings also refreshes an existing file, even at the same path.
            image = self._parse_firmware(path, values.get("loadId")) if path and path.is_file() else None
            if require_file and image is None:
                raise ProtocolError("file_not_found", "固件文件不存在。", text)
            with self._lock:
                # Explicitly reopening unchanged symbols also acknowledges a
                # download performed in an external IDE/programmer.
                requires_download = bool(image and text == self._source_project["firmwarePath"]
                    and ((self._firmware.get("requiresDownload") and not require_file)
                         or (self._firmware["fingerprint"] and image.fingerprint != self._firmware["fingerprint"])))
                self._commit_firmware(config, image, requires_download=requires_download)
                state = self.state_snapshot()
            self._emit(EventName.STATE, state)
            return {"state": state}

    def _commit_firmware(self, config, image, *, requires_download=False):
        if requires_download:
            # Monitoring also reads addresses, so pausing capture alone is insufficient.
            self._flush_pending_samples_locked()
            self._stop_memory_sampling_locked()
            self._stop_rtt_locked()
            self._latest_rtt_values.clear()
            self._sampling_paused, self._rtt_enabled = True, False
        self._debug.remove_breakpoints(self._memory, connected=self._connection_status == "connected")
        symbols = image.symbols if image else []
        self._source_project = dict(config)
        self._symbols = {symbol.key: symbol for symbol in symbols}
        self._firmware = {
            "status": "ready" if image else "missing" if config["firmwarePath"] else "empty",
            "revision": self._firmware["revision"] + 1,
            "fingerprint": image.fingerprint if image else "",
            "requiresDownload": requires_download,
        }
        self._freertos = FreeRtosInspector(image.freertos_layout if image else None)
        self._freertos_watch_identity.clear()
        self._freertos_snapshot = {}
        self._next_freertos_at = 0.0
        self._debug.info = image.debug_info if image else DebugInfoIndex()
        self._debug.stopped_location, self._debug.registers = None, {}
        self._watches = self._rebind_watches(self._watches, symbols)
        if requires_download:
            self._debug.execution_state = "unknown"
            self._debug.mark_breakpoints_pending(message="固件已变化，请重新下载后应用断点。")
        else:
            self._debug.apply_breakpoints(self._memory, connected=self._connection_status == "connected")
        self._reconcile_acquisition_clock_locked()

    def _firmware_built(self):
        # The compiler has exited; build-only jobs need not wait for the poller.
        path = self._source_project["firmwarePath"]
        if path:
            self._refresh_changed_firmware(Path(path), after_build=True)

    def _refresh_changed_firmware(self, path: Path, *, after_build=False) -> bool:
        # Parsing stays off the sampler/RPC thread and never holds the probe lock.
        # Serialize against explicit loads and downloads; a busy job is retried.
        if not self._firmware_lock.acquire(blocking=False):
            return False
        try:
            if self._closed or str(path) != self._source_project["firmwarePath"]:
                return False
            if self._source_tasks.running and not after_build:
                return False
            fingerprint = file_fingerprint(path)
            if fingerprint == self._firmware["fingerprint"]:
                return True
            image = self._parse_firmware(path)
            with self._lock:
                if self._closed:
                    return False
                self._commit_firmware(self._source_project, image, requires_download=True)
                state = self.state_snapshot()
            self._firmware_watch_error = None
            self._emit(EventName.LOG, {"level": "info", "message": f"检测到固件变化，已自动刷新符号与源码索引：{path}"})
            self._emit(EventName.STATE, state)
            self._wake.set()
            return True
        except Exception as error:
            # Linkers can leave an incomplete/unreadable file between writes.
            # Keep the previous generation and retry, without repeated popups.
            message = getattr(error, "message", str(error))
            signature = (str(path), message)
            if signature != self._firmware_watch_error:
                self._firmware_watch_error = signature
                self._emit(EventName.LOG, {"level": "warning", "message": f"自动刷新符号暂未完成，将重试：{message}"})
            return False
        finally:
            self._firmware_lock.release()

    def _require_current_firmware_locked(self):
        if self._firmware.get("requiresDownload"):
            raise ProtocolError("firmware_download_required", "固件已变化，符号已刷新，请重新下载固件后再采样或调试。")

    def _parse_firmware(self, path: Path, load_id=None) -> FirmwareImage:
        path_text = str(path)
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
        if not path.is_file():
            raise ProtocolError("file_not_found", "Symbol file does not exist.", str(path))
        if path.suffix.lower() not in {".elf", ".axf"}:
            raise ProtocolError("unsupported_symbol_file", "Symbol file must use .elf or .axf.", str(path))
        fingerprint = file_fingerprint(path)
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
        if fingerprint != file_fingerprint(path):
            raise ProtocolError("firmware_changed", "解析期间固件文件发生变化，请重试。", str(path))
        report_progress("ui")
        return FirmwareImage(symbols, debug_info, freertos_layout, fingerprint)

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
        with self._firmware_lock:
            self._download_firmware_locked(staged, original, config, task)

    def _download_firmware_locked(self, staged: Path, original: Path, config: dict[str, object], task: SourceTasks) -> None:
        # Parse exactly the staged bytes before touching the target.
        image = self._parse_firmware(staged)
        successful = False
        with self._lock:
            self._firmware_busy = True
            was_paused, was_rtt = self._sampling_paused, self._rtt_enabled
            self._sampling_paused, self._rtt_enabled = True, False
            self._reconcile_acquisition_clock_locked()
        self._emit(EventName.STATE, {"samplingPaused": True, "rttEnabled": False,
                                    **self._sampling_clock_state()})
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
            with self._lock:
                self._commit_firmware(config, image)
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
                self._reconcile_acquisition_clock_locked()
                state = self.state_snapshot()
            self._emit(EventName.STATE, state)
            self._wake.set()

