"""Read-only standard GDB memory benchmark. Does not reset or program firmware.

Use --resume explicitly if the server halts the target on connection. Server
disconnect policies still apply. Without --resume, no run-control packets run.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import RpcMethod, EventName
from take_a_look_backend.service import BackendService


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3333)
    parser.add_argument("--address", type=lambda text: int(text, 0), default=0x20000000)
    parser.add_argument("--variables", type=int, default=1)
    parser.add_argument("--stride", type=int, default=4)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--mode", choices=["memory", "debug"], default="memory")
    parser.add_argument("--gdb", default="")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--service", action="store_true", help="include capture, recording and publication")
    parser.add_argument("--rate", type=float, default=7000)
    args = parser.parse_args()
    if args.seconds <= 0 or not 1 <= args.variables <= 128 or args.stride < 4:
        parser.error("seconds > 0, variables in 1..128, stride >= 4 required")
    if args.mode == "debug" and (args.resume or args.service):
        parser.error("MI debug reads require a halted target; service/resume need --mode memory")
    config = {"host": args.host, "gdbPort": str(args.port), "gdbPath": args.gdb, "gdbMode": args.mode}
    symbols = [SymbolInfo(f"probe{i}", args.address + i * args.stride, 4, "uint32_t", ".data")
               for i in range(args.variables)]
    if args.service:
        frames = [0]
        perf = []
        errors = []
        def event(name, payload):
            if name == EventName.SAMPLES:
                frames[0] += len(payload.get("frames", []))
            elif name == EventName.PERF:
                perf.append(payload.get("effectiveHz", 0))
            elif name == EventName.ERROR or (name == EventName.LOG and payload.get("level") == "error"):
                errors.append(payload)
        with tempfile.TemporaryDirectory(prefix="tal_gdb_rate_") as directory:
            service = BackendService(event, recording_directory=Path(directory))
            try:
                with service._lock:
                    service._symbols = {symbol.key: symbol for symbol in symbols}
                service.handle(RpcMethod.CONNECT, {"connectionKind": "gdb", "remoteConfig": config})
                if args.resume:
                    service.handle(RpcMethod.DEBUG_CONTROL, {"action": "resume"})
                service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": args.rate})
                service.handle(RpcMethod.SET_WATCHES, {"watches": [
                    {"key": s.key, "readMode": "capture", "plotted": True} for s in symbols]})
                start, cpu = time.perf_counter(), time.process_time()
                time.sleep(args.seconds)
                service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
                with service._lock:
                    service._flush_pending_samples_locked()
                service._recording_worker.submit(lambda: None).result()
                elapsed, cpu_time = time.perf_counter() - start, time.process_time() - cpu
                print(json.dumps({"mode": "service", "variables": args.variables, "frames": frames[0],
                    "recorded": service._recording.sample_count, "hz": frames[0] / elapsed,
                    "cpu_one_core_percent": 100 * cpu_time / elapsed, "perf_hz": perf,
                    "errors": errors}, ensure_ascii=False))
            finally:
                service.close()
        return
    backend = RemoteMemoryBackend("gdb", config)
    backend.connect()
    try:
        if args.resume:
            backend.resume()
        timings = []
        start, cpu = time.perf_counter(), time.process_time()
        while time.perf_counter() - start < args.seconds:
            before = time.perf_counter()
            backend.read_symbols(symbols)
            timings.append(time.perf_counter() - before)
        elapsed = time.perf_counter() - start
        ordered = sorted(timings)
        print(json.dumps({"mode": args.mode, "variables": args.variables, "frames": len(timings),
            "hz": len(timings) / elapsed, "median_us": statistics.median(timings) * 1e6,
            "p95_us": ordered[min(len(ordered) - 1, int(len(ordered) * .95))] * 1e6,
            "cpu_one_core_percent": 100 * (time.process_time() - cpu) / elapsed,
            "read_metrics": backend.last_read_metrics}))
    finally:
        backend.disconnect()


if __name__ == "__main__":
    main()
