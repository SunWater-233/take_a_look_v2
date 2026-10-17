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
        self.raw = path.with_suffix(".samples").open("wb")
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
            finite = [point for point in group if math.isfinite(point[2])]
            summary = _Summary()
            summary.start = min(point[1] for point in group)
            summary.end = max(point[1] for point in group)
            summary.first, summary.last = group[0], group[-1]
            summary.low = min(finite, key=lambda point: point[2]) if finite else group[0]
            summary.high = max(finite, key=lambda point: point[2]) if finite else group[0]
            summary.gap = next((point for point in group if not math.isfinite(point[2])), EMPTY)
            output.setdefault(1, bytearray()).extend(summary.encode())
            push(2, summary.fields())
        self.tail = self.tail[complete:]
        self.count += len(indexed)
        for level, data in output.items():
            if level not in self.levels:
                self.levels[level] = self.path.with_suffix(f".l{level}").open("wb")
            self.levels[level].write(data)
            self.levels[level].flush()
        self.raw.write(raw)
        self.raw.flush()

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
            for index in range(1, len(row), 2):
                value = row[index + 1]
                # Raw journals may contain nonnumeric values; those are gaps.
                try:
                    numeric = float(value)
                except (TypeError, ValueError):
                    numeric = math.nan
                grouped.setdefault(row[index], []).append((float(row[0]), numeric))
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
