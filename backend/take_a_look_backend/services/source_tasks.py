"""Non-blocking build/download jobs with bounded output and process-tree ownership."""
from __future__ import annotations

import base64
import codecs
from contextlib import contextmanager
from collections import deque
import ctypes
import locale
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.services.source_project import firmware_file, shell_options


class _WindowsJob:
    """Closing the job kills compiler grandchildren, including after shell exit."""
    def __init__(self) -> None:
        from ctypes import wintypes as w
        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("flags", w.DWORD), ("minimum", ctypes.c_size_t), ("maximum", ctypes.c_size_t),
                        ("active", w.DWORD), ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]
        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", ctypes.c_uint64 * 6),
                        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                        ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.api.CreateJobObjectW.restype = w.HANDLE
        self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.api.CloseHandle.argtypes = [w.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        info = Extended()
        info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.handle or not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            self.close()
            raise ctypes.WinError(ctypes.get_last_error())

    def assign(self, process: subprocess.Popen) -> None:
        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self) -> None:
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def task_environment(config: dict[str, object]) -> dict[str, str]:
    env = dict(os.environ)
    for key in ("PYTHONPATH", "PYTHONUTF8"):
        host_key = "TAL_HOST_" + key
        if host_key in env:
            original = env.pop(host_key)
            env.pop(key, None)
            if original:
                env[key] = original
    backend_root = str(Path(__file__).resolve().parents[2])
    if env.get("PYTHONPATH") == backend_root:
        env.pop("PYTHONPATH", None)
    if getattr(sys, "frozen", False):
        original = env.pop("LD_LIBRARY_PATH_ORIG", None)
        env.pop("LD_LIBRARY_PATH", None)
        if original:
            env["LD_LIBRARY_PATH"] = original
        for key in list(env):
            if key.startswith("_PYI_"):
                env.pop(key)
    paths = []
    for item in str(config.get("extraPath", "")).splitlines():
        if item.strip():
            path = Path(item.strip()).expanduser()
            paths.append(str(path if path.is_absolute() else Path(str(config["sourceRoot"])) / path))
    env["PATH"] = os.pathsep.join([*paths, env.get("PATH", "")])
    if config.get("outputEncoding") == "utf-8":
        env["PYTHONIOENCODING"] = "utf-8"
    return env


@contextmanager
def external_dll_search():
    # PyInstaller sets a process-wide DLL directory. Do not hand bundled Python
    # DLLs to a user's compiler/toolchain; restore it immediately after launch.
    if os.name != "nt" or not getattr(sys, "frozen", False):
        yield
        return
    api = ctypes.WinDLL("kernel32", use_last_error=True)
    from ctypes import wintypes as w
    api.GetDllDirectoryW.argtypes = [w.DWORD, w.LPWSTR]
    api.SetDllDirectoryW.argtypes = [w.LPCWSTR]
    buffer = ctypes.create_unicode_buffer(32768)
    api.GetDllDirectoryW(len(buffer), buffer)
    original = buffer.value
    api.SetDllDirectoryW(None)
    try:
        yield
    finally:
        api.SetDllDirectoryW(original or None)


def shell_command(config: dict[str, object], directory: Path) -> list[str] | str:
    shell = next((item for item in shell_options() if item["id"] == config["shell"]), None)
    if shell is None or not shell["available"]:
        raise ProtocolError("shell_missing", "所选命令解释器未安装，请在工程设置中更换。", config["shell"])
    executable, command = str(shell["executable"]), str(config["buildCommand"])
    if config["shell"] == "powershell":
        # The gate prevents user code running before the Windows job owns the process.
        script = "[Console]::ReadLine() | Out-Null\n" if os.name == "nt" else ""
        script += "$ErrorActionPreference = 'Stop'\n$PSNativeCommandUseErrorActionPreference = $true\n"
        if config.get("outputEncoding") == "utf-8":
            script += "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n$OutputEncoding = [Console]::OutputEncoding\n"
        script += ("try {\n& {\n" + command + "\n}\n$talBuildSucceeded = $?\n"
                   "if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n"
                   "if (-not $talBuildSucceeded) { exit 1 }\n} catch {\n[Console]::Error.WriteLine($_.ToString())\n"
                   "if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; exit 1\n}\nexit 0")
        return [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
                base64.b64encode(script.encode("utf-16-le")).decode("ascii")]
    if config["shell"] == "cmd":
        script = directory / "build.cmd"
        script.write_text("@chcp 65001 >nul\n@set /p TAL_BUILD_START=\n@echo off\n" + command + "\nexit /b %errorlevel%\n", encoding="utf-8")
        return f'"{executable}" /d /s /c ""{script}""'
    switches = ["--noprofile", "--norc"] if config["shell"] == "bash" else ["-f"] if config["shell"] == "zsh" else []
    return [executable, *switches, "-c", command]


