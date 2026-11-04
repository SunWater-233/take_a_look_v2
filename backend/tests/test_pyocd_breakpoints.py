from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from pyocd.core.exceptions import TransferError
from pyocd.core.memory_map import FlashRegion, MemoryMap
from pyocd.core.target import Target
from pyocd.coresight.fpb import FPB
from pyocd.debug.breakpoints.manager import BreakpointManager

from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend
from take_a_look_backend.protocol import EventName, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex, SourceLocation


class _BufferedAccessPort:
    """Model probe write buffering while using pyOCD's real FPB implementation."""

    def __init__(self) -> None:
        # FPB revision 2 with two hardware comparators.
        self.memory = {0xE0002000: (1 << 28) | (2 << 4)}
        self.pending: dict[int, int] = {}

    def read32(self, address: int) -> int:
        self.flush()
        return self.memory.get(address, 0)

    def write_memory(self, address: int, value: int) -> None:
        self.pending[address] = value

    write32 = write_memory

    def flush(self) -> None:
        self.memory.update(self.pending)
        self.pending.clear()


@pytest.fixture
def pyocd_backend():
    ap = _BufferedAccessPort()
    fpb = FPB(ap, addr=0xE0002000)
    fpb.init()
    ap.flush()
    core = SimpleNamespace(
        session=Mock(),
        memory_map=MemoryMap(FlashRegion(start=0x08000000, length=0x100000, blocksize=0x1000)),
    )
    core.bp_manager = BreakpointManager(core)
    core.bp_manager.add_provider(fpb)
    target = Mock(spec=[
        "selected_core", "set_breakpoint", "remove_breakpoint", "find_breakpoint",
        "flush", "get_state", "read_core_registers_raw", "halt", "resume", "step",
    ])
    target.selected_core = core
    target.set_breakpoint.side_effect = core.bp_manager.set_breakpoint
    target.remove_breakpoint.side_effect = core.bp_manager.remove_breakpoint
    target.find_breakpoint.side_effect = core.bp_manager.find_breakpoint
    target.flush.side_effect = ap.flush
    target.get_state.return_value = Target.State.RUNNING
    target.read_core_registers_raw.side_effect = lambda names: [
        {"pc": 0x08000108, "sp": 0x20001000}.get(name, 0) for name in names
    ]
    backend = PyOcdMemoryBackend()
    backend.target = target
    backend.session = Mock()
    return SimpleNamespace(backend=backend, target=target, manager=core.bp_manager, fpb=fpb, ap=ap)


@pytest.mark.parametrize("state", [Target.State.RUNNING, Target.State.HALTED])
@pytest.mark.parametrize("address", [0x08000108, 0x08000109])
def test_add_programs_fpb_before_reporting_success(pyocd_backend, state, address):
    harness = pyocd_backend
    harness.target.get_state.return_value = state

    assert harness.backend.set_breakpoint(address)

    assert harness.ap.memory[0xE0002000] & 1  # FPB enabled.
    assert harness.ap.memory[0xE0002008] == 0x08000109
    assert harness.manager.find_breakpoint(0x08000108).enabled
    assert not harness.ap.pending
    harness.target.halt.assert_not_called()
    harness.target.resume.assert_not_called()
    harness.target.step.assert_not_called()


def test_remove_clears_fpb_without_waiting_for_resume(pyocd_backend):
    harness = pyocd_backend
    # Seed an installed breakpoint independently of the adapter under test.
    harness.target.set_breakpoint(0x08000108)
    harness.manager.flush()
    harness.target.flush()
    assert harness.ap.memory[0xE0002008] == 0x08000109

    harness.backend.remove_breakpoint(0x08000108)

    assert harness.ap.memory[0xE0002008] == 0
    assert harness.manager.find_breakpoint(0x08000108) is None
    assert not harness.ap.pending
    harness.target.resume.assert_not_called()


def test_provider_rejection_is_not_reported_as_verified(pyocd_backend, monkeypatch):
    harness = pyocd_backend
    monkeypatch.setattr(harness.fpb, "set_breakpoint", lambda _address: None)

    assert not harness.backend.set_breakpoint(0x08000108)
    assert harness.ap.memory[0xE0002008] == 0
    assert harness.manager.find_breakpoint(0x08000108) is None


def test_probe_flush_failure_is_propagated(pyocd_backend):
    harness = pyocd_backend
    harness.target.flush.side_effect = TransferError("probe write failed")

    with pytest.raises(TransferError, match="probe write failed"):
        harness.backend.set_breakpoint(0x08000108)


def test_removed_comparator_is_immediately_reusable(pyocd_backend):
    harness = pyocd_backend
    assert harness.backend.set_breakpoint(0x08000100)
    assert harness.backend.set_breakpoint(0x08000108)
    assert not harness.backend.set_breakpoint(0x08000110)
    harness.backend.remove_breakpoint(0x08000100)
    assert harness.backend.set_breakpoint(0x08000110)

    assert {harness.ap.memory[0xE0002008], harness.ap.memory[0xE000200C]} == {
        0x08000109, 0x08000111,
    }


def test_running_breakpoint_rpc_programs_fpb_and_reports_stop(pyocd_backend, tmp_path):
    harness = pyocd_backend
    events = []
    path = "C:/firmware/main.c"
    elf = tmp_path / "firmware.elf"
    elf.touch()
    service = BackendService(
        lambda name, params: events.append((name, params)),
        memory_backend=harness.backend,
        symbol_loader=lambda _path, **_kwargs: [],
        debug_info_loader=lambda _path, **_kwargs: DebugInfoIndex([
            SourceLocation(path, 12, 0x08000108),
        ]),
    )
    try:
        service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(elf)})
        service.handle(RpcMethod.CONNECT, {})
        result = service.handle(RpcMethod.SET_BREAKPOINTS, {"path": path, "lines": [12]})
        assert result["debug"]["breakpoints"][0]["verified"]
        assert harness.ap.memory[0xE0002008] == 0x08000109

        # Model the core stopping at the programmed comparator, then use the
        # same poll path as the sampling worker to publish the source location.
        with service._lock:
            harness.target.get_state.return_value = Target.State.HALTED
            service._poll_debug_state_locked()
        stopped = [payload for name, payload in events
                   if name == EventName.DEBUG and payload["executionState"] == "halted"]
        assert stopped[-1]["stoppedLocation"] == {"path": path, "line": 12, "address": 0x08000108}

        service.handle(RpcMethod.SET_BREAKPOINTS, {"path": path, "lines": []})
        assert harness.ap.memory[0xE0002008] == 0
    finally:
        service.close()
