from __future__ import annotations

import pytest

from test_service import _FakeMemory, _FakeRtt
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService


@pytest.fixture
def rig(tmp_path):
    events = []
    memory = _FakeMemory()
    service = BackendService(lambda name, payload: events.append((name, payload)),
                             recording_directory=tmp_path, memory_backend=memory,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt())
    # Advance the poll deadlines explicitly, without timing-sensitive sleeps.
    service._shutdown.set()
    service._wake.set()
    service._sampler.join(2)
    symbols = {name: SymbolInfo(name, 0x20000000 + i * 4, 4, 'uint32_t', '.data')
               for i, name in enumerate(('fast', 'watch', 'slow', 'manual'))}
    service._symbols = {s.key: s for s in symbols.values()}
    service.handle(RpcMethod.SET_WATCHES, {'watches': [
        {'key': symbols['fast'].key, 'readMode': 'capture'},
        {'key': symbols['watch'].key, 'readMode': 'monitor'},
        {'key': symbols['slow'].key, 'readMode': 'monitor', 'monitorRateHz': 0.5},
        {'key': symbols['manual'].key, 'readMode': 'manual'},
    ]})
    service._connection_status = 'connected'
    service._target_execution_state = 'running'
    try:
        yield service, memory, symbols, events
    finally:
        service.close()


def test_fast_reads_exclude_monitors_and_manual_variables(rig):
    service, memory, symbols, events = rig
    for _ in range(100):
        values = service._read_memory_locked(False, 'normal')
        assert set(values) == {symbols['fast'].key}
    assert set(memory.values) == {symbols['fast'].key}
    assert not any(name is EventName.WATCH_VALUES for name, _ in events)


def test_collapsed_monitors_stop_polling_without_changing_mode_or_capture(rig):
    service, memory, symbols, _ = rig
    hidden = symbols['watch'].key
    def configure(enabled):
        service.handle(RpcMethod.SET_WATCHES, {'watches': [
            {'key': w.symbol.key, 'readMode': w.mode,
             'monitorEnabled': enabled if w.symbol.key == hidden else True}
            for w in service._watches.values()]})
    configure(False)
    service._poll_monitors_locked(10)
    assert hidden not in memory.values
    assert service._watches[hidden].mode == 'monitor'
    assert symbols['fast'].key in service._read_memory_locked(False, 'normal')
    configure(True)
    service._poll_monitors_locked(11)
    assert hidden in memory.values
    assert service._recording.sample_count == 0


def test_monitor_cadence_and_overrides_continue_while_capture_is_paused(rig):
    service, memory, symbols, events = rig
    service.handle(RpcMethod.SET_SAMPLING_PAUSED, {'paused': True})
    service._poll_monitors_locked(10.0)
    assert service.state_snapshot()['monitorRateHz'] == 10.0
    service._poll_monitors_locked(10.09)
    assert memory.values[symbols['watch'].key] == 1
    assert memory.values[symbols['slow'].key] == 1
    service._poll_monitors_locked(10.1)
    assert memory.values[symbols['watch'].key] == 2
    assert memory.values[symbols['slow'].key] == 1
    service._poll_monitors_locked(12.0)
    assert memory.values[symbols['slow'].key] == 2
    assert symbols['manual'].key not in memory.values
    assert service._recording.sample_count == 0
    assert not any(name is EventName.SAMPLES for name, _ in events)


def test_manual_read_and_write_readback_do_not_record_samples(rig):
    service, memory, symbols, events = rig
    key = symbols['manual'].key
    result = service.handle(RpcMethod.READ_WATCH, {'key': key})
    assert result['values'][0]['value'] == 1
    assert result['values'][0]['updatedAtMs'] > 0
    service.handle(RpcMethod.WRITE_WATCH, {'key': key, 'value': '42'})
    assert service._watches[key].value == 42
    assert service._watches[key].mode == 'manual'
    assert service._recording.sample_count == 0
    assert not any(name is EventName.SAMPLES for name, _ in events)


def test_switch_preserves_captured_data_and_does_not_backfill_monitor_values(rig):
    service, memory, symbols, events = rig
    fast, monitor = symbols['fast'].key, symbols['watch'].key
    service._queue_samples_locked([(1, {fast: 10, monitor: 99})])
    service.handle(RpcMethod.SET_WATCHES, {'watches': [
        {'key': fast, 'readMode': 'monitor'},
        {'key': monitor, 'readMode': 'capture'},
    ]})
    service._queue_samples_locked([(2, {fast: 20, monitor: 100})])
    service._flush_pending_samples_locked()
    samples = [payload for name, payload in events if name is EventName.SAMPLES]
    assert all(batch['captureOnly'] for batch in samples)
    assert [frame['values'] for batch in samples for frame in batch['frames']] == [
        {fast: 10}, {monitor: 100}]
    assert service._recording.sample_count == 2


