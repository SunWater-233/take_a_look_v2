import threading

from take_a_look_backend.models import SymbolInfo, WatchedVariable, SampleFrame
from take_a_look_backend.protocol import EventName
from take_a_look_backend.services.recording import RawRecording
from take_a_look_backend.services.sample_pipeline import SamplePipeline


def test_admission_retains_pending_policy_and_recording_precedes_delivery(tmp_path, monkeypatch):
    recording = RawRecording(tmp_path)
    events, failures = [], []
    def emit(name, payload):
        if name is EventName.SAMPLES:
            assert recording.sample_count >= sum(len(p['frames']) for _, p in events) + len(payload['frames'])
            events.append((name, payload))
    pipeline = SamplePipeline(recording, emit, failures.append, threading.Event(), max_jobs=1)
    entered, release = threading.Event(), threading.Event()
    clock = [1_000_000_000]
    monkeypatch.setattr('take_a_look_backend.services.sample_pipeline.time.time_ns', lambda: clock[0])
    def block():
        entered.set()
        assert release.wait(3)
    try:
        pipeline.worker.submit(block)
        assert entered.wait(1)
        symbol = SymbolInfo('a', 0x20000000, 4, 'uint32_t', '.data', 'fixture.c')
        watches = {symbol.key: WatchedVariable(symbol, '#00ff00')}
        values = {symbol.key: 41}
        timing = {'quality': 'transaction_window', 'batchSequence': 1, 'index': 0,
                  'repeat': 2, 'start': 1.0, 'end': 1.1}
        pipeline.queue([SampleFrame(1.0, values, timing)], watches)
        values[symbol.key] = 99
        assert pipeline.flush(wait=False) is False
        assert pipeline.backpressure and pipeline.pending_count == 1
        # Replacing the watch policy does not retroactively alter queued capture.
        watches = {symbol.key: WatchedVariable(symbol, '#00ff00', read_mode='manual')}
        clock[0] = 2_000_000_000
        pipeline.queue([(2.0, {symbol.key: 100})], watches)
        pipeline.queue([], watches)
        assert pipeline.pending_count == 1
        release.set()
        pipeline.drain()
        assert pipeline.flush() is True
        assert not pipeline.backpressure and pipeline.pending_count == 0
        assert events[0][1]['frames'] == [{'elapsed': 1.0, 'values': {symbol.key: 41}, 'timing': timing}]
        assert events[0][1]['updatedAtMs'] == 1000
        assert pipeline.take_committed_count() == 1
        assert pipeline.take_committed_count() == 0
        assert failures == []
        pipeline.rotate()
        assert recording.sample_count == 0 and recording.path is None
    finally:
        release.set()
        pipeline.close()
        recording.close()


def test_write_failure_reports_once_and_never_publishes_samples(tmp_path, monkeypatch):
    recording = RawRecording(tmp_path)
    events, failures = [], []
    pipeline = SamplePipeline(recording, lambda *event: events.append(event), failures.append, threading.Event())
    try:
        symbol = SymbolInfo('a', 0x20000000, 4, 'uint32_t', '.data', 'fixture.c')
        watches = {symbol.key: WatchedVariable(symbol, '#00ff00')}
        def fail(*args):
            raise OSError('disk full')
        monkeypatch.setattr(recording, 'append', fail)
        pipeline.queue([(0, {symbol.key: 1})], watches)
        pipeline.flush()
        pipeline.queue([(1, {symbol.key: 2})], watches)
        assert pipeline.flush() is False
        assert len(failures) == 1 and recording.failure is failures[0]
        assert pipeline.take_committed_count() == 0 and events == []
    finally:
        pipeline.close()
        recording.close()
