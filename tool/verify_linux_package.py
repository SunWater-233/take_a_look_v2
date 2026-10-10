"""Integration test of the archive as delivered, including relocation and install/update/remove."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def command(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


archive = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="tal package test ") as temporary:
    root = Path(temporary)
    relocated = root / "unpacked 中文"
    relocated.mkdir()
    with tarfile.open(archive) as package:
        package.extractall(relocated, filter="data")
    (app,) = relocated.iterdir()
    home = root / "empty home"
    home.mkdir()
    environment = {**os.environ, "HOME": str(home)}
    for name in ("PYTHONPATH", "PYTHONHOME", "LD_LIBRARY_PATH", "TAKE_A_LOOK_BACKEND_DIR", "TAKE_A_LOOK_PYTHON"):
        environment.pop(name, None)
    launcher = str(app / "take-a-look")
    print(command(launcher, "--doctor", env=environment, cwd=root), end="")
    report = json.loads(command(launcher, "--backend", "--self-test", env=environment, cwd=root))
    assert report["ok"] and report["checks"]["rpc"] == "ok", report
    requests = '\n'.join(json.dumps({"v": 2, "id": index, "method": method, "params": {}})
                         for index, method in enumerate(("handshake", "getState", "shutdown"), 1)) + '\n'
    responses = [json.loads(line) for line in command(
        launcher, "--backend", input=requests, env=environment, cwd=root).splitlines()]
    replies = {message["id"]: message for message in responses if "id" in message}
    assert replies[1]["result"]["protocolVersion"] == 2
    assert replies[2]["result"]["state"]["connectionStatus"] == "disconnected"
    assert "error" not in replies[3]

    # Spaces, Unicode, dollar signs and % must remain literal in installed paths.
    prefix = home / "local 中文 $cash 100%"
    installed = prefix / "lib/take-a-look"
    command(str(app / "install.sh"), "--no-deps", "--prefix", str(prefix), env=environment, cwd=root)
    assert (prefix / "bin/take-a-look").resolve() == installed / "take-a-look"
    desktop = prefix / "share/applications/com.example.take_a_look_v2.desktop"
    if shutil.which("desktop-file-validate"):
        command("desktop-file-validate", str(desktop))
    command(str(prefix / "bin/take-a-look"), "--doctor", env=environment, cwd=root)
    # A stale library from an old release must disappear on upgrade.
    (installed / "obsolete.so").touch()
    command(str(app / "install.sh"), "--no-deps", "--prefix", str(prefix), env=environment, cwd=root)
    assert not (installed / "obsolete.so").exists()
    # Verify the guard against deleting a directory that is not this installation.
    marker = installed / ".take-a-look-package"
    marker.unlink()
    refused = subprocess.run([str(installed / "uninstall.sh")], capture_output=True, timeout=10)
    assert refused.returncode != 0 and installed.is_dir()
    marker.touch()
    command(str(installed / "uninstall.sh"), env=environment, cwd=root)
    assert not installed.exists()
    assert not (prefix / "bin/take-a-look").is_symlink()
    assert not desktop.exists()
print("Archive verified: relocation, offline backend, RPC, install, upgrade, guarded uninstall.")
