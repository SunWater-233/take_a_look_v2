from __future__ import annotations

import logging
import time
from typing import Any

from take_a_look_backend.models import WatchedVariable, json_value
from take_a_look_backend.backends.ember_transport import EmberError
from take_a_look_backend.backends.target_backend import backend_capabilities, backend_rtt_binding
from take_a_look_backend.protocol import EventName, ProtocolError
from take_a_look_backend.services.sampling_clock import advance_deadline, wait_until


_LOG = logging.getLogger(__name__)


class SamplingServiceMixin:
    """Time-critical acquisition loop and RTT lifecycle."""

    def _sampling_loop(self) -> None:
        next_memory_at = next_rtt_at = next_monitor_at = last_emit_at = time.perf_counter()
        previous_periods = None
        monitor_revision = -1
        last_sampling_error = None
        while not self._shutdown.is_set():
            if not self._controls_idle.is_set():
                self._controls_idle.wait(0.05)
                continue
            now = time.perf_counter()
            deadlines = [now + 0.05]
            precise = False
            try:
                with self._lock:
                    connected = (self._connection_status == "connected" and not self._firmware_busy
                                 and not self._firmware.get("requiresDownload"))
                    if connected and now >= self._next_debug_poll_at:
                        self._poll_debug_state_locked()
                        # The phone services every probe request on one worker, so a
                        # status poll steals read time from capture. Poll slowly while
                        # a running target is being sampled quickly.
                        fast_capture = (self._debug.execution_state != "halted"
                                        and self._sample_rate_hz >= 200)
                        self._next_debug_poll_at = now + (0.25 if fast_capture else 0.05)
                        connected = self._connection_status == "connected"
                    if connected:
                        deadlines.append(self._next_debug_poll_at)
                    if monitor_revision != self._monitor_schedule_revision:
                        monitor_revision = self._monitor_schedule_revision
                        next_monitor_at = now
                    active = connected and not self._sampling_paused and self._debug.execution_state != "halted"
                    if self._reconcile_acquisition_clock_locked():
                        self._emit(EventName.STATE, self._sampling_clock_state())
                    memory_period = 1.0 / self._sample_rate_hz
                    rtt_period = max(1.0 / self._rtt_sample_rate_hz, 0.002)
                    periods = (memory_period, rtt_period)
                    if previous_periods != periods:
                        next_memory_at = next_rtt_at = now
                        previous_periods = periods
                    elapsed = self._acquisition_clock.elapsed()
                    self._poll_freertos_locked(now, connected)
                    if self._freertos_enabled:
                        deadlines.append(self._next_freertos_at)
                    rtt_enabled = self._rtt_enabled
                    rtt_protocol = self._rtt_protocol
                    if self._pipeline.backpressure:
                        self._flush_pending_samples_locked(wait=False)
                    if connected:
                        if now >= next_monitor_at:
                            next_monitor_at = self._poll_monitors_locked(now)
                        deadlines.append(next_monitor_at)
                    memory_enabled = (active and bool(self._capture_symbols_locked()) and
                            backend_capabilities(self._memory).memory_sampling and
                            not (rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started))
                    if not memory_enabled or self._pipeline.backpressure:
                        self._stop_memory_sampling_locked()
                    if connected and not self._pipeline.backpressure:
                        if memory_enabled:
                            push_read = getattr(self._memory, "read_sample_frames", None)
                            frames = (push_read(self._capture_symbols_locked(), self._sample_rate_hz, elapsed)
                                      if push_read is not None else None)
                            if frames is not None:
                                if frames:
                                    self._remember_values_locked(frames[-1][1])
                                    self._queue_samples_locked(frames)
                                # Drain in batches; acquisition is clocked on the phone.
                                deadlines.append(time.perf_counter() + 0.002)
                            elif now >= next_memory_at:
                                precise = memory_period < 0.001
                                values = self._read_memory_locked(rtt_enabled, rtt_protocol)
                                if values:
                                    self._queue_samples_locked([(elapsed, values)])
                                next_memory_at = advance_deadline(next_memory_at, time.perf_counter(), memory_period)
                            if frames is None:
                                deadlines.append(next_memory_at)
                        # Drain push streams while capture is paused. Monitors use
                        # fresh cached values; old RTT frames must never be replayed.
                        if rtt_enabled and self._debug.execution_state != "halted":
                            if now >= next_rtt_at:
                                frames = self._read_rtt_locked(elapsed, now)
                                if active:
                                    self._queue_samples_locked(frames)
                                next_rtt_at = advance_deadline(next_rtt_at, time.perf_counter(), rtt_period)
                            deadlines.append(next_rtt_at)
                    if self._pipeline.pending_count:
                        if self._pipeline.pending_count >= 64 or now - last_emit_at >= 0.006:
                            if self._flush_pending_samples_locked(wait=False):
                                last_emit_at = now
                        if not self._pipeline.backpressure:
                            deadlines.append(last_emit_at + 0.006)
                last_sampling_error = None
            except Exception as error:
                message = error.message if isinstance(error, ProtocolError) else str(error)
                signature = (type(error), message)
                if signature != last_sampling_error:
                    _LOG.exception("采样失败：%s", message)
                    last_sampling_error = signature
                with self._lock:
                    disconnected = self._handle_connection_failure_locked(error)
                    if not disconnected:
                        self._stop_memory_sampling_locked()
                    if isinstance(error, EmberError) and error.code == "client_overflow":
                        self._sampling_paused = True
                        self._reconcile_acquisition_clock_locked()
                        self._emit(EventName.ERROR, {"code": error.code, "message": str(error)})
                        self._emit(EventName.STATE, {"samplingPaused": True, **self._sampling_clock_state()})
                if not disconnected:
                    self._emit(EventName.LOG, {"level": "error", "message": f"采样失败：{message}"})
                next_memory_at = time.perf_counter() + 0.25
                deadlines = [next_memory_at]
            now = time.perf_counter()
            if now - self._last_perf_at >= 1.0:
                self._publish_perf(now)
            wait_until(self._wake, min(deadlines), precise=precise)

    @staticmethod
    def _watch_value_json(watch: WatchedVariable) -> dict[str, object]:
        return {"key": watch.symbol.key, "value": json_value(watch.value),
                "updatedAtMs": watch.updated_at_ms}

    def _stop_memory_sampling_locked(self):
        stop = getattr(self._memory, "stop_sampling", None)
        if stop is not None:
            stop()

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
                           or self._debug.execution_state == "halted")
        plus = self._rtt_enabled and self._rtt_protocol == "plus"
        for watch in self._watches.values():
            if watch.mode != "monitor" or not watch.monitor_enabled or watch.symbol.diagnostic:
                continue
            period = 1.0 / (watch.monitor_rate_hz or self._monitor_rate_hz)
            if watch.next_monitor_at <= now:
                watch.next_monitor_at = now + period
                if watch.symbol.is_rtt or (plus and self._debug.execution_state != "halted"):
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

    def _capture_symbols_locked(self) -> tuple:
        if self._capture_source is not self._watches or self._capture_source_count != len(self._watches):
            self._capture_source = self._watches
            self._capture_source_count = len(self._watches)
            self._capture_symbols = tuple(watch.symbol for watch in self._watches.values()
                                          if not watch.symbol.is_rtt and not watch.symbol.diagnostic and watch.captures)
        return self._capture_symbols

    def _read_memory_locked(self, rtt_enabled: bool, rtt_protocol: str) -> dict[str, object]:
        if not backend_capabilities(self._memory).memory_sampling:
            return {}
        if rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started:
            return {}
        symbols = self._capture_symbols_locked()
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
                self._configure_rtt_timebases_locked()
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
                if self._handle_connection_failure_locked(error):
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
        latest = self._pipeline.queue(frames, self._watches)
        if latest is not None:
            self._last_sample_seconds = max(self._last_sample_seconds, latest)

    def _flush_pending_samples_locked(self, *, wait: bool = True, block: bool | None = None) -> bool:
        return self._pipeline.flush(wait=wait, block=block)

    def _recording_failed(self, error) -> None:
        self._sampling_paused = True
        self._acquisition_clock.set_running(False)
        self._wake.set()
        self._emit(EventName.ERROR, {"code": "raw_recording_failed",
                   "message": "原始记录写入失败，已暂停采样。", "details": str(error)})
        self._emit(EventName.STATE, {"samplingPaused": True,
                   "rawRecording": self._recording.status(), **self._sampling_clock_state()})

    def _publish_perf(self, now: float) -> None:
        with self._lock:
            interval = max(now - self._last_perf_at, 0.001)
            metrics = self._memory.last_read_metrics
            rtt_backend = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
            capture = getattr(rtt_backend, "control_block", None)
            dropped = sum(getattr(getattr(channel, "stream", None), "dropped", 0)
                          for channel in getattr(capture, "up_channels", []))
            sample_count = self._pipeline.take_committed_count()
            payload = {
                "effectiveHz": sample_count / interval,
                "sampleCount": sample_count,
                "watchCount": len(self._watches),
                "readBlockCount": metrics.get("block_count", 0),
                "readByteCount": metrics.get("byte_count", 0),
                "memoryDroppedSamples": metrics.get("dropped_samples", 0),
                "memoryDroppedBatches": metrics.get("dropped_batches", 0),
                "memorySkippedTicks": metrics.get("skipped_ticks", 0),
                "memoryReadDurationUs": metrics.get("duration_us", 0),
                "memorySamplingMode": getattr(self._memory, "sampling_mode", "timed"),
                "memoryBurst": metrics.get("burst", 1),
                "memoryTimeQuality": metrics.get("time_quality", "phone_submission"),
                "memoryPhoneReadUs": getattr(self._memory, "phone_read_us", 0),
                "rttDroppedBytes": dropped,
                "rttTransport": (
                    self._normal_rtt.transport_name if self._rtt_protocol == "normal" else self._plus_rtt.transport_name
                ),
            }
            self._last_perf_at = now
        self._emit(EventName.PERF, payload)

    def _stop_rtt_locked(self) -> None:
        self._stop_memory_sampling_locked()
        self._normal_rtt.stop()
        self._plus_rtt.stop()
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0
        self._latest_rtt_values.clear()

    def _sampling_clock_state(self) -> dict[str, object]:
        elapsed, running = self._acquisition_clock.snapshot()
        return {"samplingElapsedSeconds": elapsed, "samplingClockRunning": running}

    def _acquisition_should_run(self) -> bool:
        return (self._connection_status == "connected" and not self._sampling_paused
                and not self._firmware_busy and not self._firmware.get("requiresDownload")
                and self._debug.execution_state != "halted")

    def _reconcile_acquisition_clock_locked(self) -> bool:
        running = self._acquisition_should_run()
        if running and not self._acquisition_clock.running:
            # Monitoring continues during a pause. Discard its remaining bytes
            # and map the next captured packet onto the resumed session time.
            self._reset_capture_timing_locked()
        return self._acquisition_clock.set_running(running)

    def _reset_capture_timing_locked(self) -> None:
        for backend in (self._normal_rtt, self._plus_rtt):
            discard = getattr(backend, "discard_available", None)
            if backend.is_started and discard is not None:
                discard()
            reset = getattr(backend, "reset_timing", None)
            if reset is not None:
                reset()

    def _configure_rtt_timebases_locked(self) -> None:
        for backend in (self._normal_rtt, self._plus_rtt):
            configure = getattr(backend, "set_nominal_rate_hz", None)
            if configure is not None:
                configure(self._rtt_sample_rate_hz)
