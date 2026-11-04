"""Project configuration and the single firmware path; persisted only in .talproj."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import sys

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


def normalize_config(current: dict[str, object], values: dict[str, object]) -> dict[str, object]:
    """Prepare one project configuration. Paths are normalized only here."""
    result = default_config()
    for key in result:
        value = values.get(key, current.get(key, result[key]))
        if not isinstance(value, str) or "\x00" in value or len(value) > 32768:
            raise ProtocolError("invalid_source_config", f"无效的工程配置：{key}")
        result[key] = value.strip()
    root = str(result["sourceRoot"])
    if root:
        directory = Path(root).expanduser().resolve()
        if not directory.is_dir():
            raise ProtocolError("source_root_missing", "源码根目录不存在或不是文件夹。", str(directory))
        result["sourceRoot"] = str(directory)
    text = str(result["firmwarePath"])
    if text:
        path = Path(text).expanduser()
        if not path.is_absolute():
            if not root:
                raise ProtocolError("source_root_required", "相对固件路径需要设置工程源码根目录。")
            path = Path(str(result["sourceRoot"])) / path
        path = path.resolve()
        if path.suffix.lower() not in {".elf", ".axf"}:
            raise ProtocolError("unsupported_symbol_file", "固件文件必须为 ELF / AXF。", str(path))
        result["firmwarePath"] = str(path)
    if result["shell"] not in {item["id"] for item in shell_options()}:
        raise ProtocolError("unsupported_shell", "当前平台不支持此命令解释器。")
    if result["afterDownload"] not in {"halt", "run"} or result["outputEncoding"] not in {"utf-8", "system"}:
        raise ProtocolError("invalid_source_config", "无效的下载动作或输出编码。")
    return result


def project_snapshot(config: dict[str, object]) -> dict[str, object]:
    return {**config, "platform": platform_name(), "shells": shell_options()}


def firmware_file(config: dict[str, object]) -> Path:
    text = str(config.get("firmwarePath", ""))
    if not text:
        raise ProtocolError("firmware_required", "请打开 ELF / AXF 文件，或在工程设置中指定固件文件。")
    path = Path(text)
    if not path.is_absolute():
        raise ProtocolError("invalid_source_config", "固件路径必须经过工程配置解析。", text)
    if path.suffix.lower() not in {".elf", ".axf"} or not path.is_file():
        raise ProtocolError("firmware_missing", "固件文件不存在，或不是 ELF / AXF 文件。", text)
    return path
