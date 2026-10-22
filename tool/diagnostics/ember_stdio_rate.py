"""Drive the packaged backend over stdio exactly as the Flutter app does.

Spawns ``take_a_look_backend.exe``, loads a real ELF, connects to the paired
phone, watches one variable and reports the delivered rate from ``perf`` events.
This exercises the production pipe encoding, recording worker and sampling loop.
"""
from __future__ import annotations

import argparse
import io
import json
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path


class Backend:
    def __init__(self, executable: Path) -> None:
        self.process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
        self.events: list[tuple[str, object]] = []
        self.frames = 0
        self._id = 0
        self._lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        # Popen uses bufsize=0 so requests flush immediately. Buffer the reader
        # separately: FileIO.readline() otherwise issues a Windows pipe read
        # for every byte of a large ELF symbol-table response.
        stream = io.BufferedReader(self.process.stdout, buffer_size=65536)
        def exact(size):
            result = bytearray()
            while len(result) < size:
                part = stream.read(size - len(result))
                if not part:
                    raise EOFError("backend pipe closed inside a frame")
                result.extend(part)
            return bytes(result)
        while True:
            head = stream.read(1)
            if not head:
                return
            if head == b"\x00":
                size = struct.unpack("<I", exact(4))[0]
                payload = exact(size)
                frames = struct.unpack_from("<I", payload, 9)[0] if len(payload) > 13 else 0
                with self._lock:
                    self.frames += frames
                continue
            line = head + stream.readline()
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "event" in message:
                with self._lock:
                    self.events.append((message["event"], message.get("params")))
            elif "id" in message:
                with self._lock:
                    self.events.append((f"reply:{message['id']}", message))

    def call(self, method: str, params: dict, timeout: float = 30.0) -> dict:
        self._id += 1
        request_id = self._id
        self.process.stdin.write((json.dumps(
            {"v": 2, "id": request_id, "method": method, "params": params}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            with self._lock:
                for name, payload in self.events:
                    if name == f"reply:{request_id}":
                        if isinstance(payload, dict) and "error" in payload:
                            raise RuntimeError(f"{method}: {payload['error']}")
                        return payload.get("result") or {}
            time.sleep(0.01)
        raise TimeoutError(f"{method} did not reply")

    def drain(self) -> tuple[list[tuple[str, object]], int]:
        with self._lock:
            events, self.events = self.events, []
            frames, self.frames = self.frames, 0
            return events, frames


def pick(symbols: list[dict]) -> dict:
    scalar = {"uint32_t", "int32_t", "float", "uint16_t", "int16_t", "uint8_t", "int8_t"}
    usable = [s for s in symbols
              if s.get("writable") and s.get("dataSource") == "memory"
              and 1 <= s["size"] <= 8 and s["type"] in scalar]
    if not usable:
        raise SystemExit("no scalar RAM symbol in the ELF")
    return next((s for s in usable if s["type"] == "float"), usable[0])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--rates", default="100,1000,2000")
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--variables", type=int, default=1)
    parser.add_argument("--min-gap", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--token-from-pairing", action="store_true", default=True)
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))
    from take_a_look_backend.backends.ember_pairing import PairingStore
    phone = PairingStore().phones()[0]

    backend = Backend(args.exe)
    try:
        state = backend.call("loadSymbols", {"path": str(args.elf)})["state"]
        symbol = pick(state["symbols"])
        selected = [symbol]
        for candidate in state["symbols"]:
            if len(selected) >= args.variables:
                break
            if (candidate.get("writable") and candidate.get("dataSource") == "memory"
                    and candidate.get("type") == symbol["type"] and candidate["size"] == 4
                    and all(candidate["key"] != other["key"] and
                            abs(candidate["address"] - other["address"]) >= args.min_gap
                            for other in selected)):
                selected.append(candidate)
        if len(selected) != args.variables:
            raise SystemExit("not enough distinct scalar RAM symbols in the ELF")
        for symbol in selected:
            print(f"symbol={symbol['name']} type={symbol['type']} address={symbol['address']:#x}")
        backend.call("setConfig", {
            "connectionKind": "ember",
            "remoteConfig": {"host": phone["host"], "gatewayPort": str(phone["port"]),
                             "token": phone["token"]},
        })
        backend.call("connect", {})
        backend.call("setWatches", {"watches": [
            {"key": symbol["key"], "sampling": True, "plotted": True, "readMode": "capture"}
            for symbol in selected]})
        for rate in (int(value) for value in args.rates.split(",") if value):
            backend.call("setConfig", {"sampleRateHz": rate})
            time.sleep(0.5)
            backend.drain()
            deadline = time.perf_counter() + args.seconds
            last, total = {}, 0
            while time.perf_counter() < deadline:
                events, frames = backend.drain()
                total += frames
                for name, payload in events:
                    if name == "perf" and isinstance(payload, dict):
                        last = payload
                time.sleep(0.05)
            print(f"rate={rate:5d}Hz effectiveHz={last.get('effectiveHz', 0):7.1f} "
                  f"mode={last.get('memorySamplingMode', '-')} "
                  f"phoneReadUs={last.get('memoryPhoneReadUs', 0):5d} "
                  f"skipped={last.get('memorySkippedTicks', 0):5d} "
                  f"framesSeen={total}")
        return 0
    finally:
        try:
            backend.call("shutdown", {}, timeout=5)
        except Exception:
            backend.process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
