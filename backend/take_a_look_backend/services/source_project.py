"""Local, platform-specific source project settings. Never executes on load."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from take_a_look_backend.protocol import ProtocolError


def platform_name() -> str:
    return "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux"


def shell_options(platform: str | None = None) -> list[dict[str, object]]:
    platform = platform or platform_name()
    names = [("powershell", "PowerShell"), ("cmd", "CMD")] if platform == "windows" else (
        [("zsh", "zsh"), ("bash", "Bash"), ("sh", "sh")] if platform == "macos" else
        [("bash", "Bash"), ("sh", "sh"), ("zsh", "zsh")])
    result = []
    for key, label in names:
        candidates = ["pwsh.exe", "powershell.exe"] if key == "powershell" else ["cmd.exe"] if key == "cmd" else [key]
        executable = next((path for name in candidates if (path := shutil.which(name))), None)
        if not executable and key in {"cmd", "powershell"}:
            system = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32"
            fallback = system / ("cmd.exe" if key == "cmd" else "WindowsPowerShell/v1.0/powershell.exe")
            if fallback.is_file():
                executable = str(fallback)
        result.append({"id": key, "label": label, "available": bool(executable), "executable": executable or ""})
    return result


def default_config(root: str = "", platform: str | None = None) -> dict[str, object]:
    platform = platform or platform_name()
    shell = {"windows": "powershell", "macos": "zsh", "linux": "bash"}[platform]
    if platform != "windows":
        available = shell_options(platform)
        if not any(item["id"] == shell and item["available"] for item in available):
            shell = next((str(item["id"]) for item in available if item["available"]), shell)
    return {"sourceRoot": root, "buildCommand": "", "firmwarePath": "", "shell": shell,
            "afterDownload": "halt", "extraPath": "", "outputEncoding": "utf-8"}


def default_settings_file() -> Path:
    override = os.environ.get("TAL_SOURCE_SETTINGS")
    if override:
        return Path(override).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("APPDATA", str(Path.home() / "AppData/Roaming")))
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    return base / "TakeALook/source-projects.json"


class SourceProjects:
    def __init__(self, file: Path | None = None) -> None:
        self.file = file
        self.platform = platform_name()
        self.current = default_config()
        self._profiles: dict[str, dict[str, object]] = {}
        self._platforms: dict[str, dict[str, object]] = {}
        if file is not None and file.is_file():
            try:
                data = json.loads(file.read_text(encoding="utf-8"))
                if data.get("version") == 1:
                    self._platforms = data.get("platforms", {})
                    if data.get("platform") in {"windows", "macos", "linux"}:
                        self._platforms[data["platform"]] = {"projects": data.get("projects", {})}
                    local = self._platforms.get(self.platform, {})
                    self._profiles = local.get("projects", {})
                    # Profiles are reused only after an explicit selection.
                    # Ignore lastRoot from older settings and start unselected.
            except (OSError, ValueError, TypeError, AttributeError, ProtocolError):
                self._profiles = {}
                self._platforms = {}

    def snapshot(self) -> dict[str, object]:
        return {**self.current, "platform": self.platform, "shells": shell_options()}

    def select(self, values: dict[str, object]) -> dict[str, object]:
        root = str(values.get("sourceRoot", self.current["sourceRoot"])).strip()
        if not root:
            raise ProtocolError("source_root_required", "请先设置工程源码根目录。")
        normalized = str(Path(root).expanduser().resolve())
        if normalized != self.current["sourceRoot"]:
            draft = dict(self._profiles.get(os.path.normcase(normalized), default_config(normalized)))
            if not draft["firmwarePath"] and not self.current["sourceRoot"]:
                draft["firmwarePath"] = self.current["firmwarePath"]
        else:
            draft = dict(self.current)
        draft.update(values)
        draft["sourceRoot"] = normalized
        candidate = self._validate(draft)
        profiles = {**self._profiles, os.path.normcase(normalized): candidate}
        platforms = {**self._platforms, self.platform: {"projects": profiles}}
        if self.file is not None:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix="source-projects-", suffix=".json", dir=self.file.parent)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump({"version": 1, "platforms": platforms}, stream, ensure_ascii=False)
                os.replace(temporary, self.file)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        self.current, self._profiles = candidate, profiles
        self._platforms = platforms
        return self.snapshot()

    def sync_firmware_path(self, path: Path) -> None:
        """Commit a loaded symbol file without changing equivalent relative paths."""
        path = path.resolve()
        root = str(self.current["sourceRoot"])
        configured = str(self.current["firmwarePath"])
        if configured:
            previous = Path(configured).expanduser()
            if not previous.is_absolute():
                previous = Path(root).expanduser() / previous
            if os.path.normcase(str(previous.resolve())) == os.path.normcase(str(path)):
                return
        if root and Path(root).is_dir():
            self.select({"firmwarePath": str(path)})
        else:
            # Symbol selection also works before a source project is selected.
            self.current = {**self.current, "firmwarePath": str(path)}

    def _validate(self, values: dict[str, object]) -> dict[str, object]:
        result = default_config()
        for key in result:
            value = values.get(key, result[key])
            if not isinstance(value, str) or "\x00" in value or len(value) > 32768:
                raise ProtocolError("invalid_source_config", f"无效的工程配置：{key}")
            result[key] = value.strip()
        if not Path(str(result["sourceRoot"])).is_dir():
            raise ProtocolError("source_root_missing", "源码根目录不存在或不是文件夹。", result["sourceRoot"])
        if result["shell"] not in {item["id"] for item in shell_options()}:
            raise ProtocolError("unsupported_shell", "当前平台不支持此命令解释器。")
        if result["afterDownload"] not in {"halt", "run"} or result["outputEncoding"] not in {"utf-8", "system"}:
            raise ProtocolError("invalid_source_config", "无效的下载动作或输出编码。")
        return result


def firmware_file(config: dict[str, object]) -> Path:
    text = str(config.get("firmwarePath", "")).strip()
    if not text:
        raise ProtocolError("firmware_required", "请打开 ELF / AXF 文件，或在工程设置中指定下载文件。")
    path = Path(text).expanduser()
    if not path.is_absolute():
        if not str(config["sourceRoot"]).strip():
            raise ProtocolError("source_root_required", "相对固件路径需要设置工程源码根目录。")
        path = Path(str(config["sourceRoot"])) / path
    path = path.resolve()
    if path.suffix.lower() not in {".elf", ".axf"} or not path.is_file():
        raise ProtocolError("firmware_missing", "下载文件不存在，或不是 ELF / AXF 文件。", str(path))
    return path
