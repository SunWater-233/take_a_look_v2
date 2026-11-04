"""Small subprocess fixture exercising Dart's actual RPC/timeout transport."""
import json
import sys
import time


def send(message):
    print(json.dumps({"v": 3, **message}), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "handshake":
        send({"id": request["id"], "result": {"state": {"connectionStatus": "disconnected"}}})
    elif method == "loadFirmware":
        params = request["params"]
        if params["path"] == "broken.elf":
            print("{invalid JSON}", flush=True)
            continue
        if params["path"] == "exit.elf":
            sys.exit(3)
        send({"event": "symbolLoadProgress", "params": {
            "loadId": params["loadId"], "phase": "debug", "current": 96, "total": 160,
        }})
        time.sleep(3.2)
        state = {"sourceProject": {"firmwarePath": params["path"]}, "firmware": {"status": "ready"}, "symbols": [], "debug": {"sourceFiles": ["main.c"]}}
        send({"event": "state", "params": state})
        send({"id": request["id"], "result": {"state": state}})
    elif method == "getState":
        time.sleep(3.2)
        send({"id": request["id"], "result": {"state": {}}})
    elif method == "shutdown":
        send({"id": request["id"], "result": {}})
        break
