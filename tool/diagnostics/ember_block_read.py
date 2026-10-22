"""Time whole-block reads through the phone.

This isolates the CMSIS-DAP block-read path (``DAP_TransferBlock``): one read of
``--bytes`` should cost one USB round trip per 1 KiB TAR window, not one per
56-byte packet. Run it before/after a probe-rs change to see the difference.

Read-only: never writes target memory.
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
    parser.add_argument("--device", default="")
    parser.add_argument("--address", default="0x24000000")
    parser.add_argument("--bytes", type=int, default=4096)
    parser.add_argument("--rounds", type=int, default=20)
    args = parser.parse_args()

    sys.path.insert(0, str(args.source_root.resolve() / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    from take_a_look_backend.backends.ember_transport import EmberClient

    phones = PairingStore().phones()
    if not phones:
        print("no paired phone in the local pairing store")
        return 2
    phone = next((p for p in phones if p["id"] == args.device), phones[0])
    client = EmberClient(phone["host"], int(phone["port"]), phone["token"])
    try:
        connection = (client.call("backend_state") or {}).get("connection") or {}
        if not connection.get("attached"):
            print("target not attached on the phone")
            return 3
        session = int(connection["session_id"])
        address = int(args.address, 0)
        timings: list[float] = []
        for _ in range(args.rounds):
            mark = time.perf_counter()
            reply = client.call("read_memory_batch", {
                "session_id": session, "core": 0,
                "ranges": [{"address": address, "length": args.bytes}], "merge": True,
            })
            got = len(reply["ranges"][0]["data"])
            timings.append((time.perf_counter() - mark) * 1000)
            if got != args.bytes:
                print(f"short read: {got} of {args.bytes} bytes")
                return 4
        timings.sort()
        mean = statistics.fmean(timings)
        print(f"{args.bytes}B read: mean={mean:.2f}ms p50={timings[len(timings) // 2]:.2f}ms "
              f"min={timings[0]:.2f}ms max={timings[-1]:.2f}ms "
              f"-> {args.bytes / (mean / 1000) / 1024:.1f} KiB/s")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
