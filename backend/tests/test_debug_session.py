from unittest.mock import Mock

import pytest
from elftools.dwarf.callframe import CFARule, RegisterRule

from take_a_look_backend.backends.target_backend import TargetCapabilities
from take_a_look_backend.services.debug_info import DebugInfoIndex, SourceLocation
from take_a_look_backend.services.debug_session import DebugSession
from take_a_look_backend.services.source_stepping import SourceStepInfo


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


_CALL = 0x08000100
_RETURN = _CALL + 4
_CALLEE = 0x08000120
_STACK = 0x20001000


def _registers(pc, *, sp=_STACK, lr=_RETURN | 1):
    return {'pc': pc, 'sp': sp, 'lr': lr, 'xpsr': 0x01000000}


def _source_session():
    debug = DebugSession()
    dwarf = Mock()
    dwarf.has_CFI.return_value = dwarf.has_EH_CFI.return_value = False
    debug.info = DebugInfoIndex([
        SourceLocation('main.c', 10, _CALL),
        SourceLocation('main.c', 11, _RETURN),
        SourceLocation('motor.c', 20, _CALLEE),
    ], source_steps=SourceStepInfo(dwarf, [(_CALL, _RETURN + 2), (_CALLEE, _CALLEE + 8)],
                                  [(_CALL, _CALLEE + 8)]))
    target = Mock()
    target.capabilities = TargetCapabilities()
    target.debug_state.return_value = 'halted'
    target.set_breakpoint.return_value = True
    return debug, target


def test_global_pause_reconnect_and_clear_respect_per_line_settings():
    debug, target = _source_session()
    requested = {'main.c': {10, 11}, 'motor.c': {20}}
    disabled = {'main.c': {11}}
    debug.execution_state = 'running'
    debug.replace_breakpoints(requested, disabled, False, target, connected=True)
    assert [item['status'] for item in debug.resolved_breakpoints] == ['installed', 'disabled', 'installed']
    assert [call.args[0] for call in target.set_breakpoint.call_args_list] == [_CALL, _CALLEE]

    debug.replace_breakpoints(requested, disabled, True, target, connected=True)
    assert [item['status'] for item in debug.resolved_breakpoints] == ['paused', 'disabled', 'paused']
    assert [call.args[0] for call in target.remove_breakpoint.call_args_list] == [_CALL, _CALLEE]
    assert debug.snapshot()['executionState'] == 'running'

    target.reset_mock()
    debug.mark_breakpoints_pending()
    debug.apply_breakpoints(target, connected=True)
    target.set_breakpoint.assert_not_called()
    debug.replace_breakpoints(requested, disabled, False, target, connected=True)
    assert [call.args[0] for call in target.set_breakpoint.call_args_list] == [_CALL, _CALLEE]
    debug.replace_breakpoints({}, {}, False, target, connected=True)
    assert debug.snapshot()['requestedBreakpoints'] == {}
    assert debug.snapshot()['disabledBreakpoints'] == {}


def test_failed_bulk_removal_restores_previously_removed_addresses():
    debug, target = _source_session()
    debug.replace_breakpoints({'main.c': {10, 11}}, {}, False, target, connected=True)
    target.reset_mock()
    target.remove_breakpoint.side_effect = [None, RuntimeError('probe refused')]

    with pytest.raises(RuntimeError, match='probe refused'):
        debug.replace_breakpoints({}, {}, False, target, connected=True)

    assert debug.snapshot()['requestedBreakpoints'] == {'main.c': [10, 11]}
    assert all(item['verified'] for item in debug.resolved_breakpoints)
    assert [call.args[0] for call in target.set_breakpoint.call_args_list] == [_CALL, _RETURN]
    assert debug.breakpoint_revision == 1


def test_source_step_in_enters_a_called_function():
    debug, target = _source_session()
    target.read_debug_memory.side_effect = [b'\x00\xf0', b'\x00\xf8']
    target.read_core_registers.side_effect = [_registers(_CALL), _registers(_CALLEE)]

    debug.step_source(target, 'stepIn')

    target.step.assert_called_once_with()
    target.resume.assert_not_called()
    target.set_breakpoint.assert_not_called()


def test_source_step_in_advances_past_multiple_instructions_on_one_line():
    debug, target = _source_session()
    target.read_debug_memory.return_value = b'\x00\xbf'  # Thumb NOP
    target.read_core_registers.side_effect = [_registers(pc) for pc in (_CALL, _CALL + 2, _RETURN)]

    debug.step_source(target, 'stepIn')

    assert target.step.call_count == 2


@pytest.mark.parametrize('existing', [False, True])
def test_source_step_over_uses_a_return_breakpoint_without_removing_user_breakpoints(existing):
    debug, target = _source_session()
    target.read_debug_memory.side_effect = [b'\x00\xf0', b'\x00\xf8']
    target.read_core_registers.side_effect = [_registers(_CALL), _registers(_RETURN)]
    if existing:
        debug.resolved_breakpoints = [{'address': _RETURN, 'verified': True}]

    debug.step_source(target, 'stepOver')

    target.resume.assert_called_once_with()
    target.step.assert_not_called()
    assert target.set_breakpoint.call_count == target.remove_breakpoint.call_count == (0 if existing else 1)
    if not existing:
        target.set_breakpoint.assert_called_once_with(_RETURN)
        target.remove_breakpoint.assert_called_once_with(_RETURN)


def test_source_step_out_unwinds_a_saved_lr_using_the_frame_pointer(monkeypatch):
    debug, target = _source_session()
    monkeypatch.setattr(debug.info.source_steps, 'frame_rules', lambda _:
                        (CFARule(reg=7, offset=8), RegisterRule(RegisterRule.OFFSET, -4)))
    target.read_debug_registers.return_value = {'r7': _STACK - 8}
    target.read_debug_memory.return_value = (_RETURN | 1).to_bytes(4, 'little')
    target.read_core_registers.side_effect = [
        _registers(_CALLEE, sp=_STACK - 8, lr=0x08000127), _registers(_RETURN),
    ]

    debug.step_source(target, 'stepOut')

    target.read_debug_registers.assert_called_once_with(['r7'])
    target.read_debug_memory.assert_called_once_with(_STACK - 4, 4)
    target.set_breakpoint.assert_called_once_with(_RETURN)
    target.remove_breakpoint.assert_called_once_with(_RETURN)


def test_source_step_over_stops_at_a_user_breakpoint_inside_the_callee():
    debug, target = _source_session()
    target.read_debug_memory.side_effect = [b'\x00\xf0', b'\x00\xf8']
    target.read_core_registers.side_effect = [_registers(_CALL), _registers(_CALLEE)]
    debug.resolved_breakpoints = [{'address': _CALLEE, 'verified': True}]

    debug.step_source(target, 'stepOver')

    target.resume.assert_called_once_with()
    target.remove_breakpoint.assert_called_once_with(_RETURN)
    assert debug.resolved_breakpoints[0]['verified']


def test_source_step_over_leaves_target_halted_and_cleans_up_on_timeout(monkeypatch):
    debug, target = _source_session()
    target.read_debug_memory.side_effect = [b'\x00\xf0', b'\x00\xf8']
    target.read_core_registers.return_value = _registers(_CALL)
    target.debug_state.side_effect = ['halted', 'running']
    clock = iter([0, 0, 0, 0, 5])
    monkeypatch.setattr('take_a_look_backend.services.debug_session.monotonic', lambda: next(clock))

    with pytest.raises(RuntimeError, match='超时'):
        debug.step_source(target, 'stepOver')

    target.halt.assert_called_once_with()
    target.remove_breakpoint.assert_called_once_with(_RETURN)
