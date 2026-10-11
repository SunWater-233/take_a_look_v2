"""Summarize paired release audits, retaining raw data and validation evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def summarize(values):
    return {"runs": values, "minimum": min(values), "maximum": max(values),
            "mean": statistics.mean(values)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("docs/performance/2026-10-11/results.json"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    work = root / "build/performance_review"
    benchmark = root / "build/data_benchmark"
    raw = {}
    environments = {}
    for side in ("before", "after"):
        directory = benchmark / f"audit-{side}"
        raw[side] = {suite: [read(directory / f"{suite}-run-{run}.json") for run in (1, 2)]
                     for suite in ("audit", "live")}
        environments[side] = {suite: read(directory / f"environment-{suite}.json")
                              for suite in ("audit", "live")}
        for suite in raw[side].values():
            assert all(run["status"] == "passed" for run in suite)
    names = [item["name"] for item in raw["before"]["audit"][0]["results"]]
    assert all([item["name"] for item in run["results"]] == names
               for side in raw.values() for run in side["audit"])
    comparisons = []
    for name in names:
        rows = {side: [next(item for item in run["results"] if item["name"] == name)
                       for run in data["audit"]] for side, data in raw.items()}
        first = rows["before"][0]
        metric = next(key for key in ("medianMs", "elapsedMs", "bytes") if key in first)
        stats = {side: summarize([item[metric] for item in values]) for side, values in rows.items()}
        comparisons.append({"name": name, "metric": metric, **stats,
            "beforeDividedByAfter": stats["before"]["mean"] / stats["after"]["mean"]})
    live = {}
    for metric in ("buildMedianMs", "buildP95Ms", "rasterMedianMs", "rasterP95Ms", "rssBytes"):
        live[metric] = {side: summarize([run["results"][0][metric] for run in data["live"]])
                        for side, data in raw.items()}
    frontend_log = (work / "flutter-after.log").read_text(encoding="utf-8-sig")
    backend_log = (work / "python-after.log").read_text(encoding="utf-8-sig")
    analyze_log = (work / "analyze-after.log").read_text(encoding="utf-8-sig")
    frontend = re.search(r"\+(\d+)(?: ~(\d+))?: All tests passed", frontend_log)
    assert frontend and "No issues found!" in analyze_log
    assert "failed" not in backend_log.lower()
    backend = re.search(r"(\d+) passed", backend_log)
    assert backend
    smoke = read(root / "build/ui_test/smoke/smoke-result.json")
    assert smoke["smokePassed"] is True
    packaged = read(work / "backend-self-check.json")
    assert packaged["ok"] is True
    release = root / "build/windows/x64/runner/Release/take_a_look_v2.exe"
    assert release.is_file() and "Built" in (work / "windows-release.log").read_text(encoding="utf-8-sig")
    elf = read(work / "elf-comparison.json")
    assert elf["passed"] is True
    elf["reproductionSource"] = "tool/benchmarks/symbol_fixture.c"
    elf["compileFlags"] = ("clang --target=arm-none-eabi -mcpu=cortex-m7 -mthumb -gdwarf-4 -O0 -c; "
                           "ld.lld -flavor gnu -m armelf -e main -Ttext=0x08000000 -Tdata=0x20000000")
    release_backend = read(work / "release-backend-self-check.json")
    assert release_backend["ok"] is True
    backend_runs = {side: read(work / f"backend-{side}.json") for side in ("before", "after")}
    paths = [*(root / "lib").rglob("*.dart"),
             *(root / "backend/take_a_look_backend").rglob("*.py")]
    source_hashes = {str(path.relative_to(root)).replace("\\", "/"):
                     hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    result = {
        "baselineCommit": "9541b207f6626fb37adc413702566dd65aed9907",
        "afterBaseCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "scope": [
            "Windows release AOT. Two separate processes per side, same fixtures and Flutter SDK.",
            "Both benchmark processes restricted to mask 255 (logical CPUs 0-7, performance-class cores on this host). Application and OS affinity settings unchanged.",
            "CPU frequency and external system load were not locked. Ranges are two per-process results, not confidence intervals.",
            "Repeated synchronous operations use the per-process median of calibrated blocks; pause is a single operation in each process.",
            "Moving-window painting appends 64 frames/channel each operation. Unchanged-window painting additionally benefits from caching.",
            "Painting measures CPU picture recording, not rasterization or displayed FPS. Live engine timings come from a hidden generated runner.",
            "Wire comparisons use each version's production representation with identical values: legacy nested lists versus Float64 buffers and state patches.",
            "JSON-fragment timing is cumulative CPU processing for continuously fed fragments, not a measured contiguous UI freeze.",
            "Backend tests use a fake probe plus real disk recording. They do not establish USB/SWD/network throughput or a guaranteed 10 kHz memory polling rate.",
            "Raw samples, duplicate timestamps, extrema, frozen histories, readback and export boundaries retain their existing semantics.",
        ],
        "environment": environments,
        "comparison": comparisons,
        "liveComparison": live,
        "backend": backend_runs,
        "validation": {
            "analyze": "passed",
            "flutterPassed": int(frontend.group(1)),
            "flutterSkipped": int(frontend.group(2) or 0),
            "pythonPassed": int(backend.group(1)),
            "pythonSkipped": int(re.search(r"(\d+) skipped", backend_log).group(1)),
            "pythonSubtests": 4,
            "realArmElfOldNewResults": elf,
            "packagedBackendSelfCheck": packaged,
            "nativeSmoke": smoke,
            "windowsRelease": {"passed": True, "executable": str(release),
                               "backendSelfCheck": release_backend},
            "hardwareValidation": "not performed",
        },
        "afterSourceSha256": source_hashes,
        "raw": raw,
    }
    destination = root / args.output
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    for item in comparisons:
        if item["name"].startswith("audit_"):
            print(f'{item["name"]}: {item["before"]["minimum"]:.4f}-{item["before"]["maximum"]:.4f}'
                  f' -> {item["after"]["minimum"]:.4f}-{item["after"]["maximum"]:.4f}'
                  f' ({item["beforeDividedByAfter"]:.2f}x)')
    print("Saved", destination)


if __name__ == "__main__":
    main()
