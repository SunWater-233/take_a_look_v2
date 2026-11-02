"""Summarize window_resize_benchmark.dart JSON without conflating CPU and GPU."""

import argparse
from collections import Counter
import csv
import json
from pathlib import Path
from statistics import median


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "p50": values[int((len(values) - 1) * 0.50)],
        "p95": values[int((len(values) - 1) * 0.95)],
        "max": values[-1],
    }


def summarize(path):
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    frames, layouts = data["frames"], data["layouts"]
    # Scheduler frame timestamps are adjusted relative to the engine's first
    # vsync, whereas FrameTiming uses the monotonic system epoch. Recover that
    # constant offset by matching consecutive frames. Timing batches can arrive
    # after a phase boundary, so phaseAtDelivery is deliberately not used.
    offsets = Counter()
    for shift in range(-3, 4):
        for index, frame in enumerate(frames):
            other = index + shift
            if 0 <= other < len(layouts):
                offsets[frame["vsyncUs"] - layouts[other]["frameTimestampUs"]] += 1
    offset, _ = offsets.most_common(1)[0]
    by_timestamp = {layout["frameTimestampUs"]: layout for layout in layouts}
    matched = []
    clock_offsets = []
    for frame in frames:
        stamp = frame["vsyncUs"] - offset
        # Subtracting two nanosecond timestamps before converting to whole
        # microseconds can differ by one from subtracting their rounded forms.
        layout = next(
            (by_timestamp[t] for t in (stamp, stamp - 1, stamp + 1)
             if t in by_timestamp),
            None,
        )
        if layout:
            matched.append(dict(frame, phase=layout["phase"]))
            # The layout observer runs near build completion. This estimate is
            # only for phase boundaries, never for measuring an operation.
            clock_offsets.append(
                frame["buildStartUs"] + frame["buildMs"] * 1000 - layout["us"]
            )
    clock_offset = median(clock_offsets)

    trace_path = path.with_name("native-trace.csv")
    native_trace = []
    if trace_path.exists():
        with trace_path.open(encoding="utf-8-sig", newline="") as source:
            native_trace = [
                {"event": row["event"],
                 "start": float(row["startQpcUs"]),
                 "end": float(row["startQpcUs"]) + float(row["durationUs"]),
                 "ms": float(row["durationUs"]) / 1000}
                for row in csv.DictReader(source)
            ]

    def phase_stats(prefixes):
        def selected(phase):
            return any(phase.startswith(prefix) for prefix in prefixes)

        chosen_frames = [f for f in matched if selected(f["phase"])]
        chosen_layouts = [x for x in layouts if selected(x["phase"])]
        chosen_requests = [x for x in data["requests"] if selected(x["phase"])]
        result = {
            field: distribution([f[field] for f in chosen_frames])
            for field in ["buildMs", "rasterMs", "totalMs", "vsyncOverheadMs"]
        }
        result["panelErrorLogicalPx"] = distribution(
            [x["maxPanelErrorPx"] for x in chosen_layouts]
        )
        result["nativeSetSizeCallMs"] = distribution(
            [x["callMs"] for x in chosen_requests]
        )
        refresh_budget = 1000 / data["displayRefreshRate"]
        for field in ["buildMs", "rasterMs"]:
            values = [f[field] for f in chosen_frames]
            result[field]["over16_67ms"] = sum(v > 1000 / 60 for v in values)
            result[field]["overDisplayBudget"] = sum(v > refresh_budget for v in values)
        result["metricsCount"] = sum(selected(m["phase"]) for m in data["metrics"])
        result["layoutFrames"] = len(chosen_layouts)
        # Include the entire request interval, including stalls in which no
        # frame runs. Selecting only frame overlaps would omit those stalls.
        # A 2ms phase-boundary margin covers the post-frame clock estimate.
        spans = [
            (r["us"] + clock_offset - 2000,
             r["us"] + clock_offset + r["callMs"] * 1000 + 2000)
            for r in chosen_requests
        ] or [
            (f["vsyncUs"] - 100000, f["vsyncUs"] + f["totalMs"] * 1000)
            for f in chosen_frames
        ]
        trace = [
            event for event in native_trace
            if any(event["start"] < end and event["end"] > start
                   for start, end in spans)
        ]
        if native_trace:
            result["nativeWmSizeMs"] = distribution(
                [e["ms"] for e in trace if e["event"] == "WM_SIZE"]
            )
            result["dwmFlushMs"] = distribution(
                [e["ms"] for e in trace if e["event"] == "DwmFlush"]
            )
        return result

    return {
        "path": str(path),
        "release": data["release"],
        "mode": data["mode"],
        "scene": data.get("scene", "production"),
        "titlebar": data.get("titlebar", "hidden"),
        "separateUiOverride": data.get("separateUiOverride"),
        "dwmTraceInstrumented": path.with_name("native-trace-status.txt").exists()
        and "instrumented: 1" in path.with_name("native-trace-status.txt").read_text(),
        "displayRefreshRate": data["displayRefreshRate"],
        "devicePixelRatio": data["devicePixelRatio"],
        "timingFrames": len(frames),
        "matchedTimingFrames": len(matched),
        "script": phase_stats(["horizontal-", "vertical-", "diagonal-"]),
        "settle": phase_stats(["settle-"]),
        "native": phase_stats(["native-drag"]),
        "errors": data["errors"],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, nargs="+")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    summaries = [summarize(path) for path in args.results]
    output = json.dumps(summaries, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)
