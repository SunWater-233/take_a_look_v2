"""Read-only repeat validation on the prepared, paired phone and running target.

Reports batch cadence separately from read throughput. No target reset, halt,
firmware download or memory write is performed. Addresses must be readable RAM.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", type=lambda x: int(x, 0), default=0x24000000)
    parser.add_argument("--seconds", type=float, default=4)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    from take_a_look_backend.backends.ember_transport import EmberClient, EmberError

    phone = PairingStore().phones()[0]
    client = EmberClient(phone["host"], int(phone["port"]), phone["token"])
    report = {"endpoint": f"{phone['host']}:{phone['port']}", "cases": []}
    try:
        state = client.call("backend_state")
        connection = state.get("connection") or {}
        assert connection.get("attached") and connection["core"]["state"] == "running", connection
        report["target"] = connection
        report["capabilities"] = {key: value for key, value in client.call("hello")["v2"].items()
                                  if key.startswith("memory_")}
        assert client.memory_repeat_limit >= 8
        assert client.memory_burst_word_limit == 8
        session = connection["session_id"]

        def request(words, interval_ms=0):
            return {"read": {"session_id": session, "core": 0, "merge": True,
                             "ranges": [{"address": args.address + i * 64, "length": 4}
                                        for i in range(words)]}, "interval_ms": interval_ms}

        def run(words, repeat, interval_ms=0):
            stream = client.sample_memory(request(words, interval_ms), repeat=repeat)
            packets = []
            started = time.perf_counter()
            try:
                while time.perf_counter() - started < args.seconds:
                    packets.extend(stream.read_packets())
                    time.sleep(.001)
                packets.extend(stream.read_packets())
                assert len(packets) > 2
                assert all(len(data) == words * repeat * 4 for _, _, _, data in packets)
                assert all(a[0] < b[0] and a[1] <= b[1] for a, b in zip(packets, packets[1:]))
                span = (packets[-1][1] - packets[0][1]) / 1e6
                gaps = [b[1] - a[1] for a, b in zip(packets, packets[1:])]
                result = {"words": words, "repeat": repeat, "interval_ms": interval_ms,
                          "batches": len(packets), "read_count": len(packets) * repeat,
                          "batch_hz": (len(packets) - 1) / span,
                          "read_throughput_hz": (len(packets) - 1) * repeat / span,
                          "median_transaction_us": statistics.median(p[2] for p in packets),
                          "median_batch_gap_us": statistics.median(gaps),
                          "max_batch_gap_us": max(gaps), "dropped_batches": stream.dropped_batches,
                          "dropped_samples": stream.dropped_samples, "skipped_ticks": stream.skipped_ticks,
                          "subread_time_quality": "transaction_window" if repeat > 1 else "phone_submission"}
                assert result["dropped_samples"] == result["dropped_batches"] * repeat
                report["cases"].append(result)
                print(json.dumps(result), flush=True)
            finally:
                stream.close()

        for repeat in (1, 2, 4, 8):
            run(1, repeat)
        run(1, 2, 1)
        run(3, 2)
        try:
            unexpected = client.sample_memory(request(3), repeat=3)
        except EmberError as error:
            assert error.code == "invalid_params", (error.code, str(error))
            report["nine_word_request"] = "rejected_before_read"
        else:
            unexpected.close()
            raise AssertionError("Nine-word burst exceeded the advertised budget")
        # Rejection must release its sampling slot and leave ordinary IO working.
        request_read = request(1)["read"]
        assert len(client.call("read_memory_batch", request_read)["ranges"][0]["data"]) == 4
        report["after"] = client.call("backend_state")["connection"]
        assert report["after"]["core"]["state"] == "running"
    finally:
        client.close()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
