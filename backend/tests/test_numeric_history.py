import io
import pytest

from take_a_look_backend.services.numeric_history import NumericHistory, NODE, POINT, write_block
from take_a_look_backend.services.recording import RawRecording, export_recording_csv


def test_live_commits_publish_exact_sparse_points_and_summary_ties(tmp_path):
    history = NumericHistory(tmp_path)
    channels = [{"key": "a", "name": "Alpha"}, {"key": "b", "name": "Beta"}]
    expected = [[], []]
    try:
        for start, stop in ((0, 33), (33, 79), (79, 137)):
            rows = []
            for i in range(start, stop):
                value = i % 7
                row = [i / 1000, 0, value]
                expected[0].append((i / 1000, value))
                if i % 3 == 0:
                    row.extend((1, -i))
                    expected[1].append((i / 1000, -i))
                rows.append(row)
            history.append(rows, channels)
            # Read before close, from independent handles as Dart does.
            for channel in (0, 1):
                assert list(POINT.iter_unpack((tmp_path / f"{channel}.samples").read_bytes())) == expected[channel]
            for group in range(len(expected[0]) // 64):
                points = expected[0][group * 64:(group + 1) * 64]
                fields = NODE.unpack_from((tmp_path / '0.l1').read_bytes(), group * NODE.size)
                low = min(range(64), key=lambda i: points[i][1])
                high = max(range(64), key=lambda i: points[i][1])
                assert fields[:2] == (points[0][0], points[-1][0])
                assert fields[5:8] == (group * 64 + low, *points[low])
                assert fields[8:11] == (group * 64 + high, *points[high])
    finally:
        history.close()


def test_complete_blocks_handle_short_writes_and_reject_stalls():
    class ShortWriter(io.BytesIO):
        def write(self, data):
            return super().write(data[:3])
    output = ShortWriter()
    write_block(output, b"0123456789")
    assert output.getvalue() == b"0123456789"
    for result in (0, None):
        class Stalled:
            def write(self, data):
                return result
        with pytest.raises(OSError):
            write_block(Stalled(), b"data")


def test_failed_index_commit_does_not_advance_export_boundary(tmp_path, monkeypatch):
    recording = RawRecording(tmp_path / 'recording')
    try:
        recording.append([(0, {"a": 1})], {"a": "A"})
        source, boundary, count = recording.snapshot()
        def fail(*args):
            raise OSError("disk full")
        monkeypatch.setattr(recording._history, 'append', fail)
        with pytest.raises(OSError):
            recording.append([(1, {"a": 2})], {"a": "A"})
        assert recording.sample_count == count == 1
        assert recording.committed_bytes == boundary
        assert export_recording_csv(source, tmp_path / 'saved.csv', boundary) == 1
        assert recording.failure is not None
    finally:
        recording.close()
