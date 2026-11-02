"""Measure production decoding, acquisition, recording and control latency.

Use --source-root for an unchanged baseline checkout. The target returns raw
bytes, so typed memory decoding is included. No physical probe or UI is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import struct
import sys
import tempfile
import time


def percentile(values, fraction):
    return sorted(values)[min(int((len(values) - 1) * fraction), len(values) - 1)] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--rates", default="50,1000,10000")
    parser.add_argument("--channels", type=int, default=32)
    parser.add_argument("--layout", choices=("uint32", "mixed"), default="uint32")
    args = parser.parse_args()
    root = args.source_root.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(root / "backend"))
    from take_a_look_backend.backends.typed_memory import TypedMemoryBackend
    from take_a_look_backend.models import SymbolInfo
    from take_a_look_backend.protocol import EventName, RpcMethod
    from take_a_look_backend.service import BackendService

    class Target:
        def __init__(self, data):
            self.data = data

        def read_memory_block8(self, address, size):
            offset = address - 0x20000000
            return self.data[offset:offset + size]

        def write_memory_block8(self, address, data):
            offset = address - 0x20000000
            self.data[offset:offset + len(data)] = bytes(data)

    class Memory(TypedMemoryBackend):
        probe = None
        def __init__(self, data):
            super().__init__()
            self.target = Target(data)
            self.connected = False
            self.timestamps = []

        @property
        def is_connected(self):
            return self.connected

        def connect(self, config):
            self.connected = True

        def disconnect(self):
            self.connected = False

        def debug_state(self):
            return "running"

        def read_symbols(self, symbols):
            self.timestamps.append(time.perf_counter())
            return super().read_symbols(symbols)

    class Rtt:
        is_started = False
        transport_name = "disabled fixture"
        def stop(self):
            pass

    results = []
    for run in range(args.runs):
        for rate in map(float, args.rates.split(",")):
            symbols, data = [], bytearray()
            for i in range(args.channels):
                kind, fmt, value = "uint32_t", "<I", i
                if args.layout == "mixed" and i % 4:
                    kind, fmt, value = [("float", "<f", i + .25), ("int32_t", "<i", -i),
                                        ("double", "<d", i + .5)][i % 4 - 1]
                address = 0x20000000 + len(data)
                encoded = struct.pack(fmt, value)
                symbols.append(SymbolInfo(f"ch{i}", address, len(encoded), kind, ".data", "fixture.c"))
                data.extend(encoded)
            memory, delivered = Memory(data), [0]
            def event(name, params):
                if name is EventName.SAMPLES:
                    delivered[0] += len(params["frames"])
            with tempfile.TemporaryDirectory(prefix="throughput-", dir=args.output.parent) as directory:
                service = BackendService(event, memory_backend=memory,
                    normal_rtt_backend=Rtt(), plus_rtt_backend=Rtt(), recording_directory=Path(directory))
                with service._lock:
                    service._symbols = {symbol.key: symbol for symbol in symbols}
                service.handle(RpcMethod.SET_WATCHES, {"watches": [
                    {"key": symbol.key, "sampling": True, "plotted": True} for symbol in symbols]})
                service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": rate})
                started, cpu_started = time.perf_counter(), time.process_time()
                control_ms = []
                try:
                    service.handle(RpcMethod.CONNECT, {})
                    while time.perf_counter() - started < args.seconds:
                        time.sleep(min(.1, max(0, args.seconds - (time.perf_counter() - started))))
                        control_started = time.perf_counter()
                        service.handle(RpcMethod.WRITE_WATCH, {"key": symbols[0].key, "value": "0"})
                        control_ms.append((time.perf_counter() - control_started) * 1000)
                    pause_started = time.perf_counter()
                    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
                    pause_ms = (time.perf_counter() - pause_started) * 1000
                    capture_elapsed = time.perf_counter() - started
                    with service._lock:
                        service._flush_pending_samples_locked()
                    elapsed = time.perf_counter() - started
                finally:
                    service.close()
                cpu = time.process_time() - cpu_started
                count = len(memory.timestamps)
                if count != delivered[0] or count != service._recording.sample_count:
                    raise RuntimeError("Acquired, recorded and delivered frame counts differ.")
                intervals = [(b - a) * 1e6 for a, b in zip(memory.timestamps, memory.timestamps[1:])]
                result = {"run": run + 1, "requestedHz": rate, "channels": args.channels,
                    "acquiredFrames": count, "recordedFrames": service._recording.sample_count,
                    "deliveredFrames": delivered[0], "effectiveHz": count / elapsed,
                    "captureHz": count / capture_elapsed, "elapsedSecondsIncludingDrain": elapsed,
                    "cpuPercentOfOneCoreIncludingDrain": cpu / elapsed * 100,
                    "intervalMedianUs": statistics.median(intervals),
                    "intervalP95Us": percentile(intervals, .95), "intervalP99Us": percentile(intervals, .99),
                    "writeReadbackMedianMs": statistics.median(control_ms),
                    "writeReadbackP95Ms": percentile(control_ms, .95), "pauseMs": pause_ms,
                    "recordingBytes": service._recording.committed_bytes}
                print(json.dumps(result), flush=True)
                results.append(result)
    report = {"status": "passed", "python": sys.version, "sourceRoot": str(root),
        "layout": args.layout, "scope": "Production typed decoding, sampling, raw journal and numeric history, "
        "internal event delivery, concurrent explicit write/readback about every 100 ms. Raw-byte fake "
        "target; no physical USB/SWD/network/stdio/UI. CPU and effectiveHz include final drain. "
        "This is a short host throughput test, not hardware or long-run stability proof.",
        "sourceSha256": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in (root / "backend/take_a_look_backend").rglob("*.py")},
        "results": results}
    args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
