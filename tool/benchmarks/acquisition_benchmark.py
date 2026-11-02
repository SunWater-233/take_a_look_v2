"""Compare the production acquisition/recording loop using a zero-I/O fake probe."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--seconds", type=float, default=1.5)
    parser.add_argument("--affinity", type=int, default=0)
    args = parser.parse_args()
    if args.affinity:
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        kernel.SetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.c_size_t]
        if not kernel.SetProcessAffinityMask(kernel.GetCurrentProcess(), args.affinity):
            raise ctypes.WinError(ctypes.get_last_error())
    source = args.source_root.resolve()
    sys.path.insert(0, str(source / "backend"))
    from take_a_look_backend.service import BackendService
    from take_a_look_backend.models import SymbolInfo
    from take_a_look_backend.protocol import EventName, RpcMethod

    class Memory:
        target = object()
        probe = object()
        supports_running_memory = True
        def __init__(self):
            self.reads = 0
            self.connected = False
            self.last_read_metrics = {"block_count": 1, "byte_count": 128}
        @property
        def is_connected(self):
            return self.connected
        def connect(self, _config):
            self.connected = True
        def disconnect(self):
            self.connected = False
        def debug_state(self):
            return "running"
        def read_symbols(self, symbols):
            self.reads += 1
            return {symbol.key: self.reads for symbol in symbols}

    class Rtt:
        is_started = False
        transport_name = "disabled fixture"
        def stop(self):
            pass

    results = []
    for run in range(args.runs):
        for rate in (50, 1000, 10000):
            memory = Memory()
            delivered = [0]
            def event(name, params):
                if name is EventName.SAMPLES:
                    delivered[0] += len(params["frames"])
            with tempfile.TemporaryDirectory(prefix="tal_acquisition_benchmark_") as directory:
                service = BackendService(event, memory_backend=memory,
                    normal_rtt_backend=Rtt(), plus_rtt_backend=Rtt(),
                    recording_directory=Path(directory))
                symbols = [SymbolInfo(f"ch{i}", 0x20000000 + i * 4, 4, "uint32_t", ".data", "fixture.c")
                           for i in range(32)]
                with service._lock:
                    service._symbols = {symbol.key: symbol for symbol in symbols}
                service.handle(RpcMethod.SET_WATCHES, {"watches": [
                    {"key": symbol.key, "sampling": True, "plotted": True} for symbol in symbols]})
                service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": rate})
                cpu_started = time.process_time()
                started = time.perf_counter()
                try:
                    service.handle(RpcMethod.CONNECT, {})
                    time.sleep(args.seconds)
                    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
                    # Drain before close disables event delivery. Otherwise the
                    # final committed batch is counted as a false transport loss.
                    with service._lock:
                        service._flush_pending_samples_locked()
                    elapsed = time.perf_counter() - started
                finally:
                    service.close()
                cpu_seconds = time.process_time() - cpu_started
                recorded = service._recording.sample_count
                if delivered[0] != memory.reads or recorded != memory.reads:
                    raise RuntimeError(f"Sample mismatch: {memory.reads}, {delivered[0]}, {recorded}")
                results.append({"run": run + 1, "requestedHz": rate, "channels": 32,
                    "acquiredFrames": memory.reads, "recordedFrames": recorded,
                    "deliveredFrames": delivered[0], "elapsedSeconds": elapsed,
                    "effectiveHz": memory.reads / elapsed, "cpuSecondsIncludingDrain": cpu_seconds,
                    "recordingBytes": service._recording.committed_bytes})
                print(json.dumps(results[-1]), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"status": "passed", "python": sys.version,
        "sourceRoot": str(source), "processorAffinity": args.affinity,
        "clocks": {name: vars(time.get_clock_info(name)) for name in ("monotonic", "perf_counter")},
        "scope": "Production memory scheduling, 32-channel sample handling, "
        "JSONL disk recording and event delivery. Fake probe, no USB/network/stdio pipe. "
        "These rates do not establish hardware throughput. CPU time includes final drain.",
        "sourceSha256": {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in (source / "backend/take_a_look_backend").rglob("*.py")},
        "results": results}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
