"""Check an app bundle as delivered, without development Python or Homebrew paths."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

MACHO_MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
               b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}


def macho_files(root: Path):
    for path in root.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    yield path


def command(*arguments, **kwargs):
    return subprocess.check_output(list(map(str, arguments)), text=True, timeout=60, **kwargs)


def verify_app(app: Path, architecture: str, version: str, mode: str) -> None:
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    core, _, number = version.partition('+')
    assert info['CFBundleShortVersionString'] == core, info
    assert str(info['CFBundleVersion']) == (number or '0'), info
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    expected_arch = 'arm64' if architecture == 'arm64' else 'x86_64'
    assert command('lipo', '-archs', executable).strip().split() == [expected_arch]
    command('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    backend = app / 'Contents/Resources/backend/runtime/take_a_look_backend/take_a_look_backend'
    assert command('lipo', '-archs', backend).strip().split() == [expected_arch]
    manifest = json.loads((app / 'Contents/Resources/BUILD-INFO.json').read_text())
    assert (manifest['version'], manifest['build_mode'], manifest['architecture']) == (version, mode, architecture)
    for binary in macho_files(app):
        dependencies = command('otool', '-L', binary).splitlines()[1:]
        for dependency in dependencies:
            dependency = dependency.strip().split(' (', 1)[0]
            if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise ValueError(f'Unbundled absolute library dependency: {binary}: {dependency}')
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith(('DYLD_', 'PYTHON', 'TAKE_A_LOOK_'))
                   and name not in ('VIRTUAL_ENV', 'TAL_PARENT_PID', 'TAL_RECORDINGS_DIR')}
    environment['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    with tempfile.TemporaryDirectory(prefix='tal mac offline 中文 ') as directory:
        environment['HOME'] = directory
        environment['TAL_RECORDINGS_DIR'] = str(Path(directory) / 'recordings')
        report = json.loads(command(backend, '--self-test', env=environment, cwd=directory))
        assert report['ok'] and report['checks']['rpc'] == 'ok', report
        requests = '\n'.join(json.dumps({'v': 2, 'id': index, 'method': method, 'params': {}})
                             for index, method in enumerate(('handshake', 'getState', 'shutdown'), 1)) + '\n'
        responses = command(backend, input=requests, env=environment, cwd=directory)
        replies = {row['id']: row for line in responses.splitlines() if 'id' in (row := json.loads(line))}
        assert replies[1]['result']['protocolVersion'] == 2, replies
        assert replies[2]['result']['state']['connectionStatus'] == 'disconnected', replies
        assert 'error' not in replies[3], replies
    print(f'Verified macOS {architecture} {mode}: signed app, version, native backend, relocation and offline RPC.', flush=True)