def test_hidden_plot_still_captures_and_does_not_restart_push_stream(rig):
    service, memory, symbols, events = rig
    key = symbols['fast'].key
    service.handle(RpcMethod.SET_WATCHES, {'watches': [
        {'key': w.symbol.key, 'readMode': w.mode, 'plotted': False,
         'monitorRateHz': w.monitor_rate_hz} for w in service._watches.values()]})
    assert service._watches[key].captures
    assert key in service._read_memory_locked(False, 'normal')


@pytest.mark.parametrize('rate', [0, -1, 0.1, 50, float('nan'), True])
def test_invalid_monitor_rates_are_rejected(rig, rate):
    service, *_ = rig
    with pytest.raises(ProtocolError):
        service.handle(RpcMethod.SET_CONFIG, {'monitorRateHz': rate})


def test_fixed_rtt_monitor_reads_latest_cached_frame_without_history(rig):
    service, memory, symbols, events = rig
    key = symbols['watch'].key
    service._rtt_enabled, service._rtt_protocol = True, 'plus'
    service._latest_rtt_values[key] = (123, 123456)
    service._poll_monitors_locked(10)
    assert key not in memory.values
    assert service._watches[key].value == 123
    assert service._watches[key].updated_at_ms == 123456
    assert service._recording.sample_count == 0


def test_old_push_cache_cannot_undo_write_readback(rig):
    service, memory, symbols, events = rig
    key = symbols['watch'].key
    service._rtt_enabled, service._rtt_protocol = True, 'plus'
    service._latest_rtt_values[key] = (1, 1)
    service.handle(RpcMethod.WRITE_WATCH, {'key': key, 'value': '42'})
    service._poll_monitors_locked(10)
    assert service._watches[key].value == 42
    service.handle(RpcMethod.READ_WATCH, {'key': key})
    assert service._watches[key].value == 43  # explicit reads reach readable memory
    assert service._recording.sample_count == 0


def test_halted_plus_monitor_reads_memory_instead_of_frozen_cache(rig):
    service, memory, symbols, events = rig
    key = symbols['watch'].key
    service._rtt_enabled, service._rtt_protocol = True, 'plus'
    service._target_execution_state = 'halted'
    service._latest_rtt_values[key] = (999, 1)
    service._poll_monitors_locked(10)
    assert service._watches[key].value == 1


def test_batch_write_acknowledges_only_after_readback_without_capture(rig):
    service, memory, symbols, events = rig
    entries = [{'key': symbols[name].key, 'value': '42'} for name in ('watch', 'manual')]
    events.clear()
    result = service.handle(RpcMethod.WRITE_WATCHES, {'writes': entries})
    assert [value['value'] for value in result['values']] == [42, 42]
    assert [value['key'] for value in result['values']] == [entry['key'] for entry in entries]
    assert service._recording.sample_count == 0
    assert [name for name, _ in events] == [EventName.WATCH_VALUES, EventName.LOG]
    assert service._controls_idle.is_set()


def test_batch_error_releases_command_priority_and_rejects_unknown_watch_before_writes(rig):
    service, memory, symbols, events = rig
    before = dict(memory.values)
    with pytest.raises(ProtocolError):
        service.handle(RpcMethod.WRITE_WATCHES, {'writes': [
            {'key': symbols['watch'].key, 'value': '42'}, {'key': 'missing', 'value': '1'}]})
    assert memory.values == before
    assert service._controls_idle.is_set()


def test_invalid_batch_value_cannot_partially_write_an_injected_adapter(rig):
    service, memory, symbols, _ = rig
    before = dict(memory.values)
    with pytest.raises(ProtocolError):
        service.handle(RpcMethod.WRITE_WATCHES, {'writes': [
            {'key': symbols['watch'].key, 'value': '42'},
            {'key': symbols['manual'].key, 'value': '999999999999999999999'}]})
    assert memory.values == before


def test_timestamped_capture_wire_payload_preserves_event_time():
    import struct
    from take_a_look_backend.protocol import encode_sample_batch
    payload = encode_sample_batch(7, 11, ['fast'], [(1.0, {'fast': 3})], updated_at_ms=123456)
    assert struct.unpack_from('<BIIIHQ', payload) == (2, 7, 11, 1, 1, 123456)
    assert struct.unpack_from('<dBd', payload, 23) == (1.0, 1, 3.0)

