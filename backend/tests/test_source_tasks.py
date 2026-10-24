from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import sys
import threading
import time
from unittest.mock import patch

import pytest
import psutil

from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.debug_info import DebugInfoIndex
from take_a_look_backend.services.source_project import SourceProjects, default_config, firmware_file
from take_a_look_backend.services.source_tasks import SourceTasks, shell_command
from test_service import _FakeMemory, _FakeRtt


def python_command(code):
    if os.name == 'nt':
        return "& '" + sys.executable.replace("'", "''") + "' -c '" + code.replace("'", "''") + "'"
    return shlex.join([sys.executable, '-c', code])


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    assert predicate(), 'Timed out waiting for source task'


def config(root, command):
    return {**default_config(str(root)), 'buildCommand': python_command(command), 'firmwarePath': 'build/motor.elf'}


def test_profiles_restore_by_full_project_root_without_executing(tmp_path):
    roots = [tmp_path / 'A' / 'same-name', tmp_path / 'B' / 'same-name']
    for root in roots:
        root.mkdir(parents=True)
    file = tmp_path / 'settings.json'
    projects = SourceProjects(file)
    projects.select({'sourceRoot': str(roots[0]), 'buildCommand': 'project A'})
    projects.select({'sourceRoot': str(roots[1]), 'buildCommand': 'project B'})
    assert projects.select({'sourceRoot': str(roots[0])})['buildCommand'] == 'project A'
    restored = SourceProjects(file)
    assert restored.current == default_config()
    assert restored.select({'sourceRoot': str(roots[1])})['buildCommand'] == 'project B'
    with pytest.raises(ProtocolError):
        restored.select({'sourceRoot': str(tmp_path / 'missing')})
    assert restored.current['buildCommand'] == 'project B'
    assert SourceProjects(file).current == default_config()
    saved = json.loads(file.read_text(encoding='utf-8'))
    assert 'lastRoot' not in saved['platforms'][projects.platform]


@pytest.mark.parametrize('legacy_layout', [False, True])
@pytest.mark.parametrize('root_exists', [False, True])
def test_startup_ignores_saved_last_root_but_keeps_project_profiles(tmp_path, legacy_layout, root_exists):
    root = tmp_path / 'project'
    if root_exists:
        root.mkdir()
    file = tmp_path / 'settings.json'
    projects = SourceProjects(file)
    key = os.path.normcase(str(root.resolve()))
    profile = {**default_config(str(root)), 'buildCommand': 'saved build command'}
    local = {'lastRoot': key, 'projects': {key: profile}}
    data = ({'version': 1, 'platform': projects.platform, **local} if legacy_layout else
            {'version': 1, 'platforms': {projects.platform: local}})
    original = json.dumps(data)
    file.write_text(original, encoding='utf-8')

    restored = SourceProjects(file)
    assert restored.snapshot()['sourceRoot'] == ''
    assert restored.current == default_config()
    assert file.read_text(encoding='utf-8') == original
    if root_exists:
        assert restored.select({'sourceRoot': str(root)})['buildCommand'] == 'saved build command'


def test_platform_defaults_and_shell_arguments(tmp_path):
    with patch('take_a_look_backend.services.source_project.shutil.which', side_effect=lambda name: '/bin/' + name):
        assert default_config(platform='windows')['shell'] == 'powershell'
        assert default_config(platform='macos')['shell'] == 'zsh'
        assert default_config(platform='linux')['shell'] == 'bash'
    for shell in ['zsh', 'bash', 'sh']:
        with patch('take_a_look_backend.services.source_tasks.shell_options', return_value=[{'id': shell, 'available': True, 'executable': '/bin/' + shell}]):
            command = 'printf "%s" "a b"'
            args = shell_command({'shell': shell, 'buildCommand': command}, tmp_path)
            assert args[-2:] == ['-c', command]
            assert args[0] == '/bin/' + shell
    with patch('take_a_look_backend.services.source_tasks.shell_options', return_value=[]):
        with pytest.raises(ProtocolError):
            shell_command({'shell': 'powershell', 'buildCommand': 'echo x'}, tmp_path)


def test_build_cwd_unicode_and_output_and_failure_gate(tmp_path):
    root = tmp_path / '源码 空格 & project'
    root.mkdir()
    downloads = []
    task = SourceTasks(lambda _: None, lambda *args: downloads.append(args))
    try:
        task.start('build', config(root, 'import os,sys; print(os.getcwd()); print("中文输出"); sys.stderr.write("warning only\\n")'))
        wait_for(lambda: not task.running)
        result = task.snapshot()
        assert result['status'] == 'succeeded', result
        output = '\n'.join(line['text'] for line in result['lines'])
        assert str(root) in output and '中文输出' in output
        (root / 'build').mkdir()
        (root / 'build/motor.elf').write_bytes(b'old firmware')
        task.start('buildAndDownload', config(root, 'import sys; sys.exit(7)'))
        wait_for(lambda: not task.running)
        assert task.snapshot()['exitCode'] == 7
        assert task.snapshot()['status'] == 'failed'
        assert downloads == []
    finally:
        task.close()


