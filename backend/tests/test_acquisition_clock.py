import pytest

from take_a_look_backend.services.acquisition_clock import AcquisitionClock
from take_a_look_backend.backends.sample_timebase import SampleTimebase


def test_clock_reads_are_pure_and_pause_resume_are_idempotent():
    now = [100.0]
    clock = AcquisitionClock(lambda: now[0])
    assert clock.elapsed() == 0
    now[0] += 600
    assert clock.elapsed() == 0
    assert clock.set_running(True)
    now[0] += 2
    assert not clock.set_running(True)
    assert clock.set_running(False)
    now[0] += 600
    assert clock.elapsed() == 2
    assert not clock.set_running(False)
    assert clock.set_running(True)
    now[0] += 0.02
    assert clock.elapsed() == pytest.approx(2.02)
    clock.reset(running=True)
    assert clock.elapsed() == 0
    now[0] += 1
    assert clock.elapsed() == 1
    clock.reset()
    now[0] += 600
    assert clock.elapsed() == 0
    assert not clock.running


def test_target_wrap_and_reset_never_move_time_backwards():
    mapping = SampleTimebase()
    assert mapping.elapsed(0xFFFFFFF0, 2.0) == 2.0
    assert mapping.elapsed(0x10, 2.0) == pytest.approx(2.000032)
    mapping.reset()
    assert mapping.elapsed(1_000_000, 5.0) == 5.0
    assert mapping.elapsed(1_020_000, 5.02) == 5.02
    assert mapping.elapsed(100, 5.03) == 5.03
    assert mapping.elapsed(20_100, 5.05) == pytest.approx(5.05)
