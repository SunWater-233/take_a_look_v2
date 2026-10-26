"""Append-only raw journals; plot retention never affects acquisition history."""
from __future__ import annotations

import csv
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import BinaryIO, Iterable, Mapping

from .numeric_history import NumericHistory, write_block


def recording_directory() -> Path:
    if configured := os.environ.get("TAL_RECORDINGS_DIR"):
        return Path(configured)
    # The desktop launcher passes its own executable directory above. Direct
    # backend launches use the backend bundle/source directory, never AppData
    # or the Python interpreter's installation directory in development mode.
    root = (Path(sys.executable).resolve().parent if getattr(sys, "frozen", False)
            else Path(__file__).resolve().parents[2])
    return root / "recordings"


class RawRecording:
    def __init__(self, directory: Path | None = None) -> None:
        self.directory = directory or recording_directory()
        self.path: Path | None = None
        self._file: BinaryIO | None = None
        self._ids: dict[str, int] = {}
        self._channels: list[dict[str, str]] = []
        self.sample_count = 0
        self.committed_bytes = 0
        self.failure: Exception | None = None
        self._closed = False
        self._history: NumericHistory | None = None

    def status(self) -> dict[str, object]:
        return {"path": str(self.path) if self.path else None,
                "sampleCount": self.sample_count, "bytes": self.committed_bytes,
                "historyPath": str(self._history.directory) if self._history else None,
                **({"error": str(self.failure)} if self.failure else {})}

    def append(self, frames: Iterable[tuple[float, dict[str, object]]], labels: Mapping[str, str]) -> None:
        if self._closed:
            raise RuntimeError("Raw recording is closed.")
        if self.failure:
            raise RuntimeError(f"Raw recording stopped: {self.failure}") from self.failure
        try:
            previous_channels = len(self._channels)
            rows, timings = [], []
            for frame in frames:
                elapsed, values = frame
                if not values:
                    continue
                row: list[object] = [elapsed]
                for key, value in values.items():
                    if key not in self._ids:
                        self._ids[key] = len(self._channels)
                        self._channels.append({"key": key, "name": labels.get(key, key)})
                    row.extend((self._ids[key], value))
                rows.append(row)
                timings.append(getattr(frame, "timing", None))
            if not rows:
                return
            if self._file is None:
                self.directory.mkdir(parents=True, exist_ok=True)
                self.path = Path(tempfile.mkdtemp(prefix="session-", dir=self.directory)) / "samples.talraw"
                self._file = self.path.open("wb", buffering=0)
                self._history = NumericHistory(self.path.parent / "history")
            records = []
            if self.committed_bytes == 0:
                records.append({"format": "take-a-look-raw", "version": 1})
            if len(self._channels) != previous_channels:
                records.append({"channels": self._channels})
            records.append({"frames": rows,
                            **({"timing": timings} if any(timings) else {})})
            data = "".join(json.dumps(record, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n"
                           for record in records).encode("utf-8")
            write_block(self._file, data)
            self._history.append(rows, self._channels)
            self.committed_bytes = self._file.tell()
            self.sample_count += len(rows)
        except Exception as error:
            self.failure = error
            raise

    def snapshot(self) -> tuple[Path, int, int]:
        if self.path is None or self.sample_count == 0:
            raise ValueError("There are no samples to export.")
        if self._file is not None:
            self._file.flush()
            os.fsync(self._file.fileno())
        return self.path, self.committed_bytes, self.sample_count

    def rotate(self) -> None:
        self.close()
        self._closed = False
        self.path = None
        self._history = None
        self._ids.clear()
        self._channels.clear()
        self.sample_count = self.committed_bytes = 0
        self.failure = None

    def close(self) -> None:
        self._closed = True
        if self._history is not None:
            self._history.close()
        stream, self._file = self._file, None
        if stream is not None:
            try:
                stream.flush()
                os.fsync(stream.fileno())
            finally:
                stream.close()


def _records(path: Path, byte_length: int):
    with path.open("rb") as source:
        while source.tell() < byte_length:
            line = source.readline(byte_length - source.tell())
            if not line:
                raise OSError("Raw recording ended before its committed boundary.")
            yield json.loads(line)


def export_recording_csv(source: Path, destination: Path, byte_length: int | None = None) -> int:
    """Export a stable prefix in bounded memory, also usable after app restart."""
    if source.resolve() == destination.resolve():
        raise ValueError("CSV destination cannot overwrite the raw recording.")
    boundary = source.stat().st_size if byte_length is None else byte_length
    channels: list[dict[str, str]] = []
    has_timing = False
    for record in _records(source, boundary):
        if "channels" in record:
            channels = record["channels"]
        has_timing |= "timing" in record
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    count = 0
    try:
        with tempfile.NamedTemporaryFile(mode="w", newline="", encoding="utf-8-sig",
                                         dir=destination.parent, suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            writer = csv.writer(output)
            timing_keys = ["quality", "batchSequence", "index", "repeat", "start", "end"]
            writer.writerow(["elapsed_seconds", *[channel["name"] for channel in channels],
                             *(["timing_" + key for key in timing_keys] if has_timing else [])])
            for record in _records(source, boundary):
                for frame_index, frame in enumerate(record.get("frames", [])):
                    values: list[object] = [""] * len(channels)
                    for index in range(1, len(frame), 2):
                        value = frame[index + 1]
                        values[frame[index]] = int(value) if isinstance(value, bool) else value
                    timing = (record.get("timing", [])[frame_index] or {}) if "timing" in record else {}
                    writer.writerow([f"{frame[0]:.9f}", *values,
                                     *([timing.get(key, "") for key in timing_keys] if has_timing else [])])
                    count += 1
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(destination)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    return count


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Export a saved Take A Look raw recording to CSV.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    print(f"Exported {export_recording_csv(arguments.source, arguments.destination)} raw frames.")
