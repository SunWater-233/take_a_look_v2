"""QPC-backed deadlines without a minimum polling period or catch-up samples.

On Windows/Python 3.11, monotonic() uses GetTickCount64 with a 15.625 ms
resolution. perf_counter() is also monotonic and uses QueryPerformanceCounter.
All acquisition epochs, deadlines and elapsed values use that same clock.
"""
from __future__ import annotations

import time
from threading import Event


def advance_deadline(previous: float, now: float, period: float) -> float:
    return previous + max(1, int((now - previous) / period) + 1) * period


def wait_until(wake: Event, deadline: float, *, precise: bool = False) -> None:
    # Event.wait uses coarse Windows timeout granularity. Python 3.11+ sleep
    # uses the high-resolution timer. Short sleeps also release the GIL and
    # bound command/shutdown latency without busy-spinning a CPU core.
    while not wake.is_set():
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            break
        if remaining > 0.020:
            wake.wait(remaining - 0.016)
        elif precise and remaining <= 0.0008:
            # Yield instead of spinning or accepting an oversleep of ~0.5 ms.
            # The sampler enables this only for active >1 kHz memory capture.
            time.sleep(0)
        elif precise:
            time.sleep(min(remaining - 0.0008, 0.002))
        else:
            time.sleep(min(remaining, 0.002))
    wake.clear()
