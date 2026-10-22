from __future__ import annotations

import hashlib
import time
from pathlib import Path
import base64

import pytest

from take_a_look_backend.backends import remote_firmware
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from test_firmware_download import firmware
from test_ember_pairing import phone_factory  # Real Ember Rust QUIC fixture.
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.services.debug_info import DebugInfoIndex
from test_ember_remote import Phone, phone_server


def test_legacy_ember_upload_uses_bounded_chunks_and_the_same_flash_lifecycle(tmp_path):
    class LegacyPhone(Phone):
        def __init__(self):
            super().__init__()
            self.uploaded = bytearray()
            self.chunks = []
            self.flash = None

        def dispatch(self, request):
            method, params = request['method'], request['params']
            if method == 'firmware_begin':
                self.expected = params
                result = {'id': 3}
            elif method == 'firmware_chunk':
                data = base64.b64decode(params['data'])
                assert params['offset'] == len(self.uploaded) and 0 < len(data) <= 4096
                self.chunks.append(data)
                self.uploaded.extend(data)
                result = {'received': len(self.uploaded)}
            elif method == 'firmware_finish':
                digest = hashlib.sha256(self.uploaded).hexdigest()
                assert digest == self.expected['sha256'] and len(self.uploaded) == self.expected['size']
                result = {'ready': True, 'sha256': digest}
            elif method == 'flash':
                self.flash = params
                result = {'job_id': 9}
            elif method == 'backend_state' and self.flash:
                result = {'flash': {'id': 9, 'state': 'succeeded'}}
            else:
                return super().dispatch(request)
            return {'ok': True, 'result': result}

    path = firmware(tmp_path / 'legacy.axf', [(0x08000000, bytes(range(256)) * 40)])
    phone = LegacyPhone()
    with phone_server(phone) as options:
        backend = RemoteMemoryBackend('ember', options)
        try:
            backend.connect()
            progress = []
            backend.program_firmware(path, progress.append)
            assert len(phone.chunks) >= 3 and phone.flash['run_after'] is False
            assert backend.client.protocol_version == 1 and progress[-1] == 1
        finally:
            backend.disconnect()


@pytest.mark.parametrize('fails', [False, True])
def test_source_download_over_real_ember_quic_reloads_symbols_only_after_flash(phone_factory, tmp_path, fails):
    phone = phone_factory()
    if fails:
        phone.local('fail_flash')
    path = firmware(tmp_path / 'motor.axf', [(0x08000000, bytes(range(256)) * 400)])
    old = SymbolInfo('counter', 0x20000000, 4, 'uint32_t', '.data', 'app.c')
    new = SymbolInfo('counter', 0x20000040, 4, 'uint32_t', '.data', 'app.c')
    service = BackendService(lambda *_: None, recording_directory=tmp_path / 'recordings',
        symbol_loader=lambda *_, **__: [new], debug_info_loader=lambda *_, **__: DebugInfoIndex())
    try:
        service.handle(RpcMethod.CONNECT, {'connectionKind': 'ember', 'remoteConfig': {
            'host': '127.0.0.1', 'gatewayPort': str(phone.info['tcp_port']), 'token': phone.info['token']}})
        service._sampling_paused = True
        service._symbols = {old.key: old}
        service._watches = {old.key: WatchedVariable(old, '#123456')}
        service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(tmp_path), 'firmwarePath': str(path), 'afterDownload': 'run'})
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        deadline = time.monotonic() + 10
        while service._source_tasks.running and time.monotonic() < deadline:
            time.sleep(.02)
        result = service._source_tasks.snapshot()
        state = phone.local('backend')
        if fails:
            assert result['status'] == 'failed', result
            assert old.key in service._watches and not service._rtt_enabled
            assert state['resets'] == state['resumes'] == 0
        else:
            assert result['status'] == 'succeeded', result
            assert service._watches[new.key].color == '#123456'
            assert service._symbol_file == str(path)
            assert state['resets'] == state['resumes'] == 1
        assert state['firmware']['received'] == Path(path).stat().st_size
        assert state['firmware']['sha256'] == hashlib.sha256(Path(path).read_bytes()).hexdigest()
    finally:
        service.close()


