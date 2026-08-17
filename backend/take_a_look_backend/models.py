from __future__ import annotations

from dataclasses import dataclass


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

    @property
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
        return not self.is_rtt and not self.section.startswith(".rodata")


@dataclass
class WatchedVariable:
    symbol: SymbolInfo
    color: str
    plot_enabled: bool = True
    value: object = ""
