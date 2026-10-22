"""Drive the real BackendService against a paired phone and report effective Hz.

This reproduces the workstation's full acquisition path (service sampling loop,
recording worker, sample publication) without the Flutter UI, so a rate ceiling
can be attributed to the phone, the transport, or the workstation pipeline.
"""
from __future__ import annotations

import argparse
import sys
import tempfile
import threading
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--device", default="")
    parser.add_argument("--kind", default="ember", choices=["ember", "emberGdb"])
    parser.add_argument("--address", default="0x24000000")
    parser.add_argument("--rates", default="100,200,500,1000,2000")
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--variables", type=int, default=1)
    parser.add_argument("--stride", type=lambda value: int(value, 0), default=4,
                        help="byte distance between variables; use 64 to exercise scattered addresses")
    parser.add_argument("--no-debug-poll", action="store_true",
                        help="suppress the periodic debug_status RPC that shares the phone probe worker")
    parser.add_argument("--verbose", action="store_true", help="print every perf window")
    parser.add_argument("--no-escalate", action="store_true",
                        help="keep the phone timer even when it cannot meet the request")
    args = parser.parse_args()

    sys.path.insert(0, str(args.source_root.resolve() / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    from take_a_look_backend.models import SymbolInfo
    from take_a_look_backend.protocol import EventName, RpcMethod
    from take_a_look_backend.service import BackendService

    phones = PairingStore().phones()
    if not phones:
        print("no paired phone in the local pairing store")
        return 2
    phone = next((p for p in phones if p["id"] == args.device), phones[0])
    print(f"phone={phone['host']}:{phone['port']} kind={args.kind}")

    perf: list[dict] = []
    samples = [0]
    lock = threading.Lock()

    def event(name, params):
        if name is EventName.PERF:
            with lock:
                perf.append(params)
            if args.verbose:
                print(f"  perf hz={params.get('effectiveHz', 0):7.1f} "
                      f"n={params.get('sampleCount', 0):4d} "
                      f"mode={params.get('memorySamplingMode', '-')} "
                      f"skipped={params.get('memorySkippedTicks', 0)}")
        elif name is EventName.SAMPLES:
            with lock:
                samples[0] += len(params.get("frames", []))
        elif name is EventName.ERROR:
            print("ERROR:", params)
        elif name is EventName.LOG and params.get("level") == "error":
            print("LOG:", params.get("message"))

    base = int(args.address, 0)
    symbols = [SymbolInfo(f"probe{i}", base + i * args.stride, 4, "uint32_t", ".data", "probe.c")
               for i in range(args.variables)]
    with tempfile.TemporaryDirectory(prefix="tal_ember_rate_") as directory:
        service = BackendService(event, recording_directory=Path(directory))
        try:
            if args.no_debug_poll:
                service._next_debug_poll_at = float("inf")
                service._poll_debug_state_locked = lambda: None
            if args.no_escalate:
                # connect() builds a fresh backend, so patch the class, not the instance.
                from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
                RemoteMemoryBackend._evaluate_sampling_mode = lambda *arguments: None
            with service._lock:
                service._symbols = {symbol.key: symbol for symbol in symbols}
            service.handle(RpcMethod.CONNECT, {
                "connectionKind": args.kind,
                "remoteConfig": {"host": phone["host"], "gatewayPort": str(phone["port"]),
                                 "token": phone["token"]},
            })
            service.handle(RpcMethod.SET_WATCHES, {"watches": [
                {"key": symbol.key, "sampling": True, "plotted": True, "readMode": "capture"}
                for symbol in symbols]})
            for rate in (int(value) for value in args.rates.split(",") if value):
                with lock:
                    perf.clear()
                    samples[0] = 0
                service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": rate})
                time.sleep(0.4)
                with lock:
                    perf.clear()
                    samples[0] = 0
                deadline = time.perf_counter() + args.seconds
                last = None
                rows = []
                while time.perf_counter() < deadline:
                    time.sleep(0.1)
                    with lock:
                        if perf:
                            last = dict(perf[-1])
                            rows.append(last)
                payload = last or {}
                delivered, _ = samples[0], None
                print(f"rate={rate:5d}Hz effectiveHz={payload.get('effectiveHz', 0):7.1f} "
                      f"samples={payload.get('sampleCount', 0):5d} "
                      f"mode={payload.get('memorySamplingMode', '-'):5s} "
                      f"phoneReadUs={payload.get('memoryPhoneReadUs', 0):5d} "
                      f"readBlocks={payload.get('readBlockCount', 0)} "
                      f"readBytes={payload.get('readByteCount', 0)} "
                      f"readDurationUs={payload.get('memoryReadDurationUs', 0)} "
                      f"dropped={payload.get('memoryDroppedSamples', 0)} "
                      f"skipped={payload.get('memorySkippedTicks', 0)} "
                      f"deliveredAggregate={delivered}")
        finally:
            service.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
