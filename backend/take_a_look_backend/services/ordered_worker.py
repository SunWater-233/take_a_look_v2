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
        return self._submit(action, None, weight=weight, block=block)

    def submit_batch(self, action, payload, *, weight: int = 0,
                     block: bool = True) -> Future | None:
        """Merge adjacent accepted jobs with the same consumer; drains are barriers."""
        return self._submit(action, (payload,), weight=weight, block=block)

    def _submit(self, action, batch, *, weight, block):
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
            self._jobs.append((action, future, weight, batch))
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
                action, future, weight, batch = self._jobs.popleft()
                futures = [future]
                if batch is not None:
                    batch = list(batch)
                    while self._jobs and len(futures) < 32 and weight < 1024 * 1024:
                        following, pending, size, payload = self._jobs[0]
                        if following != action or payload is None or weight + size > 1024 * 1024:
                            break
                        self._jobs.popleft()
                        batch.extend(payload)
                        futures.append(pending)
                        weight += size
            try:
                result = action() if batch is None else action(batch)
                for future in futures:
                    future.set_result(result)
            except BaseException as error:
                for future in futures:
                    future.set_exception(error)
            finally:
                with self._condition:
                    self._weight -= weight
                    self._count -= len(futures)
                    self._condition.notify_all()
