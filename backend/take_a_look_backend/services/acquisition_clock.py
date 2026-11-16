"""Active acquisition time, independent of polling, rendering and wall time."""
from __future__ import annotations

from collections.abc import Callable
import threading
import time


class AcquisitionClock:
    def __init__(self, now: Callable[[], float] = time.perf_counter) -> None:
        self._now = now
        # Recording failures pause from the writer thread without taking the
        # hardware lock (the sampler may be waiting for that writer).
        self._lock = threading.RLock()
        self._accumulated = 0.0
        self._started_at: float | None = None

    @property
    def running(self) -> bool:
        with self._lock:
            return self._started_at is not None

    def elapsed(self) -> float:
        with self._lock:
            return self._accumulated + (max(0.0, self._now() - self._started_at)
                                        if self._started_at is not None else 0.0)

    def snapshot(self) -> tuple[float, bool]:
        with self._lock:
            return self.elapsed(), self._started_at is not None

    def set_running(self, running: bool) -> bool:
        with self._lock:
            if running == (self._started_at is not None):
                return False
            if running:
                self._started_at = self._now()
            else:
                self._accumulated = self.elapsed()
                self._started_at = None
            return True

    def reset(self, *, running: bool = False) -> None:
        with self._lock:
            self._accumulated = 0.0
            self._started_at = self._now() if running else None

