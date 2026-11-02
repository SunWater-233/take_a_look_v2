"""Characterise EmberMobile phone-side sampling limits for one small variable.

Read-only. Compares the timed push stream against continuous (interval 0) and
aggregated parallel streams, which is where USB round-trip latency can be hidden.
"""
from __future__ import annotations

import argparse
import sys
import threading
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--device", default="")
    parser.add_argument("--address", default="0x24000000")
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--streams", default="1,2,4")
    args = parser.parse_args()

    sys.path.insert(0, str(args.source_root.resolve() / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    from take_a_look_backend.backends.ember_transport import EmberClient

    phone = next((p for p in PairingStore().phones() if p["id"] == args.device),
                 PairingStore().phones()[0])
    client = EmberClient(phone["host"], int(phone["port"]), phone["token"])
    address = int(args.address, 0)
    try:
        state = client.call("backend_state")
        session = int((state.get("connection") or {})["session_id"])
        read = {"session_id": session, "core": 0,
                "ranges": [{"address": address, "length": 4}], "merge": True}

        def run(count: int, period: dict) -> None:
            samples, results, counters = [], [], []
            for _ in range(count):
                samples.append(client.sample_memory({"read": read, **period}))
            stop = threading.Event()
            counts = [0] * count
            durations = [0] * count
            cursors = [0] * count

            def drain(index: int) -> None:
                while not stop.is_set():
                    packets = samples[index].read()
                    counts[index] += len(packets)
                    if packets:
                        durations[index] = samples[index].duration_us
                    else:
                        time.sleep(0.0005)

            threads = [threading.Thread(target=drain, args=(i,), daemon=True) for i in range(count)]
            started = time.perf_counter()
            for thread in threads:
                thread.start()
            time.sleep(args.seconds)
            stop.set()
            for thread in threads:
                thread.join()
            span = time.perf_counter() - started
            for index in range(count):
                results.append({"delivered": counts[index], "lastDurationUs": durations[index],
                                "skipped": samples[index].skipped_ticks})
            for sample in samples:
                sample.close()
            total = sum(item["delivered"] for item in results)
            print(f"streams={count} period={period}: aggregate={total / span:7.1f}Hz "
                  f"perStream={[round(item['delivered'] / span, 1) for item in results]} "
                  f"readUs={[item['lastDurationUs'] for item in results]} "
                  f"skipped={[item['skipped'] for item in results]}")
            time.sleep(0.2)

        for count in (int(value) for value in args.streams.split(",") if value):
            run(count, {"interval_ms": 0})
        for count in (1, 2, 4):
            run(count, {"interval_ms": 1})
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
