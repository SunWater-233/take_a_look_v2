from pathlib import Path
from unittest.mock import patch

import pytest

from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex
from test_service import _FakeMemory, _FakeRtt
from test_source_tasks import wait_for, python_command


@pytest.fixture
def backend(tmp_path):
    events, downloads = [], []
    memory = _FakeMemory()
    memory.program_firmware = lambda path, progress: downloads.append(Path(path).read_bytes())
    def symbols(path, **_):
        return [SymbolInfo('counter', 0x20000000 + len(path.read_bytes()), 4, 'int32_t', '.data', 'main.c')]
    service = BackendService(lambda event, payload: events.append((event, payload)),
        memory_backend=memory, normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
        recording_directory=tmp_path / 'records', symbol_loader=symbols,
        debug_info_loader=lambda *a, **k: DebugInfoIndex())
    try:
        yield service, events, downloads
    finally:
        service.close()


def test_one_path_for_settings_symbols_and_download_without_a_source_root(tmp_path, backend):
    service, events, downloads = backend
    firmware = tmp_path / 'selected.axf'
    firmware.write_bytes(b'firmware')
    state = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
    assert 'symbolFile' not in state
    assert state['sourceProject']['firmwarePath'] == str(firmware)
    assert state['firmware']['status'] == 'ready'
    assert events[-1] == (EventName.STATE, state)
    service.handle(RpcMethod.CONNECT, {})
    service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
    wait_for(lambda: not service._source_tasks.running)
    assert service._source_tasks.snapshot()['status'] == 'succeeded'
    assert downloads == [b'firmware']
    assert service.state_snapshot()['sourceProject']['firmwarePath'] == str(firmware)


def test_root_change_keeps_the_explicit_absolute_firmware(tmp_path, backend):
    service, _, _ = backend
    a, b = tmp_path / 'A', tmp_path / 'B'
    a.mkdir(); b.mkdir()
    firmware = a / 'motor.axf'
    firmware.write_bytes(b'firmware')
    before = service.handle(RpcMethod.SET_SOURCE_PROJECT, {
        'sourceRoot': str(a), 'firmwarePath': './build/../motor.axf', 'buildCommand': 'build A',
    })['state']
    assert before['sourceProject']['firmwarePath'] == str(firmware)
    after = service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(b)})['state']
    assert after['sourceProject']['firmwarePath'] == str(firmware)
    assert after['sourceProject']['buildCommand'] == 'build A'
    assert after['firmware'] == before['firmware']
    assert after['symbols'] == before['symbols']


@pytest.mark.parametrize('method', [RpcMethod.LOAD_FIRMWARE, RpcMethod.SET_SOURCE_PROJECT])
def test_failed_parse_commits_no_configuration_or_derived_state(tmp_path, backend, method):
    service, _, _ = backend
    a, b = tmp_path / 'a.axf', tmp_path / 'b.axf'
    a.write_bytes(b'A'); b.write_bytes(b'B')
    service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(a)})
    before = service.state_snapshot()
    with patch.object(service, '_symbol_loader', side_effect=ProtocolError('symbol_load_failed', 'invalid ELF')):
        with pytest.raises(ProtocolError):
            service.handle(method, {'path': str(b)} if method is RpcMethod.LOAD_FIRMWARE else
                           {'sourceRoot': str(tmp_path), 'firmwarePath': str(b), 'buildCommand': 'new command'})
    after = service.state_snapshot()
    for key in ('sourceProject', 'firmware', 'symbols', 'watches', 'debug'):
        assert after[key] == before[key]


@pytest.mark.parametrize('path', ['not-built-yet.axf', ''])
def test_missing_or_cleared_selection_cannot_retain_previous_symbols(tmp_path, backend, path):
    service, _, _ = backend
    previous = tmp_path / 'previous.axf'
    previous.write_bytes(b'previous')
    service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(previous)})
    symbol = next(iter(service._symbols.values()))
    service._watches = {symbol.key: WatchedVariable(symbol, '#ff0000', True, True)}
    state = service.handle(RpcMethod.SET_SOURCE_PROJECT, {
        'sourceRoot': str(tmp_path), 'firmwarePath': path,
    })['state']
    assert state['sourceProject']['firmwarePath'] == (str(tmp_path / path) if path else '')
    assert state['firmware']['status'] == ('missing' if path else 'empty')
    assert state['symbols'] == state['watches'] == []
    assert state['debug']['sourceFiles'] == []
    assert state['firmware']['fingerprint'] == ''


def test_same_path_rebuild_refreshes_identity_and_rebinds_watch_addresses(tmp_path, backend):
    service, _, _ = backend
    firmware = tmp_path / 'motor.elf'
    firmware.write_bytes(b'A')
    first = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
    symbol = next(iter(service._symbols.values()))
    service._watches = {symbol.key: WatchedVariable(symbol, '#ff0000', True, True)}
    firmware.write_bytes(b'new build')
    second = service.handle(RpcMethod.SET_SOURCE_PROJECT, {'firmwarePath': str(firmware)})['state']
    assert second['firmware']['fingerprint'] != first['firmware']['fingerprint']
    assert second['firmware']['revision'] > first['firmware']['revision']
    assert next(iter(service._watches.values())).symbol.address == 0x20000009


def test_build_marks_symbols_stale_without_changing_target_addresses(tmp_path, backend):
    service, _, _ = backend
    firmware = tmp_path / 'motor.elf'
    firmware.write_bytes(b'A')
    before = service.handle(RpcMethod.SET_SOURCE_PROJECT, {
        'sourceRoot': str(tmp_path), 'firmwarePath': 'motor.elf',
        'buildCommand': python_command('from pathlib import Path; Path("motor.elf").write_bytes(b"new build")'),
    })['state']
    service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'build'})
    wait_for(lambda: not service._source_tasks.running)
    assert service._source_tasks.snapshot()['status'] == 'succeeded'
    after = service.state_snapshot()
    assert after['firmware']['status'] == 'stale'
    assert after['symbols'] == before['symbols']
    refreshed = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
    assert refreshed['firmware']['status'] == 'ready'
    assert refreshed['firmware']['fingerprint'] != before['firmware']['fingerprint']


def test_download_parses_staged_bytes_before_programming(tmp_path, backend):
    service, _, downloads = backend
    firmware = tmp_path / 'motor.axf'
    firmware.write_bytes(b'firmware')
    service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
    service.handle(RpcMethod.CONNECT, {})
    with patch.object(service, '_symbol_loader', side_effect=ProtocolError('symbol_load_failed', 'invalid ELF')):
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        wait_for(lambda: not service._source_tasks.running)
    assert service._source_tasks.snapshot()['status'] == 'failed'
    assert downloads == []


def test_file_changes_during_parse_never_publish_mixed_metadata(tmp_path, backend):
    service, _, _ = backend
    firmware = tmp_path / 'motor.axf'
    firmware.write_bytes(b'first build')
    def changed(path, **_):
        path.write_bytes(b'second build')
        return []
    before = service.state_snapshot()
    with patch.object(service, '_symbol_loader', side_effect=changed):
        with pytest.raises(ProtocolError) as error:
            service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
    assert error.value.code == 'firmware_changed'
    assert service.state_snapshot()['firmware'] == before['firmware']
    assert service.state_snapshot()['sourceProject'] == before['sourceProject']
