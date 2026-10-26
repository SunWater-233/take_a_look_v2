"""Disk range index shared with the Dart history reader (format version 1).

Each channel has float64 (time, value) records and a 64-way summary tree.
Nodes store time bounds and original first/min/max/last/nonfinite samples.
Only incomplete nodes stay resident. Completed nodes precede the raw commit,
so readers can safely query any fixed prefix while acquisition continues.
"""
from __future__ import annotations

import json
import math
import os
import struct
from pathlib import Path

GROUP = 64
POINT = struct.Struct("<dd")
NODE = struct.Struct("<17d")
EMPTY = (-1.0, 0.0, math.nan)


def write_block(stream, data):
    """Publish one complete block without a second userspace buffering layer.

    Readers rely on actual file lengths. Handle short writes before exposing a
    committed journal boundary; no preallocation or delayed visibility is used.
    """
    remaining = memoryview(data)
    while remaining:
        written = stream.write(remaining)
        if written is None or written <= 0:
            raise OSError("History write did not make progress.")
        remaining = remaining[written:]


class _Summary:
    def __init__(self):
        self.count = 0
        self.start = math.inf
        self.end = -math.inf
        self.first = self.low = self.high = self.last = self.gap = EMPTY

    def add(self, start, end, first, low, high, last, gap):
        if not self.count:
            self.first, self.low, self.high = first, low, high
        if math.isfinite(low[2]) and (not math.isfinite(self.low[2]) or low[2] < self.low[2]):
            self.low = low
        if math.isfinite(high[2]) and (not math.isfinite(self.high[2]) or high[2] > self.high[2]):
            self.high = high
        if self.gap[0] < 0 and gap[0] >= 0:
            self.gap = gap
        self.last = last
        self.start, self.end = min(self.start, start), max(self.end, end)
        self.count += 1

    def fields(self):
        return self.start, self.end, self.first, self.low, self.high, self.last, self.gap

    def encode(self):
        return NODE.pack(self.start, self.end, *self.first, *self.low, *self.high, *self.last, *self.gap)


class _Series:
    def __init__(self, path: Path):
        self.path = path
        self.count = 0
        self.raw = path.with_suffix(".samples").open("wb", buffering=0)
        self.levels = {}
        self.pending = {}
        self.tail = []

    def append(self, points):
        indexed = [(self.count + i, time, value) for i, (time, value) in
                   enumerate((time, value) for time, value in points if math.isfinite(time))]
        raw = b"".join(POINT.pack(time, value) for _, time, value in indexed)
        output: dict[int, bytearray] = {}

        def push(level, fields):
            if level not in self.pending:
                self.pending[level] = _Summary()
            summary = self.pending[level]
            summary.add(*fields)
            if summary.count == GROUP:
                output.setdefault(level, bytearray()).extend(summary.encode())
                self.pending[level] = _Summary()
                push(level + 1, summary.fields())

        # Summarize raw points a block at a time. Calling the recursive merger
        # for every channel value needlessly competes with sampling for the GIL.
        self.tail.extend(indexed)
        complete = len(self.tail) // GROUP * GROUP
        for start in range(0, complete, GROUP):
            group = self.tail[start:start + GROUP]
            summary = _Summary()
            summary.first, summary.last = group[0], group[-1]
            lower = upper = None
            minimum_time = maximum_time = group[0][1]
            gap = EMPTY
            for point in group:
                stamp, value = point[1], point[2]
                if stamp < minimum_time:
                    minimum_time = stamp
                if stamp > maximum_time:
                    maximum_time = stamp
                if math.isfinite(value):
                    if lower is None or value < lower[2]:
                        lower = point
                    if upper is None or value > upper[2]:
                        upper = point
                elif gap[0] < 0:
                    gap = point
            summary.start, summary.end = minimum_time, maximum_time
            summary.low = lower if lower is not None else group[0]
            summary.high = upper if upper is not None else group[0]
            summary.gap = gap
            output.setdefault(1, bytearray()).extend(summary.encode())
            push(2, summary.fields())
        self.tail = self.tail[complete:]
        self.count += len(indexed)
        for level, data in output.items():
            if level not in self.levels:
                self.levels[level] = self.path.with_suffix(f".l{level}").open("wb", buffering=0)
            write_block(self.levels[level], data)
        write_block(self.raw, raw)

    def close(self):
        for stream in [self.raw, *self.levels.values()]:
            stream.close()


class NumericHistory:
    def __init__(self, directory: Path):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.series: dict[int, _Series] = {}
        self.channel_count = 0

    def append(self, rows, channels):
        grouped: dict[int, list[tuple[float, float]]] = {}
        for row in rows:
            elapsed = float(row[0])
            for index in range(1, len(row), 2):
                value = row[index + 1]
                # Raw journals may contain nonnumeric values; those are gaps.
                try:
                    numeric = float(value)
                except (TypeError, ValueError):
                    numeric = math.nan
                channel = row[index]
                points = grouped.get(channel)
                if points is None:
                    points = grouped[channel] = []
                points.append((elapsed, numeric))
        for channel, points in grouped.items():
            if channel not in self.series:
                self.series[channel] = _Series(self.directory / str(channel))
            self.series[channel].append(points)
        if self.channel_count != len(channels):
            temporary = self.directory / "manifest.tmp"
            temporary.write_text(json.dumps({"version": 1, "channels": channels}, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, self.directory / "manifest.json")
            self.channel_count = len(channels)

    def close(self):
        for series in self.series.values():
            series.close()