class FlashPhone:
    def __init__(self, states=None):
        self.calls = []
        self.uploaded = None
        self.states = iter(states or [{"id": 9, "state": "succeeded"}])
        self.upload_error = False
        self.ready = True
        self.submission_error = False

    def call(self, method, params=None):
        self.calls.append((method, params))
        if method == "firmware_begin":
            self.expected = params
            return {"id": 3}
        if method == "firmware_finish":
            return {"ready": self.ready, "sha256": hashlib.sha256(self.uploaded).hexdigest()}
        if method == "flash":
            if self.submission_error:
                raise ConnectionError("result unknown")
            return {"job_id": 9}
        if method == "backend_state":
            return {"flash": next(self.states)}
        if method == "firmware_abort":
            return {}
        raise AssertionError(method)

    def upload_bytes(self, upload_id, data, *, progress):
        assert upload_id == 3
        if self.upload_error:
            raise ConnectionError("upload interrupted")
        self.uploaded = data
        progress(1)
        return {"received": len(data)}


def test_phone_flash_waits_for_verified_completion_and_progress_never_regresses(tmp_path, monkeypatch):
    path = firmware(tmp_path / 'motor.axf', [(0x08000000, b'\x11\x22\x33\x44')])
    client = FlashPhone([
        {"id": 9, "state": "running", "stage": "erase", "done": 8, "total": 8},
        {"id": 9, "state": "running", "stage": "program", "done": 16, "total": 16},
        {"id": 9, "state": "running", "stage": "verify", "done": 1, "total": 16},
        {"id": 9, "state": "succeeded"},
    ])
    backend = RemoteMemoryBackend('ember', {})
    backend.client, backend.ember, backend.target = client, type('Target', (), {'session_id': 7})(), object()
    monkeypatch.setattr(remote_firmware.time, 'sleep', lambda _: None)
    progress = []
    backend.program_firmware(path, progress.append)
    assert client.expected['sha256'] == hashlib.sha256(client.uploaded).hexdigest()
    assert client.expected['size'] == len(client.uploaded)
    assert next(p for m, p in client.calls if m == 'flash') == {
        'session_id': 7, 'firmware_id': 3, 'format': 'elf', 'run_after': False,
    }
    assert progress == sorted(progress) and progress[-1] == 1
    assert len([m for m, _ in client.calls if m == 'backend_state']) == 4


@pytest.mark.parametrize('case,code', [
    ('failed', 'firmware_flash_failed'), ('replaced', 'firmware_job_changed'), ('timeout', 'firmware_flash_timeout'),
])
def test_unconfirmed_phone_flash_never_reports_success(case, code, tmp_path, monkeypatch):
    data, _ = remote_firmware.firmware_image(firmware(tmp_path / 'app.elf', [(0x08000000, b'1234')]))
    state = {'id': 9, 'state': 'failed', 'error': 'readback mismatch'} if case == 'failed' else {
        'id': 10 if case == 'replaced' else 9, 'state': 'running'}
    client = FlashPhone([state])
    if case == 'timeout':
        monkeypatch.setattr(remote_firmware, 'FLASH_TIMEOUT', 0)
    progress = []
    with pytest.raises(ProtocolError) as error:
        remote_firmware.flash_phone(client, 1, 'app.elf', data, progress.append)
    assert error.value.code == code
    assert 1 not in progress
    assert not any(m == 'firmware_abort' for m, _ in client.calls)


@pytest.mark.parametrize('case', ['upload', 'checksum', 'submission'])
def test_upload_failures_abort_staging_but_never_replay_flash(case):
    client = FlashPhone()
    client.upload_error, client.ready, client.submission_error = case == 'upload', case != 'checksum', case == 'submission'
    with pytest.raises((ProtocolError, ConnectionError)):
        remote_firmware.flash_phone(client, 1, 'app.elf', b'firmware', lambda _: None)
    methods = [m for m, _ in client.calls]
    assert ('firmware_abort' in methods) == (case != 'submission')
    assert methods.count('flash') == (1 if case == 'submission' else 0)


@pytest.mark.parametrize('case', ['empty', 'truncated', 'non_arm', 'no_segments'])
def test_bad_firmware_is_rejected_before_upload(tmp_path, case):
    path = tmp_path / 'app.elf'
    if case in {'empty', 'truncated'}:
        path.write_bytes(b'' if case == 'empty' else b'\x7fELF')
    else:
        firmware(path, [] if case == 'no_segments' else [(0x08000000, b'1234')], machine=62 if case == 'non_arm' else 40)
    backend = RemoteMemoryBackend('ember', {})
    backend.target = object()
    backend.client = FlashPhone()
    with pytest.raises(ProtocolError):
        backend.program_firmware(str(path), lambda _: None)
    assert not backend.client.calls


@pytest.mark.parametrize('kind', ['ember', 'emberGdb'])
def test_remote_download_still_requires_a_connected_target(kind, tmp_path):
    service = BackendService(lambda *_: None, recording_directory=tmp_path)
    try:
        service._connection_kind = kind
        with pytest.raises(ProtocolError) as error:
            service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        assert error.value.code == 'not_connected'
    finally:
        service.close()
