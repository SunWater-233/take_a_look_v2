"""Measure EmberMobile private-protocol acquisition limits against a paired phone.

Read-only: never writes target memory. One variable is read through the same
paths the workstation uses (batch poll vs pushed sampling) so the observed
ceiling can be attributed to transport round trips or to the phone-side timer.
"""
from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--device", default="", help="paired device id (default: first paired)")
    parser.add_argument("--address", default="", help="symbol address to sample (default: first watch)")
    parser.add_argument("--length", type=int, default=4)
    parser.add_argument("--rounds", type=int, default=40)
    parser.add_argument("--seconds", type=float, default=3.0)
    args = parser.parse_args()

    sys.path.insert(0, str(args.source_root.resolve() / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    from take_a_look_backend.backends.ember_transport import EmberClient

    phones = PairingStore().phones()
    if not phones:
        print("no paired phone in the local pairing store")
        return 2
    phone = next((p for p in phones if p["id"] == args.device), phones[0])
    print(f"phone={phone['name']} host={phone['host']} port={phone['port']}")

    client = EmberClient(phone["host"], int(phone["port"]), phone["token"])
    try:
        print("hello:", client.call("hello"))
        info = client._legacy_call("v2_info", {}).get("v2") or {}
        caps = {key: info.get(key) for key in
                ("version", "alpn", "memory_batch", "memory_sampling", "memory_sampling_us")}
        print("advertisement:", caps)
        state = client.call("backend_state")
        connection = state.get("connection") or {}
        print("connection:", {key: connection.get(key) for key in
                              ("attached", "session_id", "probe", "state", "chip", "core_count")})
        print("rtt:", (state.get("rtt") or {}).get("state"))
        print("supports_memory_sampling:", client.supports_memory_sampling,
              "supports_memory_us:", client.supports_memory_microseconds)
        if not connection.get("attached"):
            print("target not attached on the phone; rate measurement needs an attached session")
            return 3
        session = int(connection["session_id"])

        def read(address: int, length: int) -> dict:
            return client.call("read_memory_batch", {"session_id": session, "core": 0,
                               "ranges": [{"address": address, "length": length}], "merge": True})

        address = int(args.address, 0) if args.address else None
        if address is None:
            # The phone has no symbol table; probe common Cortex-M/H7 RAM windows.
            for candidate in (0x24000000, 0x20000000, 0x30000000, 0x38000000, 0x08000000):
                try:
                    read(candidate, args.length)
                except Exception as error:
                    print(f"probe address {candidate:#x}: {error}")
                    continue
                address = candidate
                break
        if address is None:
            print("no readable address found; pass --address")
            return 4
        print("sampling address:", hex(address))

        request = {"session_id": session, "core": 0,
                   "ranges": [{"address": address, "length": args.length}], "merge": True}

        # 1. Poll path: one request/response round trip per sample.
        latencies, started = [], time.perf_counter()
        for _ in range(args.rounds):
            mark = time.perf_counter()
            read(address, args.length)
            latencies.append((time.perf_counter() - mark) * 1000)
        elapsed = time.perf_counter() - started
        latencies.sort()
        print(f"poll: rounds={len(latencies)} mean={statistics.fmean(latencies):.2f}ms "
              f"p50={latencies[len(latencies)//2]:.2f}ms "
              f"p95={latencies[int(len(latencies)*0.95)]:.2f}ms max={latencies[-1]:.2f}ms "
              f"-> ceiling={len(latencies)/elapsed:.1f}Hz")

        # 2. Push path: the phone clocks its own reads and streams them.
        if not client.supports_memory_sampling:
            print("phone does not advertise memory_sampling")
            return 0
        for rate in (100, 200, 500, 1000, 2000):
            period = ({"interval_ms": 0, "interval_us": max(1, round(1e6 / rate))}
                      if client.supports_memory_microseconds
                      else {"interval_ms": max(1, round(1000 / rate))})
            samples = client.sample_memory({"read": request, **period})
            try:
                deadline, count, sizes = time.perf_counter() + args.seconds, 0, set()
                stamps = []
                while time.perf_counter() < deadline:
                    packets = samples.read()
                    count += len(packets)
                    stamps.extend(stamp for stamp, _ in packets)
                    if not packets:
                        time.sleep(0.001)
                span = (max(stamps) - min(stamps)) / 1e6 if len(stamps) > 1 else 0
                rate_hz = (len(stamps) - 1) / span if span else 0.0
                print(f"push interval={period}: delivered={count} deviceRate={rate_hz:.1f}Hz "
                      f"residual={count / args.seconds:.1f}Hz dropped={samples.dropped} "
                      f"skippedTicks={samples.skipped_ticks} readDurationUs={samples.duration_us} "
                      f"reads={samples.reads}")
            finally:
                samples.close()
            time.sleep(0.15)
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