def test_cancellation_kills_grandchild_and_never_downloads(tmp_path):
    pid_file = tmp_path / 'child.pid'
    code = ('import subprocess,sys,pathlib,time; '
            'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); '
            'pathlib.Path(' + repr(str(pid_file)) + ').write_text(str(p.pid)); time.sleep(30)')
    downloads = []
    task = SourceTasks(lambda _: None, lambda *args: downloads.append(args))
    try:
        task.start('buildAndDownload', config(tmp_path, code))
        wait_for(pid_file.exists)
        pid = int(pid_file.read_text())
        task.cancel()
        wait_for(lambda: not task.running)
        wait_for(lambda: not psutil.pid_exists(pid) or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE)
        assert task.snapshot()['status'] == 'cancelled'
        assert downloads == []
    finally:
        task.close()


def test_output_is_bounded(tmp_path):
    task = SourceTasks(lambda _: None, lambda *_: None)
    for _ in range(2000):
        task.log('x' * 3000)
    result = task.snapshot()
    assert len(result['lines']) <= 1000
    assert sum(len(line['text']) for line in result['lines']) <= 256 * 1024
    task.close()


@pytest.mark.skipif(os.name != 'nt', reason='Windows compatibility shell')
def test_cmd_and_powershell_errors(tmp_path):
    task = SourceTasks(lambda _: None, lambda *_: None)
    try:
        values = {**default_config(str(tmp_path)), 'shell': 'cmd', 'buildCommand': 'echo CMD_OK'}
        task.start('build', values)
        wait_for(lambda: not task.running)
        assert task.snapshot()['status'] == 'succeeded', task.snapshot()
        values['buildCommand'] = 'echo CMD_OK & exit /b 9'
        task.start('build', values)
        wait_for(lambda: not task.running)
        assert task.snapshot()['exitCode'] == 9, task.snapshot()
        values.update(shell='powershell', buildCommand='Write-Error "bad command"')
        task.start('build', values)
        wait_for(lambda: not task.running)
        assert task.snapshot()['status'] == 'failed'
    finally:
        task.close()


def test_successful_build_stages_exact_firmware_for_download(tmp_path):
    received = []
    def download(staged, original, _config, _task):
        assert staged.read_bytes() == b'new firmware'
        assert original == tmp_path / 'build/motor.elf'
        original.write_bytes(b'changed externally')
        assert staged.read_bytes() == b'new firmware'
        received.append(str(staged))
    task = SourceTasks(lambda _: None, download)
    try:
        task.start('buildAndDownload', config(tmp_path, 'from pathlib import Path; Path("build").mkdir(); Path("build/motor.elf").write_bytes(b"new firmware")'))
        wait_for(lambda: not task.running)
        assert task.snapshot()['status'] == 'succeeded', task.snapshot()
        assert len(received) == 1 and not Path(received[0]).exists()
    finally:
        task.close()


@pytest.mark.parametrize('fails', [False, True])
def test_flash_reserves_probe_keeps_rpc_responsive_and_rebinds_symbols(tmp_path, fails):
    entered, release = threading.Event(), threading.Event()
    memory = _FakeMemory()
    def program(path, progress):
        assert Path(path).read_bytes() == b'firmware'
        entered.set()
        assert release.wait(5)
        if fails:
            raise RuntimeError('probe unplugged')
        progress(1)
    memory.program_firmware = program
    old = SymbolInfo('speed', 0x20000000, 4, 'float', '.data', 'motor.c')
    new = SymbolInfo('speed', 0x20000040, 4, 'float', '.data', 'motor.c')
    service = BackendService(lambda *_: None, memory_backend=memory, normal_rtt_backend=_FakeRtt(),
        plus_rtt_backend=_FakeRtt(), recording_directory=tmp_path / 'records',
        symbol_loader=lambda *a, **k: [new], debug_info_loader=lambda *a, **k: DebugInfoIndex())
    firmware = tmp_path / 'motor.elf'
    firmware.write_bytes(b'firmware')
    try:
        service.handle(RpcMethod.CONNECT, {})
        service._symbols = {old.key: old}
        service._watches = {old.key: WatchedVariable(old, '#123456')}
        service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(tmp_path), 'firmwarePath': 'motor.elf'})
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        assert entered.wait(2)
        before = time.monotonic()
        service.handle(RpcMethod.GET_STATE, {})
        assert time.monotonic() - before < .5
        with pytest.raises(ProtocolError):
            service.handle(RpcMethod.DEBUG_CONTROL, {'action': 'resume'})
        with pytest.raises(ProtocolError):
            service.handle(RpcMethod.CANCEL_SOURCE_TASK, {})
        release.set()
        wait_for(lambda: not service._source_tasks.running)
        if fails:
            assert service._source_tasks.snapshot()['status'] == 'failed'
            assert service._sampling_paused and not service._rtt_enabled
            assert old.key in service._watches
        else:
            assert service._source_tasks.snapshot()['status'] == 'succeeded', service._source_tasks.snapshot()
            assert service._watches[new.key].symbol.address == new.address
            assert service._watches[new.key].color == '#123456'
            assert service._symbol_file == str(firmware)
            assert memory.reset_calls == [True]
    finally:
        release.set()
        service.close()


