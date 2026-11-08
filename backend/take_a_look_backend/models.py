from __future__ import annotations

import math
from dataclasses import dataclass
from functools import cached_property


class SampleFrame(tuple):
    """An (elapsed, values) pair with optional acquisition-time provenance."""

    def __new__(cls, elapsed, values, timing=None):
        frame = super().__new__(cls, (elapsed, values))
        frame.timing = timing
        return frame

    def to_json(self):
        return {"elapsed": self[0], "values": self[1],
                **({"timing": self.timing} if self.timing is not None else {})}


@dataclass(frozen=True)
class SymbolInfo:
    name: str
    address: int
    size: int
    kind: str
    section: str
    source_file: str = "未知来源"
    pointer: bool = False
    data_source: str = "memory"
    source_id: str = ""
    encoding: str = ""
    byte_order: str = "little"
    diagnostic: str = ""

    @cached_property
    def key(self) -> str:
        if self.is_rtt:
            return f"rtt:{self.source_id or self.name}"
        return f"{self.address:08x}:{self.name}"

    @property
    def is_pointer(self) -> bool:
        """Whether the symbol stores an address rather than a scalar value."""
        return self.pointer or self.kind.strip().endswith("*")

    @property
    def is_rtt(self) -> bool:
        return self.data_source == "rtt"

    @property
    def is_writable(self) -> bool:
        return not self.is_rtt and not self.diagnostic and not self.section.startswith(".rodata")


@dataclass
class WatchedVariable:
    symbol: SymbolInfo
    color: str
    plot_enabled: bool = False
    sampling_enabled: bool = True
    value: object = ""
    read_mode: str | None = None
    monitor_rate_hz: float | None = None
    updated_at_ms: int | None = None
    next_monitor_at: float = 0.0
    monitor_enabled: bool = True

    @property
    def mode(self) -> str:
        return self.read_mode or ("capture" if self.sampling_enabled else "monitor")

    @property
    def captures(self) -> bool:
        return self.mode == "capture"


def json_value(value: object) -> object:
    """Normalize hardware values to JSON-safe scalar values."""
    if isinstance(value, (str, int, bool)) or value is None:
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    return str(value)
