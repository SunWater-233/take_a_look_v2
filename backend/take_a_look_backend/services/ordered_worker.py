"""Bounded ordered work, used for recording and pipe output."""
from __future__ import annotations

from collections import deque
from concurrent.futures import Future
from threading import Condition, Thread, current_thread
from typing import Callable, TypeVar

T = TypeVar("T")


class OrderedWorker:
    def __init__(self, name: str, *, max_weight: int = 32 * 1024 * 1024,
                 max_jobs: int = 256) -> None:
        self._condition = Condition()
        self._jobs = deque()
        self._weight = 0
        self._count = 0
        self._max_weight = max_weight
        self._max_jobs = max_jobs
        self._closing = False
        self._thread = Thread(target=self._run, name=name, daemon=True)
        self._thread.start()

    def submit(self, action: Callable[[], T], *, weight: int = 0,
               block: bool = True) -> Future[T] | None:
        future: Future[T] = Future()
        with self._condition:
            # A single oversized item can run alone; never truncate a message.
            while (self._count >= self._max_jobs or
                   (self._count > 0 and self._weight + weight > self._max_weight)):
                if self._closing:
                    raise RuntimeError("Worker is closed.")
                if not block:
                    return None
                self._condition.wait()
            if self._closing:
                raise RuntimeError("Worker is closed.")
            self._jobs.append((action, future, weight))
            self._weight += weight
            self._count += 1
            self._condition.notify_all()
        return future

    def drain(self) -> None:
        self.submit(lambda: None).result()

    def close(self) -> None:
        with self._condition:
            self._closing = True
            self._condition.notify_all()
        if current_thread() is not self._thread:
            self._thread.join()

    def _run(self) -> None:
        while True:
            with self._condition:
                while not self._jobs and not self._closing:
                    self._condition.wait()
                if not self._jobs:
                    return
                action, future, weight = self._jobs.popleft()
            try:
                future.set_result(action())
            except BaseException as error:
                future.set_exception(error)
            finally:
                with self._condition:
                    self._weight -= weight
                    self._count -= 1
                    self._condition.notify_all()
