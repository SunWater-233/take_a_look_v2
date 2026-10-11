import csv
from pathlib import Path

import pytest

from take_a_look_backend.services.recording import RawRecording, export_recording_csv


def test_recording_exceeds_previous_limit_and_reopens(tmp_path):
    recording = RawRecording(tmp_path / "raw")
    total = 600_005
    for start in range(0, total, 4096):
        recording.append(((index / 1000, {"a": index}) for index in range(start, min(start + 4096, total))),
                         {"a": "counter"})
    source, boundary, count = recording.snapshot()
    assert count == total
    recording.close()
    destination = tmp_path / "full.csv"
    assert export_recording_csv(source, destination, boundary) == total
    with destination.open(encoding="utf-8-sig", newline="") as stream:
        rows = csv.reader(stream)
        assert next(rows) == ["elapsed_seconds", "counter"]
        assert next(rows) == ["0.000000000", "0"]
        remaining = 0
        for row in rows:
            remaining += 1
        assert remaining == total - 1
        assert row == ["600.004000000", "600004"]


def test_snapshot_schema_sparse_duplicate_times_and_rotation(tmp_path):
    recording = RawRecording(tmp_path / "raw")
    recording.append([(1, {"a": 1}), (1, {"a": 2})], {"a": 'a,"标量"'})
    source, boundary, count = recording.snapshot()
    recording.append([(2, {"b": 3})], {"b": "b"})
    recording.rotate()
    recording.append([(0, {"c": 4})], {"c": "c"})
    assert recording.path != source
    assert source.exists()
    destination = tmp_path / "snapshot.csv"
    assert export_recording_csv(source, destination, boundary) == count == 2
    assert export_recording_csv(source, tmp_path / "all.csv") == 3
    with (tmp_path / "all.csv").open(encoding="utf-8-sig", newline="") as stream:
        assert list(csv.reader(stream)) == [
            ["elapsed_seconds", 'a,"标量"', "b"],
            ["1.000000000", "1", ""],
            ["1.000000000", "2", ""],
            ["2.000000000", "", "3"],
        ]
    recording.close()


def test_failure_is_latched_and_export_cannot_overwrite_raw(tmp_path):
    blocked = tmp_path / "blocked"
    blocked.write_text("file")
    recording = RawRecording(blocked)
    with pytest.raises(OSError):
        recording.append([(0, {"a": 1})], {"a": "a"})
    assert recording.failure is not None
    assert recording.sample_count == 0
    with pytest.raises(RuntimeError):
        recording.append([(1, {"a": 2})], {"a": "a"})
    recording.close()
    recording = RawRecording(tmp_path / "valid")
    recording.append([(0, {"a": 1})], {"a": "a"})
    source, boundary, _ = recording.snapshot()
    with pytest.raises(ValueError):
        export_recording_csv(source, Path(source), boundary)
    recording.close()