@pytest.mark.parametrize('configured', [False, True])
@pytest.mark.parametrize('root', ['', 'missing-source-root'])
def test_download_uses_loaded_elf_without_source_settings_and_prefers_explicit_firmware(tmp_path, configured, root):
    loaded = tmp_path / 'loaded.elf'
    explicit = tmp_path / 'configured.axf'
    loaded.write_bytes(b'loaded firmware')
    explicit.write_bytes(b'configured firmware')
    downloads = []
    memory = _FakeMemory()
    memory.program_firmware = lambda path, progress: downloads.append(Path(path).read_bytes())
    service = BackendService(lambda *_: None, memory_backend=memory,
        normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
        recording_directory=tmp_path / 'records', symbol_loader=lambda *a, **k: [],
        debug_info_loader=lambda *a, **k: DebugInfoIndex())
    try:
        service.handle(RpcMethod.CONNECT, {})
        service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(loaded)})
        service._source_projects.current.update(sourceRoot=root,
            firmwarePath=str(explicit) if configured else '')
        original_config = dict(service._source_projects.current)
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        wait_for(lambda: not service._source_tasks.running)
        assert service._source_tasks.snapshot()['status'] == 'succeeded', service._source_tasks.snapshot()
        assert downloads == [b'configured firmware' if configured else b'loaded firmware']
        assert service._symbol_file == str(explicit if configured else loaded)
        assert service._source_projects.current == {
            **original_config, 'firmwarePath': str(explicit if configured else loaded),
        }
    finally:
        service.close()


def test_download_fallback_requires_an_existing_selected_elf(tmp_path):
    service = BackendService(lambda *_: None, recording_directory=tmp_path / 'records',
        symbol_loader=lambda *a, **k: [], debug_info_loader=lambda *a, **k: DebugInfoIndex())
    try:
        service._connection_status = 'connected'
        with pytest.raises(ProtocolError) as error:
            service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        assert error.value.code == 'firmware_required'
        selected = tmp_path / 'selected.elf'
        selected.write_bytes(b'firmware')
        service.handle(RpcMethod.LOAD_SYMBOLS, {'path': str(selected)})
        selected.unlink()
        with pytest.raises(ProtocolError) as error:
            service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        assert error.value.code == 'firmware_missing'
        assert not service._source_tasks.running
    finally:
        service.close()


@pytest.mark.parametrize('kind', ['build', 'buildAndDownload'])
def test_build_still_requires_a_source_root(tmp_path, kind):
    task = SourceTasks(lambda _: None, lambda *_: None)
    try:
        with pytest.raises(ProtocolError) as error:
            task.start(kind, {**default_config(), 'buildCommand': 'echo build',
                              'firmwarePath': str(tmp_path / 'motor.elf')})
        assert error.value.code == 'source_root_required'
        assert not task.running
    finally:
        task.close()


def test_relative_firmware_still_requires_a_source_root():
    with pytest.raises(ProtocolError) as error:
        firmware_file({**default_config(), 'firmwarePath': 'motor.elf'})
    assert error.value.code == 'source_root_required'


def test_missing_firmware_and_remote_download_are_explicit(tmp_path):
    with pytest.raises(ProtocolError):
        firmware_file({**default_config(str(tmp_path)), 'firmwarePath': 'missing.elf'})
    service = BackendService(lambda *_: None, recording_directory=tmp_path / 'records')
    try:
        service._connection_kind = 'gdb'
        with pytest.raises(ProtocolError) as error:
            service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        assert error.value.code == 'download_unsupported'
    finally:
        service.close()
