from unittest.mock import Mock

from take_a_look_backend.backends.target_backend import TargetCapabilities
from take_a_look_backend.services.debug_session import DebugSession


def test_breakpoint_step_restores_hardware_breakpoint_before_resume():
    target = Mock()
    target.capabilities = TargetCapabilities()
    target.debug_state.return_value = "halted"
    target.read_core_registers.return_value = {"pc": 0x08000001}
    target.set_breakpoint.return_value = True
    debug = DebugSession()
    debug.resolved_breakpoints = [{"address": 0x08000000, "verified": True}]

    debug.continue_or_step(target, resume=True)

    assert [call[0] for call in target.method_calls] == [
        "debug_state", "read_core_registers", "remove_breakpoint",
        "step", "set_breakpoint", "resume",
    ]


def test_debug_refresh_owns_stopped_state_without_a_service_or_worker():
    target = Mock()
    target.debug_state.return_value = "halted"
    target.read_core_registers.return_value = {"pc": 0x08000000}
    debug = DebugSession()
    assert debug.refresh(target, force=False)
    assert debug.snapshot()["stoppedLocation"] == {"address": 0x08000000}
    assert not debug.refresh(target, force=False)
    assert target.read_core_registers.call_count == 1

    target.debug_state.return_value = "running"
    assert debug.refresh(target, force=False)
    assert debug.snapshot()["registers"] == {}
    assert debug.snapshot()["stoppedLocation"] is None