class SourceTasks:
    def __init__(self, emit, download, built=lambda: None) -> None:
        self._emit, self._download, self._built = emit, download, built
        self._lock = threading.RLock()
        self._cancel = threading.Event()
        self._thread: threading.Thread | None = None
        self._process: subprocess.Popen | None = None
        self._job: _WindowsJob | None = None
        self._task: dict[str, object] = {"status": "idle", "phase": "idle", "message": ""}
        self._lines: deque[dict[str, object]] = deque()
        self._pending: deque[dict[str, object]] = deque(maxlen=128)
        self._characters = self._sequence = self._dropped = 0
        self._started = 0.0
        self._closed = False

    @property
    def running(self) -> bool:
        with self._lock:
            return self._task["status"] == "running"

    @property
    def reserves_probe(self) -> bool:
        with self._lock:
            return self.running and self._task.get("kind") != "build"

    def snapshot(self, *, output: bool = True) -> dict[str, object]:
        with self._lock:
            return {**self._task, "canCancel": self.running and self._task["phase"] == "build",
                    "outputTruncated": self._sequence > len(self._lines) or self._task.get("outputTruncated", False),
                    **({"lines": list(self._lines), "replaceOutput": True} if output else {})}

    def start(self, kind: str, config: dict[str, object]) -> dict[str, object]:
        if kind not in {"build", "download", "buildAndDownload"}:
            raise ProtocolError("invalid_source_task", "未知的工程任务。")
        if kind != "download" and (not str(config["sourceRoot"]).strip() or not Path(str(config["sourceRoot"])).is_dir()):
            raise ProtocolError("source_root_required", "请设置有效的工程源码根目录。")
        if kind != "download" and not str(config["buildCommand"]).strip():
            raise ProtocolError("build_command_required", "请在工程设置中填写编译命令。")
        if kind == "download":
            firmware_file(config)
        if kind == "buildAndDownload" and not str(config["firmwarePath"]).strip():
            raise ProtocolError("firmware_required", "请先设置编译产出的 ELF / AXF 路径。")
        with self._lock:
            if self._closed or self.running:
                raise ProtocolError("source_task_busy", "已有编译或下载任务正在执行。")
            self._cancel.clear()
            self._lines.clear(); self._pending.clear()
            self._characters = self._sequence = self._dropped = 0
            self._started = time.monotonic()
            self._task = {"id": uuid.uuid4().hex, "kind": kind, "status": "running",
                          "phase": "build" if kind != "download" else "download",
                          "message": "正在编译…" if kind != "download" else "准备下载…",
                          "sourceRoot": config["sourceRoot"], "command": config["buildCommand"], "elapsed": 0.0}
            initial = self.snapshot()
            self._emit(initial)
            self._thread = threading.Thread(target=self._run, args=(kind, dict(config)), name="tal-source-task", daemon=True)
            self._thread.start()
            return initial

    def cancel(self) -> dict[str, object]:
        with self._lock:
            if self.running and self._task["phase"] == "build":
                self._cancel.set()
                self._task["message"] = "正在停止编译…"
            elif self.running:
                raise ProtocolError("download_not_cancellable", "正在写入固件，不能强制终止。")
            return self.snapshot(output=False)

    def close(self) -> None:
        with self._lock:
            self._closed = True
            if self._task.get("phase") == "build":
                self._cancel.set()
            thread = self._thread
        if thread is not None:
            # A flash operation must release its session before shutdown disconnects it.
            thread.join()

    def log(self, text: str, stream: str = "info") -> None:
        with self._lock:
            for start in range(0, max(1, len(text)), 2048):
                self._sequence += 1
                line = {"seq": self._sequence, "text": text[start:start + 2048], "stream": stream}
                self._lines.append(line)
                self._characters += len(str(line["text"]))
                while self._characters > 256 * 1024 or len(self._lines) > 1000:
                    self._characters -= len(str(self._lines.popleft()["text"]))
                if len(self._pending) == self._pending.maxlen:
                    self._dropped += 1
                    self._task["outputTruncated"] = True
                self._pending.append(line)

    def phase(self, phase: str, message: str, progress: float | None = None) -> None:
        with self._lock:
            self._task.update(phase=phase, message=message, progress=progress)
        self._flush()

    def _flush(self) -> None:
        with self._lock:
            self._task["elapsed"] = round(time.monotonic() - self._started, 2)
            event = self.snapshot(output=False)
            event["lines"] = list(self._pending)
            self._pending.clear()
            if self._dropped:
                event["droppedLines"] = self._dropped
                self._dropped = 0
        self._emit(event)

    def _run(self, kind: str, config: dict[str, object]) -> None:
        try:
            if kind != "download":
                code = self._build(config)
                with self._lock:
                    self._task["exitCode"] = code
                    cancelled = self._cancel.is_set()
                if cancelled:
                    self._finish("cancelled", "编译已取消，未执行下载。")
                    return
                if code != 0:
                    self._finish("failed", f"编译失败，退出码 {code}，未执行下载。")
                    return
                self.log("编译成功。")
            if kind != "build":
                with self._lock:
                    if self._cancel.is_set():
                        self._finish("cancelled", "编译已取消，未执行下载。")
                        return
                    self._task.update(phase="download", message="准备下载…")
                self._flush()
                # Check only after a successful build; a first build need not have an ELF yet.
                firmware = firmware_file(config)
                with tempfile.TemporaryDirectory(prefix="tal-firmware-") as temporary:
                    import shutil
                    staged = Path(temporary) / firmware.name
                    shutil.copy2(firmware, staged)
                    self._download(staged, firmware, config, self)
                self._finish("succeeded", "下载完成，可以调试。" if config["afterDownload"] == "halt" else "下载完成，目标已运行。")
            else:
                self._built()
                self._finish("succeeded", "编译成功，待下载。")
        except Exception as error:
            details = getattr(error, "details", None)
            self._finish("cancelled" if self._cancel.is_set() else "failed",
                         "编译已取消，未执行下载。" if self._cancel.is_set() else f"{getattr(error, 'message', str(error))}" + (f"：{details}" if details else ""))

    def _finish(self, status: str, message: str) -> None:
        with self._lock:
            self.log(message, "stderr" if status == "failed" else "info")
            self._task.update(status=status, message=message, progress=None)
            self._flush()

    def _read_output(self, stream, name: str, encoding: str) -> None:
        decoder = codecs.getincrementaldecoder(encoding)(errors="replace")
        pending = ""
        try:
            while chunk := stream.read(4096):
                pending += decoder.decode(chunk).replace("\r\n", "\n").replace("\r", "\n")
                parts = pending.split("\n")
                pending = parts.pop()
                for line in parts:
                    self.log(line, name)
                if len(pending) >= 2048:
                    self.log(pending[:2048], name)
                    pending = pending[2048:]
            pending += decoder.decode(b"", final=True)
            if pending:
                self.log(pending, name)
        finally:
            stream.close()

    def _stop_tree(self) -> None:
        process = self._process
        if process is None:
            return
        if self._job is not None:
            self._job.close()
            self._job = None
        elif os.name != "nt":
            try:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif process.poll() is None:
            process.kill()

    def _build(self, config: dict[str, object]) -> int:
        self.log(f"工作目录：{config['sourceRoot']}")
        self.log(f"解释器：{config['shell']}\n{config['buildCommand']}")
        encoding = locale.getencoding() if config.get("outputEncoding") == "system" else "utf-8"
        readers: list[threading.Thread] = []
        with tempfile.TemporaryDirectory(prefix="tal-build-") as temporary:
            args = shell_command(config, Path(temporary))
            try:
                if os.name == "nt":
                    self._job = _WindowsJob()
                if self._cancel.is_set():
                    return -1
                with external_dll_search():
                    self._process = subprocess.Popen(args, cwd=str(config["sourceRoot"]), env=task_environment(config),
                        stdin=subprocess.PIPE if os.name == "nt" else subprocess.DEVNULL,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP) if os.name == "nt" else 0,
                        start_new_session=os.name != "nt")
                if self._job is not None:
                    try:
                        self._job.assign(self._process)
                    except BaseException:
                        self._process.kill()
                        raise
                    self._process.stdin.write(b"start\n")
                    self._process.stdin.close()
                for stream, name in [(self._process.stdout, "stdout"), (self._process.stderr, "stderr")]:
                    reader = threading.Thread(target=self._read_output, args=(stream, name, encoding), daemon=True)
                    reader.start(); readers.append(reader)
                while self._process.poll() is None:
                    if self._cancel.wait(0.1):
                        self._stop_tree()
                    self._flush()
                return self._process.wait()
            finally:
                self._stop_tree()
                if self._process is not None:
                    self._process.wait(timeout=5)
                for reader in readers:
                    reader.join(timeout=2)
                if self._job is not None:
                    self._job.close()
                    self._job = None
                self._process = None
                self._flush()
