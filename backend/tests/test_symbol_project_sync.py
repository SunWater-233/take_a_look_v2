from pathlib import Path
from unittest.mock import patch

import pytest

from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex
from take_a_look_backend.services.source_project import SourceProjects
from test_service import _FakeMemory, _FakeRtt
from test_source_tasks import wait_for


@pytest.fixture
def backend(tmp_path):
    events = []
    downloads = []
    memory = _FakeMemory()
    memory.program_firmware = lambda path, progress: downloads.append(Path(path).read_bytes())
    service = BackendService(
        lambda event, payload: events.append((event, payload)),
        memory_backend=memory, normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
        recording_directory=tmp_path / 'records', source_settings_file=tmp_path / 'settings.json',
        symbol_loader=lambda *a, **k: [], debug_info_loader=lambda *a, **k: DebugInfoIndex(),
    )
    try:
        yield service, events, downloads
    finally:
        service.close()


@pytest.mark.parametrize('selected_project', [False, True])
def test_loading_symbols_syncs_firmware_and_downloads_the_selected_file(tmp_path, backend, selected_project):
    service, events, downloads = backend
    firmware = tmp_path / 'selected.axf'
    firmware.write_bytes(b'selected firmware')
    if selected_project:
        service.handle(RpcMethod.SET_SOURCE_PROJECT, {
            'sourceRoot': str(tmp_path), 'firmwarePath': 'old.axf', 'buildCommand': 'build motor',
        })
    result = service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(firmware)})
    state = result['state']
    assert state['symbolFile'] == str(firmware)
    assert state['sourceProject']['firmwarePath'] == str(firmware)
    assert events[-1] == (EventName.STATE, state)
    if selected_project:
        assert state['sourceProject']['buildCommand'] == 'build motor'
        restored = SourceProjects(tmp_path / 'settings.json')
        assert restored.select({'sourceRoot': str(tmp_path)})['firmwarePath'] == str(firmware)
    else:
        assert state['sourceProject']['sourceRoot'] == ''
        assert not (tmp_path / 'settings.json').exists()
        selected = service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(tmp_path)})
        assert selected['state']['sourceProject']['firmwarePath'] == str(firmware)

    service.handle(RpcMethod.CONNECT, {})
    service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
    wait_for(lambda: not service._source_tasks.running)
    assert service._source_tasks.snapshot()['status'] == 'succeeded'
    assert downloads == [b'selected firmware']
    assert service.state_snapshot()['sourceProject']['firmwarePath'] == str(firmware)


def test_refresh_and_download_preserve_equivalent_relative_firmware_path(tmp_path, backend):
    service, _, downloads = backend
    firmware = tmp_path / 'build' / 'motor.axf'
    firmware.parent.mkdir()
    firmware.write_bytes(b'firmware')
    configured = 'build/../build/motor.axf'
    service.handle(RpcMethod.SET_SOURCE_PROJECT, {
        'sourceRoot': str(tmp_path), 'firmwarePath': configured,
    })
    settings = (tmp_path / 'settings.json').read_bytes()
    for _ in range(2):
        result = service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(firmware)})
        assert result['state']['sourceProject']['firmwarePath'] == configured
    service.handle(RpcMethod.CONNECT, {})
    service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
    wait_for(lambda: not service._source_tasks.running)
    assert service._source_tasks.snapshot()['status'] == 'succeeded'
    assert downloads == [b'firmware']
    assert service.state_snapshot()['symbolFile'] == str(firmware)
    assert service.state_snapshot()['sourceProject']['firmwarePath'] == configured
    assert (tmp_path / 'settings.json').read_bytes() == settings


@pytest.mark.parametrize('failure', ['parse', 'save'])
def test_failed_load_keeps_previous_symbol_and_project_paths(tmp_path, backend, failure):
    service, _, _ = backend
    previous, replacement = tmp_path / 'previous.axf', tmp_path / 'replacement.axf'
    previous.touch()
    replacement.touch()
    service.handle(RpcMethod.SET_SOURCE_PROJECT, {
        'sourceRoot': str(tmp_path), 'firmwarePath': str(previous),
    })
    service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(previous)})
    settings = (tmp_path / 'settings.json').read_bytes()
    before = service.state_snapshot()
    if failure == 'parse':
        # The injected loader fails before any new configuration is committed.
        error = ProtocolError('symbol_load_failed', 'invalid ELF')
        fail = patch.object(service, '_symbol_loader', side_effect=error)
    else:
        error = OSError('settings are read-only')
        fail = patch('take_a_look_backend.services.source_project.os.replace', side_effect=error)
    with fail:
        with pytest.raises(type(error)):
            service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(replacement)})
    after = service.state_snapshot()
    for key in ('symbolFile', 'sourceProject', 'symbols', 'watches', 'debug'):
        assert after[key] == before[key]
    assert (tmp_path / 'settings.json').read_bytes() == settings
