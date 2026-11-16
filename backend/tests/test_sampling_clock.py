import csv
import time
from types import SimpleNamespace

import pytest

from test_service import _FakeMemory, _FakeRtt
from take_a_look_backend import service as service_module
from take_a_look_backend.backends.j_scope_rtt import JScopePacket, JScopeRttBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend, RttPlusPacket
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services import sampling


@pytest.fixture
def clock_rig(tmp_path, monkeypatch):
    events = []
    clock = [100.0]
    service = BackendService(lambda name, payload: events.append((name, payload)),
                             recording_directory=tmp_path, memory_backend=_FakeMemory(),
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
                             monotonic_clock=lambda: clock[0])
    service._shutdown.set()
    service._wake.set()
    service._sampler.join(2)
    controlled_time = SimpleNamespace(perf_counter=lambda: clock[0], time_ns=time.time_ns)
    monkeypatch.setattr(service_module, 'time', controlled_time)
    monkeypatch.setattr(sampling, 'time', controlled_time)
    symbol = SymbolInfo('counter', 0x20000000, 4, 'uint32_t', '.data')
    service._symbols = {symbol.key: symbol}
    service.handle(RpcMethod.SET_WATCHES, {'watches': [{'key': symbol.key, 'readMode': 'capture'}]})
    service.handle(RpcMethod.CONNECT, {})
    try:
        yield service, clock, events
    finally:
        service.close()


def sample_once(service, events, monkeypatch):
    # Run the real acquisition and recording path for one deterministic tick.
    events.clear()
    service._next_debug_poll_at = service._last_perf_at = float('inf')
    monkeypatch.setattr(sampling, 'wait_until', lambda *args, **kwargs: service._shutdown.set())
    service._shutdown.clear()
    service._sampling_loop()
    service._flush_pending_samples_locked()
    return [frame for name, payload in events if name is EventName.SAMPLES
            for frame in payload['frames']]


def test_clear_while_paused_excludes_wait_from_samples_and_csv(clock_rig, tmp_path, monkeypatch):
    service, clock, events = clock_rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 2.0
    sample_once(service, events, monkeypatch)
    previous_recording = service._recording.path
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    cleared = service.handle(RpcMethod.CLEAR_SAMPLES, {})
    assert cleared['state']['elapsedSeconds'] == 0.0

    clock[0] += 600.0
    assert service.state_snapshot()['samplingElapsedSeconds'] == 0.0
    paused = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    assert paused['state']['samplingElapsedSeconds'] == 0.0
    resumed = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    assert resumed['state']['samplingElapsedSeconds'] == 0.0

    clock[0] += 0.02
    frames = sample_once(service, events, monkeypatch)
    assert [frame['elapsed'] for frame in frames] == pytest.approx([0.02])
    assert previous_recording.exists()
    exported = service.handle(RpcMethod.EXPORT_CSV, {'path': str(tmp_path / 'resumed.csv')})
    with open(exported['path'], encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.reader(stream))
    assert len(rows) == 2
    assert float(rows[1][0]) == pytest.approx(0.02)


def test_first_continue_after_connect_starts_at_zero(clock_rig):
    service, clock, _ = clock_rig
    clock[0] += 600.0
    assert service.state_snapshot()['samplingElapsedSeconds'] == 0.0
    resumed = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    assert resumed['state']['samplingElapsedSeconds'] == 0.0
    clock[0] += 0.02
    assert service.state_snapshot()['samplingElapsedSeconds'] == pytest.approx(0.02)


def test_clear_during_capture_restarts_the_time_axis(clock_rig, monkeypatch):
    service, clock, events = clock_rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 600.0
    assert sample_once(service, events, monkeypatch)[0]['elapsed'] == 600.0
    service.handle(RpcMethod.CLEAR_SAMPLES, {})
    assert not service._sampling_paused
    assert sample_once(service, events, monkeypatch)[0]['elapsed'] == 0.0
    clock[0] += 0.02
    assert sample_once(service, events, monkeypatch)[0]['elapsed'] == pytest.approx(0.02)
    repeated_resume = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    assert repeated_resume['state']['samplingElapsedSeconds'] == pytest.approx(0.02)


