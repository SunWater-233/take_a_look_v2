"""Owned acquisition batches, bounded admission and ordered recording commits.

The caller serializes queue/flush with its target state. The worker never takes
that lock; it reports failure through a callback and owns committed counters.
"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import chain
import threading
import time

from take_a_look_backend.models import SampleFrame, json_value
from take_a_look_backend.protocol import EventName
from .ordered_worker import OrderedWorker


@dataclass(frozen=True)
class SampleBatch:
    frames: tuple[SampleFrame, ...]
    labels: dict[str, str]
    updated_at_ms: int | None


class SamplePipeline:
    def __init__(self, recording, emit, failed, wake, *, max_jobs=256, max_weight=32 * 1024 * 1024):
        self.recording = recording
        self._emit, self._failed, self._wake = emit, failed, wake
        self.worker = OrderedWorker("tal-recording", max_jobs=max_jobs, max_weight=max_weight)
        self._pending = []
        self._labels = {}
        self._updated_at_ms = None
        self._weight = 0
        self.backpressure = False
        self._error_reported = False
        self._count_lock = threading.Lock()
        self._committed_count = 0
        self._policy_source = None
        self._policy_count = -1
        self._capture_labels = {}

    @property
    def pending_count(self):
        return len(self._pending)

    def queue(self, frames, watches):
        if self._policy_source is not watches or self._policy_count != len(watches):
            self._policy_source = watches
            self._policy_count = len(watches)
            self._capture_labels = {key: watch.symbol.name for key, watch in watches.items()
                                    if watch.captures}
        labels = self._capture_labels
        if not self._pending:
            self._labels = labels
        elif self._labels is not labels:
            self._labels = {**self._labels, **labels}
        received = False
        latest_elapsed = None
        for acquired in frames:
            elapsed, values = acquired
            normalized = {key: json_value(value) for key, value in values.items() if key in labels}
            if not normalized:
                continue
            timing = getattr(acquired, "timing", None)
            self._pending.append(SampleFrame(elapsed, normalized, timing))
            self._weight += 128 + len(normalized) * 96 + (256 if timing is not None else 0)
            received = True
            latest_elapsed = elapsed if latest_elapsed is None else max(latest_elapsed, elapsed)
        if received:
            self._updated_at_ms = time.time_ns() // 1_000_000
        return latest_elapsed

    def flush(self, *, wait=True, block=None):
        if self.recording.failure is not None:
            return False
        if not self._pending:
            if wait:
                self.drain()
            return True
        batch = SampleBatch(tuple(self._pending), self._labels, self._updated_at_ms)
        future = self.worker.submit_batch(self._commit, batch, weight=self._weight,
                                          block=wait if block is None else block)
        if future is None:
            self.backpressure = True
            return False
        self.backpressure = False
        self._pending, self._labels = [], {}
        self._updated_at_ms, self._weight = None, 0
        if wait:
            future.result()
        return True

    def _commit(self, batches):
        previous_path = self.recording.path
        try:
            labels = {}
            for batch in batches:
                labels.update(batch.labels)
            self.recording.append(chain.from_iterable(batch.frames for batch in batches), labels)
        except Exception as error:
            self.recording.failure = error
            if not self._error_reported:
                self._error_reported = True
                self._failed(error)
            return
        with self._count_lock:
            self._committed_count += sum(len(batch.frames) for batch in batches)
        if self.recording.path != previous_path:
            self._emit(EventName.LOG, {"level": "info", "message": f"原始采样持续保存：{self.recording.path}"})
            self._emit(EventName.STATE, {"rawRecording": self.recording.status()})
        for batch in batches:
            self._emit(EventName.SAMPLES, {"captureOnly": True, "updatedAtMs": batch.updated_at_ms,
                                         "frames": [frame.to_json() for frame in batch.frames]})
        self._wake.set()

    def take_committed_count(self):
        with self._count_lock:
            count, self._committed_count = self._committed_count, 0
        return count

    def drain(self):
        self.worker.drain()

    def snapshot(self):
        return self.worker.submit(self.recording.snapshot)

    def rotate(self):
        self.drain()
        self.recording.rotate()
        self._pending, self._labels = [], {}
        self._updated_at_ms, self._weight = None, 0
        self.backpressure = self._error_reported = False
        self.take_committed_count()

    def close(self):
        self.worker.close()
