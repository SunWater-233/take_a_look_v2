from __future__ import annotations

import time
from typing import Any

from take_a_look_backend.models import WatchedVariable, json_value
from take_a_look_backend.backends.target_backend import backend_capabilities, backend_rtt_binding
from take_a_look_backend.protocol import EventName
from take_a_look_backend.services.sampling_clock import advance_deadline, wait_until


class SamplingServiceMixin:
    """Time-critical acquisition loop and RTT lifecycle."""

    def _sampling_loop(self) -> None:
        next_memory_at = next_rtt_at = next_monitor_at = last_emit_at = time.perf_counter()
        previous_periods = None
        monitor_revision = -1
        while not self._shutdown.is_set():
            now = time.perf_counter()
            deadlines = [now + 0.05]
            try:
                with self._lock:
                    connected = self._connection_status == "connected" and not self._firmware_busy
                    if connected and now >= self._next_debug_poll_at:
                        self._poll_debug_state_locked()
                        self._next_debug_poll_at = now + 0.05
                        connected = self._connection_status == "connected"
                    if connected:
                        deadlines.append(self._next_debug_poll_at)
                    if monitor_revision != self._monitor_schedule_revision:
                        monitor_revision = self._monitor_schedule_revision
                        next_monitor_at = now
                    active = connected and not self._sampling_paused and self._target_execution_state != "halted"
                    memory_period = 1.0 / self._sample_rate_hz
                    rtt_period = max(1.0 / self._rtt_sample_rate_hz, 0.002)
                    periods = (memory_period, rtt_period)
                    if previous_periods != periods:
                        next_memory_at = next_rtt_at = now
                        previous_periods = periods
                    elapsed = self._elapsed_locked(now)
                    rtt_enabled = self._rtt_enabled
                    rtt_protocol = self._rtt_protocol
                    if self._pipeline_backpressure:
                        self._flush_pending_samples_locked(wait=False)
                    if connected:
                        if now >= next_monitor_at:
                            next_monitor_at = self._poll_monitors_locked(now)
                        deadlines.append(next_monitor_at)
                    if connected and not self._pipeline_backpressure:
                        memory_enabled = (active and any(w.captures and not w.symbol.is_rtt for w in self._watches.values()) and
                            backend_capabilities(self._memory).memory_sampling and
                            not (rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started))
                        if memory_enabled:
                            if now >= next_memory_at:
                                values = self._read_memory_locked(rtt_enabled, rtt_protocol)
                                if values:
                                    self._queue_samples_locked([(elapsed, values)])
                                next_memory_at = advance_deadline(next_memory_at, time.perf_counter(), memory_period)
                            deadlines.append(next_memory_at)
                        # Drain push streams while capture is paused. Monitors use
                        # fresh cached values; old RTT frames must never be replayed.
                        if rtt_enabled and self._target_execution_state != "halted":
                            if now >= next_rtt_at:
                                frames = self._read_rtt_locked(elapsed, now)
                                if active:
                                    self._queue_samples_locked(frames)
                                next_rtt_at = advance_deadline(next_rtt_at, time.perf_counter(), rtt_period)
                            deadlines.append(next_rtt_at)
                    if self._pending_frames:
                        if len(self._pending_frames) >= 64 or now - last_emit_at >= 0.006:
                            if self._flush_pending_samples_locked(wait=False):
                                last_emit_at = now
                        if not self._pipeline_backpressure:
                            deadlines.append(last_emit_at + 0.006)
            except Exception as error:
                with self._lock:
                    self._handle_remote_failure_locked(error)
                self._emit(EventName.LOG, {"level": "error", "message": f"采样失败：{error}"})
                next_memory_at = time.perf_counter() + 0.25
                deadlines = [next_memory_at]
            now = time.perf_counter()
            if now - self._last_perf_at >= 1.0:
                self._publish_perf(now)
            wait_until(self._wake, min(deadlines))

    @staticmethod
    def _watch_value_json(watch: WatchedVariable) -> dict[str, object]:
        return {"key": watch.symbol.key, "value": json_value(watch.value),
                "updatedAtMs": watch.updated_at_ms}

    def _remember_values_locked(self, values: dict[str, object], *, updated_at_ms: int | None = None) -> None:
        stamp = updated_at_ms if updated_at_ms is not None else time.time_ns() // 1_000_000
        for key, value in values.items():
            watch = self._watches.get(key)
            if watch is not None and (watch.updated_at_ms is None or stamp >= watch.updated_at_ms):
                watch.value = value
                watch.updated_at_ms = stamp

    def _publish_watch_values_locked(self, values: dict[str, object], *, updated_at_ms: int | None = None) -> None:
        self._remember_values_locked(values, updated_at_ms=updated_at_ms)
        payload = [self._watch_value_json(self._watches[key]) for key in values if key in self._watches]
        if payload:
            self._emit(EventName.WATCH_VALUES, {"values": payload})

    def _poll_monitors_locked(self, now: float) -> float:
        """Latest-only polling has its own deadlines, independent of capture."""
        memory = []
        pushed: list[tuple[WatchedVariable, tuple[object, int]]] = []
        next_at = now + 2.0
        can_read_memory = (backend_capabilities(self._memory).memory_sampling
                           or self._target_execution_state == "halted")
        plus = self._rtt_enabled and self._rtt_protocol == "plus"
        for watch in self._watches.values():
            if watch.mode != "monitor":
                continue
            period = 1.0 / (watch.monitor_rate_hz or self._monitor_rate_hz)
            if watch.next_monitor_at <= now:
                watch.next_monitor_at = now + period
                if watch.symbol.is_rtt or (plus and self._target_execution_state != "halted"):
                    cached = self._latest_rtt_values.get(watch.symbol.key)
                    if cached is not None and (watch.updated_at_ms is None or cached[1] > watch.updated_at_ms):
                        pushed.append((watch, cached))
                elif can_read_memory:
                    memory.append(watch.symbol)
            next_at = min(next_at, watch.next_monitor_at)
        if memory:
            self._publish_watch_values_locked(self._memory.read_symbols(memory))
        # A fixed RTT producer retains its own rate. Throttle presentation,
        # without pretending this reduces traffic on the target's link.
        if pushed:
            for watch, (value, stamp) in pushed:
                watch.value, watch.updated_at_ms = value, stamp
            self._emit(EventName.WATCH_VALUES, {"values": [self._watch_value_json(w) for w, _ in pushed]})
        return max(now + 0.001, next_at)

    def _read_memory_locked(self, rtt_enabled: bool, rtt_protocol: str) -> dict[str, object]:
        if not backend_capabilities(self._memory).memory_sampling:
            return {}
        if rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started:
            return {}
        symbols = [watch.symbol for watch in self._watches.values()
                   if not watch.symbol.is_rtt and watch.captures]
        if not symbols:
            return {}
        values = self._memory.read_symbols(symbols)
        self._remember_values_locked(values)
        return values

    def _read_rtt_locked(self, elapsed: float, now: float) -> list[tuple[float, dict[str, object]]]:
        backend: Any = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
        binding = backend_rtt_binding(self._memory)
        target = binding.target
        if not backend.is_started:
            if now < self._next_rtt_retry_at:
                return []
            try:
                if self._rtt_protocol == "normal":
                    symbols = self._normal_rtt.start(
                        target,
                        self._rtt_control_block_address,
                        binding.probe,
                    )
                else:
                    symbols = self._plus_rtt.start(
                        target,
                        self._rtt_control_block_address,
                        binding.probe,
                        list(self._watches.values()),
                    )
                if self._rtt_protocol == "normal":
                    for symbol in symbols:
                        self._symbols[symbol.key] = symbol
                    self._emit(EventName.STATE, self.state_snapshot())
                self._emit(EventName.LOG, {"level": "info", "message": f"RTT 已启动：{backend.transport_name}。"})
                self._last_rtt_error = ""
            except Exception as error:
                if self._handle_remote_failure_locked(error):
                    return []
                text = str(error)
                self._next_rtt_retry_at = now + 1.0
                if text != self._last_rtt_error:
                    self._last_rtt_error = text
                    self._emit(EventName.LOG, {"level": "error", "message": f"RTT 启动失败：{text}"})
                return []
        try:
            frames = backend.read_frames(elapsed)
        except Exception:
            # A dropped RTT byte invalidates fixed-width sample alignment. Do
            # not keep decoding or replay stale samples after a reset/overflow.
            if self._connection_kind in {"ember", "emberGdb"}:
                self._rtt_enabled = False
                self._stop_rtt_locked()
                self._emit(EventName.STATE, {"rttEnabled": False})
            raise
        latest = {}
        for _frame_elapsed, values in frames:
            latest.update({key: value for key, value in values.items() if key in self._watches})
        stamp = time.time_ns() // 1_000_000
        self._latest_rtt_values.update({key: (value, stamp) for key, value in latest.items()})
        if not self._sampling_paused:
            self._remember_values_locked({key: value for key, value in latest.items()
                                          if self._watches[key].captures}, updated_at_ms=stamp)
        return frames

    def _queue_samples_locked(self, frames: list[tuple[float, dict[str, object]]]) -> None:
        # Capture the sampling switches/labels at acquisition, before a watch
        # can be disabled or removed while this batch waits for publication.
        for elapsed, values in frames:
            normalized = {key: json_value(value) for key, value in values.items()
                          if key in self._watches and self._watches[key].captures}
            if not normalized:
                continue
            self._pending_frames.append((elapsed, normalized))
            self._pending_updated_at_ms = time.time_ns() // 1_000_000
            recorded = {}
            for key, value in normalized.items():
                watch = self._watches.get(key)
                if watch and watch.captures:
                    recorded[key] = value
                    self._pending_recording_labels[key] = watch.symbol.name
            if recorded:
                self._pending_recording_frames.append((elapsed, recorded))

    def _flush_pending_samples_locked(self, *, wait: bool = True, block: bool | None = None) -> bool:
        if self._recording.failure is not None:
            return False
        if not self._pending_frames:
            if wait:
                self._recording_worker.drain()
            return True
        frames = self._pending_frames
        recorded = self._pending_recording_frames
        labels = self._pending_recording_labels
        updated_at_ms = self._pending_updated_at_ms
        weight = len(frames) * 128 + sum(len(values) for _, values in frames) * 96
        future = self._recording_worker.submit(
            lambda: self._commit_sample_batch(frames, recorded, labels, updated_at_ms),
            weight=weight, block=wait if block is None else block)
        if future is None:
            # Retain the acquired batch and stop further reads until admitted.
            # Hardware-side RTT overflow still follows its existing error path.
            self._pipeline_backpressure = True
            return False
        self._pipeline_backpressure = False
        self._pending_frames = []
        self._pending_recording_frames = []
        self._pending_recording_labels = {}
        self._pending_updated_at_ms = None
        if wait:
            future.result()
        return True

    def _commit_sample_batch(self, frames, recorded, labels, updated_at_ms=None) -> None:
        previous_path = self._recording.path
        try:
            self._recording.append(recorded, labels)
        except Exception as error:
            first_failure = not self._recording_error_reported
            self._recording_error_reported = True
            self._recording.failure = error
            self._sampling_paused = True
            self._wake.set()
            if first_failure:
                self._emit(EventName.ERROR, {"code": "raw_recording_failed",
                           "message": "原始记录写入失败，已暂停采样。", "details": str(error)})
                self._emit(EventName.STATE, {"samplingPaused": True,
                           "rawRecording": self._recording.status()})
            return
        with self._perf_lock:
            self._sample_count_since_perf += len(frames)
        if self._recording.path != previous_path:
            self._emit(EventName.LOG, {"level": "info", "message": f"原始采样持续保存：{self._recording.path}"})
            self._emit(EventName.STATE, {"rawRecording": self._recording.status()})
        self._emit(EventName.SAMPLES, {"captureOnly": True, "updatedAtMs": updated_at_ms, "frames": [
            {"elapsed": elapsed, "values": values} for elapsed, values in frames]})
        self._wake.set()

    def _publish_perf(self, now: float) -> None:
        with self._lock:
            interval = max(now - self._last_perf_at, 0.001)
            metrics = self._memory.last_read_metrics
            rtt_backend = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
            capture = getattr(rtt_backend, "control_block", None)
            dropped = sum(getattr(getattr(channel, "stream", None), "dropped", 0)
                          for channel in getattr(capture, "up_channels", []))
            with self._perf_lock:
                sample_count = self._sample_count_since_perf
                self._sample_count_since_perf = 0
            payload = {
                "effectiveHz": sample_count / interval,
                "sampleCount": sample_count,
                "watchCount": len(self._watches),
                "readBlockCount": metrics.get("block_count", 0),
                "readByteCount": metrics.get("byte_count", 0),
                "rttDroppedBytes": dropped,
                "rttTransport": (
                    self._normal_rtt.transport_name if self._rtt_protocol == "normal" else self._plus_rtt.transport_name
                ),
            }
            self._last_perf_at = now
        self._emit(EventName.PERF, payload)

    def _stop_rtt_locked(self) -> None:
        self._normal_rtt.stop()
        self._plus_rtt.stop()
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0
        self._latest_rtt_values.clear()

    def _elapsed_locked(self, now: float | None = None) -> float:
        if self._connection_started_at is None:
            return 0.0
        return max(0.0, (now if now is not None else time.perf_counter()) - self._connection_started_at)
