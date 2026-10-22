"""Offline checks for the distributed runtime; no probe is opened or modified."""

from __future__ import annotations

import importlib
import json
import platform
import sys


def run() -> int:
    checks: dict[str, object] = {"python": platform.python_version()}
    errors: list[str] = []
    modules = [
        "elftools.elf.elffile", "cmsis_pack_manager", "pylink",
        "pygdbmi.gdbmiparser", "aioquic.asyncio.client",
        "aioquic._crypto", "aioquic._buffer",
        "take_a_look_backend.backends.remote_backend",
        "take_a_look_backend.backends.ember_v2",
        "take_a_look_backend.backends.ember_pairing", "zeroconf",
        "take_a_look_backend.backends.remote_firmware",
        "take_a_look_backend.backends.gdb_rsp",
    ]
    # Linux CMSIS-DAP v1 uses PyUSB; hidapi is a Windows/macOS dependency.
    if sys.platform in ("win32", "darwin"):
        modules.append("hid")
    for name in modules:
        try:
            importlib.import_module(name)
            checks[name] = "ok"
        except Exception as error:
            errors.append(f"{name}: {error}")

    try:
        from usb.backend import libusb1

        if sys.platform == "win32":
            import libusb_package

            backend = libusb1.get_backend(find_library=libusb_package.find_library)
        else:
            backend = libusb1.get_backend()
        if backend is None:
            raise RuntimeError("libusb-1.0 could not be loaded")
        checks["libusb"] = "ok"
    except Exception as error:
        errors.append(f"libusb: {error}")

    try:
        from pyocd.probe.aggregator import PROBE_CLASSES

        checks["probe_plugins"] = sorted(PROBE_CLASSES)
        checks["jlink_runtime"] = "available" if "jlink" in PROBE_CLASSES else "optional; install SEGGER J-Link separately"
        missing = {"cmsisdap", "stlink"} - PROBE_CLASSES.keys()
        if missing:
            raise RuntimeError(f"Missing pyOCD plugins: {', '.join(sorted(missing))}")
    except Exception as error:
        errors.append(f"pyocd: {error}")

    # Exercise the same RPC server used by Flutter, including its sampler shutdown.
    try:
        import io

        from take_a_look_backend.stdio import StdioServer

        output = io.BytesIO()
        requests = '\n'.join(
            json.dumps({"v": 2, "id": index, "method": method, "params": {}})
            for index, method in enumerate(("handshake", "listTargets", "shutdown"), 1)
        ) + '\n'
        StdioServer(io.StringIO(requests), output).run()
        responses = {
            message["id"]: message
            for line in output.getvalue().splitlines()
            if "id" in (message := json.loads(line))
        }
        if responses[1]["result"]["protocolVersion"] != 2:
            raise RuntimeError("Unexpected protocol version")
        if "memoryWriteBatch" not in responses[1]["result"]["capabilities"]:
            raise RuntimeError("Batch memory-write support is missing")
        if len(responses[2]["result"]["targets"]) < 100:
            raise RuntimeError("Builtin target catalogue is missing")
        if responses[3]["result"]["state"]["connectionStatus"] != "disconnected":
            raise RuntimeError("Backend shutdown failed")
        checks["rpc"] = "ok"
        checks["target_catalog"] = "ok"
    except Exception as error:
        errors.append(f"rpc: {error}")

    print(json.dumps({"ok": not errors, "checks": checks, "errors": errors}, ensure_ascii=True))
    return 1 if errors else 0