@pytest.mark.parametrize('timestamped', [True, False])
@pytest.mark.parametrize('protocol,backend_type,packet_type', [
    ('normal', JScopeRttBackend, JScopePacket),
    ('plus', JScopeRttPlusBackend, RttPlusPacket),
])
def test_rtt_timing_reanchors_after_clear_and_paused_drain(
        clock_rig, timestamped, protocol, backend_type, packet_type):
    service, clock, _ = clock_rig
    backend = backend_type()
    setattr(service, f'_{protocol}_rtt', backend)
    def packet(stamp):
        return packet_type(stamp if timestamped else None, (1.0,))

    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    assert backend._elapsed_for_packet(packet(1_000_000), 0.0) == 0.0
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    service.handle(RpcMethod.CLEAR_SAMPLES, {})
    clock[0] += 600.0
    # RTT continues draining for monitors while capture is paused.
    backend._elapsed_for_packet(packet(601_000_000), 0.0)
    resumed = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    assert backend._elapsed_for_packet(packet(601_020_000), resumed['state']['samplingElapsedSeconds']) == 0.0


def test_normal_pause_freezes_time_and_preserves_recording(clock_rig, monkeypatch):
    service, clock, events = clock_rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 2.0
    assert sample_once(service, events, monkeypatch)[0]['elapsed'] == 2.0
    recording = service._recording.path
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    clock[0] += 600.0
    state = service.state_snapshot()
    assert state['samplingElapsedSeconds'] == state['elapsedSeconds'] == 2.0
    assert not state['samplingClockRunning']
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 0.02
    assert sample_once(service, events, monkeypatch)[0]['elapsed'] == pytest.approx(2.02)
    assert service._recording.path == recording
    assert service._recording.sample_count == 2


def test_state_reads_do_not_change_clock_or_rtt_decoder(clock_rig):
    from unittest.mock import Mock
    service, clock, _ = clock_rig
    reset = service._normal_rtt.reset_timing = Mock()
    for _ in range(3):
        service.state_snapshot()
    assert not service._acquisition_clock.running
    reset.assert_not_called()
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    reset.reset_mock()
    clock[0] += 1.0
    for _ in range(3):
        assert service.state_snapshot()['samplingElapsedSeconds'] == 1.0
        assert service.state_snapshot()['elapsedSeconds'] == 0.0
    reset.assert_not_called()


def test_pause_freezes_before_waiting_for_remote_subscription(clock_rig):
    service, clock, _ = clock_rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 2
    def stop():
        clock[0] += 10
    service._memory.stop_sampling = stop
    paused = service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    assert paused['state']['samplingElapsedSeconds'] == 2


@pytest.mark.parametrize('backend_type,packet_type', [
    (JScopeRttBackend, JScopePacket), (JScopeRttPlusBackend, RttPlusPacket),
])
def test_configured_rtt_rate_controls_untimed_spacing(clock_rig, backend_type, packet_type):
    service, _, _ = clock_rig
    backend = backend_type()
    service._normal_rtt = backend
    service.handle(RpcMethod.SET_CONFIG, {'rttSampleRateHz': 200})
    assert backend._elapsed_for_packet(packet_type(None, (1.0,)), 0.0) == 0.0
    assert backend._elapsed_for_packet(packet_type(None, (1.0,)), 0.0) == pytest.approx(0.005)
    service.handle(RpcMethod.SET_CONFIG, {'rttSampleRateHz': 100})
    assert backend._elapsed_for_packet(packet_type(None, (1.0,)), 0.0) == pytest.approx(0.015)


def test_reconnect_and_target_halt_use_explicit_clock_transitions(clock_rig, monkeypatch):
    service, clock, events = clock_rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': False})
    clock[0] += 2
    sample_once(service, events, monkeypatch)
    service.handle(RpcMethod.DEBUG_CONTROL, {'action': 'halt'})
    clock[0] += 600
    assert service.state_snapshot()['samplingElapsedSeconds'] == 2
    assert not service.state_snapshot()['samplingClockRunning']
    service.handle(RpcMethod.DEBUG_CONTROL, {'action': 'resume'})
    clock[0] += 0.02
    assert service.state_snapshot()['samplingElapsedSeconds'] == pytest.approx(2.02)
    service.handle(RpcMethod.DISCONNECT, {})
    service.handle(RpcMethod.CONNECT, {})
    clock[0] += 600
    assert service.state_snapshot()['elapsedSeconds'] == 0
    assert service.state_snapshot()['samplingElapsedSeconds'] == 0
