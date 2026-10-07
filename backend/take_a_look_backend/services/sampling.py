from __future__ import annotations

import time
from typing import Any

from take_a_look_backend.models import json_value
from take_a_look_backend.protocol import EventName


class SamplingServiceMixin:
    """Time-critical acquisition loop and RTT lifecycle."""

    def _sampling_loop(self) -> None:
        next_memory_at = time.monotonic()
        next_rtt_at = time.monotonic()
        pending_frames: list[tuple[float, dict[str, object]]] = []
        last_emit_at = time.monotonic()
        while not self._shutdown.is_set():
            now = time.monotonic()
            try:
                with self._lock:
                    connected = self._connection_status == "connected"
                    paused = self._sampling_paused
                    if connected and now >= self._next_debug_poll_at:
                        self._poll_debug_state_locked()
                        self._next_debug_poll_at = now + 0.05
                        connected = self._connection_status == "connected"
                    target_halted = self._target_execution_state == "halted"
                    memory_period = 1.0 / self._sample_rate_hz
                    rtt_period = 1.0 / self._rtt_sample_rate_hz
                    elapsed = self._elapsed_locked(now)
                    has_watches = bool(self._watches)
                    rtt_enabled = self._rtt_enabled
                    rtt_protocol = self._rtt_protocol
                    if connected and not paused and not target_halted and has_watches and now >= next_memory_at:
                        values = self._read_memory_locked(rtt_enabled, rtt_protocol)
                        if values:
                            pending_frames.append((elapsed, values))
                        next_memory_at = now + memory_period
                    if connected and not paused and not target_halted and rtt_enabled and now >= next_rtt_at:
                        pending_frames.extend(self._read_rtt_locked(elapsed, now))
                        next_rtt_at = now + max(rtt_period, 0.002)
            except Exception as error:
                with self._lock:
                    self._handle_remote_failure_locked(error)
                self._emit(EventName.LOG, {"level": "error", "message": f"采样失败：{error}"})
                next_memory_at = time.monotonic() + 0.25

            now = time.monotonic()
            if pending_frames and (len(pending_frames) >= 64 or now - last_emit_at >= 0.006):
                self._publish_samples(pending_frames)
                pending_frames = []
                last_emit_at = now
            if now - self._last_perf_at >= 1.0:
                self._publish_perf(now)
            wait_s = min(max(next_memory_at - now, 0.001), max(next_rtt_at - now, 0.001), 0.05)
            self._wake.wait(wait_s)
            self._wake.clear()

    def _read_memory_locked(self, rtt_enabled: bool, rtt_protocol: str) -> dict[str, object]:
        if not getattr(self._memory, "supports_running_memory", True):
            return {}
        if rtt_enabled and rtt_protocol == "plus" and self._plus_rtt.is_started:
            return {}
        symbols = [watch.symbol for watch in self._watches.values() if not watch.symbol.is_rtt]
        if not symbols:
            return {}
        values = self._memory.read_symbols(symbols)
        for key, value in values.items():
            if key in self._watches:
                self._watches[key].value = value
        return values

    def _read_rtt_locked(self, elapsed: float, now: float) -> list[tuple[float, dict[str, object]]]:
        backend: Any = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
        target = getattr(self._memory, "rtt_target", self._memory.target)
        if not backend.is_started:
            if now < self._next_rtt_retry_at:
                return []
            try:
                if self._rtt_protocol == "normal":
                    symbols = self._normal_rtt.start(
                        target,
                        self._rtt_control_block_address,
                        self._memory.probe,
                    )
                else:
                    symbols = self._plus_rtt.start(
                        target,
                        self._rtt_control_block_address,
                        self._memory.probe,
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
        for _frame_elapsed, values in frames:
            for key, value in values.items():
                if key in self._watches:
                    self._watches[key].value = value
        return frames

    def _publish_samples(self, frames: list[tuple[float, dict[str, object]]]) -> None:
        with self._lock:
            normalized = [
                {"elapsed": elapsed, "values": {key: json_value(value) for key, value in values.items()}}
                for elapsed, values in frames
            ]
            sampled_keys = {
                key for key, watch in self._watches.items() if watch.sampling_enabled
            }
            self._samples.extend(
                (
                    frame["elapsed"],
                    {
                        key: value
                        for key, value in frame["values"].items()
                        if key in sampled_keys
                    },
                )
                for frame in normalized
                if any(key in sampled_keys for key in frame["values"])
            )
            self._sample_count_since_perf += len(normalized)
        self._emit(EventName.SAMPLES, {"frames": normalized})

    def _publish_perf(self, now: float) -> None:
        with self._lock:
            interval = max(now - self._last_perf_at, 0.001)
            metrics = self._memory.last_read_metrics
            rtt_backend = self._normal_rtt if self._rtt_protocol == "normal" else self._plus_rtt
            capture = getattr(rtt_backend, "control_block", None)
            dropped = sum(getattr(getattr(channel, "stream", None), "dropped", 0)
                          for channel in getattr(capture, "up_channels", []))
            payload = {
                "effectiveHz": self._sample_count_since_perf / interval,
                "sampleCount": self._sample_count_since_perf,
                "watchCount": len(self._watches),
                "readBlockCount": metrics.get("block_count", 0),
                "readByteCount": metrics.get("byte_count", 0),
                "rttDroppedBytes": dropped,
                "rttTransport": (
                    self._normal_rtt.transport_name if self._rtt_protocol == "normal" else self._plus_rtt.transport_name
                ),
            }
            self._sample_count_since_perf = 0
            self._last_perf_at = now
        self._emit(EventName.PERF, payload)

    def _stop_rtt_locked(self) -> None:
        self._normal_rtt.stop()
        self._plus_rtt.stop()
        self._last_rtt_error = ""
        self._next_rtt_retry_at = 0.0

    def _elapsed_locked(self, now: float | None = None) -> float:
        if self._connection_started_at is None:
            return 0.0
        return max(0.0, (now if now is not None else time.monotonic()) - self._connection_started_at)
