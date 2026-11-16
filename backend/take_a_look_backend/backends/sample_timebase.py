"""Map producer timestamps or nominal sample spacing onto acquisition time."""
from __future__ import annotations

import math
from numbers import Real


class SampleTimebase:
    def __init__(self) -> None:
        self.nominal_rate_hz = 1000.0
        self.reset()

    def set_rate(self, rate_hz: float) -> None:
        if isinstance(rate_hz, Real) and not isinstance(rate_hz, bool) and math.isfinite(rate_hz) and rate_hz > 0:
            if self._next_untimed is not None and self._last_elapsed is not None and rate_hz != self.nominal_rate_hz:
                self._next_untimed = self._last_elapsed + 1.0 / rate_hz
            self.nominal_rate_hz = float(rate_hz)

    def reset(self) -> None:
        self._first_target_us: int | None = None
        self._last_target_us: int | None = None
        self._wraps = 0
        self._host_origin: float | None = None
        self._next_untimed: float | None = None
        self._last_elapsed: float | None = None

    def elapsed(self, timestamp_us: int | None, host_elapsed: float) -> float:
        if timestamp_us is None:
            elapsed = host_elapsed if self._next_untimed is None else self._next_untimed
            self._next_untimed = elapsed + 1.0 / self.nominal_rate_hz
        else:
            if self._last_target_us is not None and timestamp_us < self._last_target_us:
                if self._last_target_us - timestamp_us > 0x80000000:
                    self._wraps += 1
                else:
                    # A producer reset is a discontinuity, not uint32 wrap.
                    # Re-anchor without moving an existing channel backwards.
                    self._first_target_us = None
                    self._wraps = 0
            self._last_target_us = timestamp_us
            unwrapped = timestamp_us + self._wraps * 0x100000000
            if self._first_target_us is None:
                self._first_target_us = unwrapped
                self._host_origin = max(host_elapsed, self._last_elapsed or 0.0)
            elapsed = self._host_origin + (unwrapped - self._first_target_us) / 1_000_000.0
        self._last_elapsed = elapsed
        return elapsed
