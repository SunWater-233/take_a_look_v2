"""The target operations consumed by orchestration, independent of an adapter."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Protocol

from take_a_look_backend.models import SymbolInfo


@dataclass(frozen=True)
class TargetCapabilities:
    memory_sampling: bool = True
    memory_write: bool = True
    rtt: bool = True
    firmware_download: bool = False
    manages_breakpoint_step: bool = False

    def to_json(self) -> dict[str, bool]:
        return {
            "memorySampling": self.memory_sampling,
            "memoryWrite": self.memory_write,
            "rtt": self.rtt,
            "firmwareDownload": self.firmware_download,
        }


def capabilities_for_connection(kind: str) -> TargetCapabilities:
    return TargetCapabilities(
        memory_sampling=kind in {"local", "ember"},
        memory_write=kind != "ember",
        rtt=kind != "gdb",
        firmware_download=kind == "local",
        manages_breakpoint_step=kind in {"emberGdb", "gdb"},
    )


@dataclass(frozen=True)
class RttBinding:
    target: Any
    probe: Any | None


class TargetBackend(Protocol):
    capabilities: TargetCapabilities
    last_read_metrics: dict[str, int]
    last_connect_timings: dict[str, float]

    @property
    def is_connected(self) -> bool: ...
    @property
    def rtt_binding(self) -> RttBinding: ...
    def connect(self, config: Any) -> None: ...
    def disconnect(self) -> None: ...
    def read_symbols(self, symbols: list[SymbolInfo]) -> dict[str, object]: ...
    def write_symbol(self, symbol: SymbolInfo, value_text: str) -> object: ...
    def write_symbols(self, writes: list[tuple[SymbolInfo, str]]) -> dict[str, object]: ...
    def reset(self, halt: bool = False) -> None: ...
    def halt(self) -> None: ...
    def resume(self) -> None: ...
    def step(self) -> None: ...
    def debug_state(self) -> str: ...
    def set_breakpoint(self, address: int) -> bool: ...
    def remove_breakpoint(self, address: int) -> None: ...
    def read_core_registers(self) -> dict[str, int]: ...
    def program_firmware(self, path: str, progress: Callable[[float], None]) -> None: ...


def backend_capabilities(backend: TargetBackend) -> TargetCapabilities:
    capabilities = getattr(backend, "capabilities", None)
    if isinstance(capabilities, TargetCapabilities):
        return capabilities
    # Preserve the existing injected-backend contract for callers and test fakes.
    return TargetCapabilities(
        memory_sampling=getattr(backend, "supports_running_memory", True),
        memory_write=getattr(backend, "supports_memory_write", True),
        manages_breakpoint_step=getattr(backend, "manages_breakpoint_step", False),
    )


def backend_rtt_binding(backend: TargetBackend) -> RttBinding:
    binding = getattr(backend, "rtt_binding", None)
    if isinstance(binding, RttBinding):
        return binding
    return RttBinding(
        getattr(backend, "rtt_target", getattr(backend, "target", None)),
        getattr(backend, "probe", None),
    )
