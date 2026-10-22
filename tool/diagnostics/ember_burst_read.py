"""Read the take_a_look burst ring from the phone and report the real sample rate.

The target firmware writes one entry per control tick (see
``Application/Tasks/Src/chassis_task.c`` in the chassis firmware) and the host
reads the whole ring with one ``read_memory_batch``. Sample times come from the
target's DWT cycle counter, so the measured rate is the firmware loop rate and
not the USB round-trip rate.

Read-only: never writes target memory.
"""
from __future__ import annotations

import argparse
import statistics
import struct
import sys
import time
from pathlib import Path

MAGIC = 0x54414C31  # "TAL1"
HEADER = struct.Struct("<IIIII")  # magic, capacity, channels, period_us, head
# Entry: t_us + channels * f32.
MAX_CHANNELS = 8


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--device", default="", help="paired device id (default: first paired)")
    parser.add_argument("--address", default="0x24006d54", help="tal_burst_buffer address")
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--interval", type=float, default=0.02, help="poll period in seconds")
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
        state = client.call("backend_state")
        connection = state.get("connection") or {}
        if not connection.get("attached"):
            print("target not attached on the phone")
            return 3
        session = int(connection["session_id"])
        print("chip:", connection.get("chip"), "probe:", connection.get("probe"))

        def read(address: int, length: int) -> bytes:
            reply = client.call("read_memory_batch", {
                "session_id": session, "core": 0,
                "ranges": [{"address": address, "length": length}], "merge": True,
            })
            data = reply["ranges"][0]["data"]
            return data if isinstance(data, (bytes, bytearray)) else bytes.fromhex(data)

        base = int(args.address, 0)
        header = HEADER.unpack(read(base, HEADER.size))
        magic, capacity, channels, period_us, head = header
        if magic != MAGIC:
            print(f"no burst ring at {base:#x}: magic={magic:#x}")
            return 4
        if not 1 <= channels <= MAX_CHANNELS or capacity == 0:
            print(f"unsupported ring: capacity={capacity} channels={channels}")
            return 5
        entry = struct.Struct("<I" + "f" * channels)
        size = HEADER.size + capacity * entry.size
        print(f"ring: address={base:#x} capacity={capacity} channels={channels} "
              f"period={period_us}us size={size}B head={head}")

        started = time.perf_counter()
        polls = 0
        new_samples = 0
        last_head = head
        deltas: list[int] = []
        values = [0.0] * channels
        read_ms: list[float] = []
        lost = 0

        while time.perf_counter() - started < args.seconds:
            mark = time.perf_counter()
            block = read(base, size)
            read_ms.append((time.perf_counter() - mark) * 1000)
            polls += 1

            magic, capacity, channels, period_us, head = HEADER.unpack_from(block)
            if magic != MAGIC:
                print("ring magic changed; target reset?")
                return 6
            entry = struct.Struct("<I" + "f" * channels)
            advance = head - last_head
            if advance > capacity:
                lost += advance - capacity
                advance = capacity
            # The newest entry may be partially written; start one behind.
            first = head - advance
            previous_t = None
            for index in range(first, head):
                offset = HEADER.size + (index % capacity) * entry.size
                t_us, *sample = entry.unpack_from(block, offset)
                if previous_t is not None:
                    delta = (t_us - previous_t) & 0xFFFFFFFF
                    if delta < 10_000_000:
                        deltas.append(delta)
                previous_t = t_us
                values = sample
                new_samples += 1
            last_head = head
            time.sleep(max(0.0, args.interval - (time.perf_counter() - mark)))

        elapsed = time.perf_counter() - started
        print(f"polls={polls} in {elapsed:.2f}s ({polls / elapsed:.1f}/s), "
              f"block read mean={statistics.fmean(read_ms):.2f}ms "
              f"max={max(read_ms):.2f}ms")
        if not deltas:
            print("no timestamp deltas collected; is the firmware running the 1 kHz loop?")
            return 0
        deltas.sort()
        mean = statistics.fmean(deltas)
        print(f"samples={new_samples} lost={lost} rate={new_samples / elapsed:.1f}/s "
              f"firmware {1e6 / mean:.1f}Hz")
        print(f"interval us: mean={mean:.1f} p50={deltas[len(deltas) // 2]} "
              f"p95={deltas[int(len(deltas) * 0.95)]} max={deltas[-1]} "
              f"stdev={statistics.pstdev(deltas):.1f}")
        print("last values:", [round(v, 4) for v in values])
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
