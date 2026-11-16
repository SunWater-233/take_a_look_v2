import hashlib
import os
import shutil
import subprocess
from unittest.mock import Mock, patch

import pytest

from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.elf_context import ElfLoadContext
from take_a_look_backend.services.symbols import SymbolCandidate, load_symbols_from_elf
from test_service import _FakeMemory, _FakeRtt


@pytest.fixture
def loading(tmp_path, monkeypatch):
    # Use the real parser orchestration with a tiny ELF adapter; no toolchain
    # or probe is needed to check content identity and cache invalidation.
    def elf_file(stream):
        data = stream.read()
        elf = Mock()
        elf.has_dwarf_info.return_value = False
        elf.address = 0x20000000 + data[0]
        return elf
    monkeypatch.setattr('elftools.elf.elffile.ELFFile', elf_file)
    candidates = Mock(side_effect=lambda elf: [SymbolCandidate('counter', 'int', elf.address, 4, '.data')])
    monkeypatch.setattr('take_a_look_backend.services.symbols.symbol_candidates_from_elf', candidates)
    path = tmp_path/'firmware.axf'
    path.write_bytes(b'A version')
    service = BackendService(lambda *_: None, recording_directory=tmp_path/'records')
    try:
        yield service, path, candidates
    finally:
        service.close()


def load(service, path, **kwargs):
    display_path = kwargs.get('display_path')
    if display_path is None:
        return service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(path)})['state']
    with service._firmware_lock:
        image = service._parse_firmware(path)
        with service._lock:
            service._commit_firmware({**service._source_project, 'firmwarePath': str(display_path)}, image)
            return service.state_snapshot()


def test_same_image_at_new_staging_path_reuses_parsed_results(loading, tmp_path):
    service, path, candidates = loading
    first = load(service, path)
    staged = tmp_path/'staging'/'firmware.axf'
    staged.parent.mkdir()
    shutil.copyfile(path, staged)
    second = load(service, staged, display_path=path)
    assert service.last_symbol_load_timings['cache_hit']
    assert candidates.call_count == 1
    assert second['symbols'] == first['symbols']
    assert second['debug'] == first['debug']
    assert second['sourceProject']['firmwarePath'] == str(path)


def test_rebuild_with_same_size_and_timestamp_invalidates_cache(loading):
    service, path, candidates = loading
    first = load(service, path)
    stat = path.stat()
    path.write_bytes(b'B version')
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    second = load(service, path)
    assert not service.last_symbol_load_timings['cache_hit']
    assert candidates.call_count == 2
    assert second['symbols'][0]['address'] != first['symbols'][0]['address']


def test_cache_keeps_only_the_latest_successfully_parsed_image(loading):
    service, path, candidates = loading
    for version in (b'A version', b'B version', b'A version'):
        path.write_bytes(version)
        load(service, path)
        assert not service.last_symbol_load_timings['cache_hit']
    assert candidates.call_count == 3


def test_timeout_during_cache_hit_keeps_the_current_state(loading, monkeypatch):
    service, path, candidates = loading
    before = load(service, path)
    monkeypatch.setattr('take_a_look_backend.services.firmware.SYMBOL_LOAD_TIMEOUT_SECONDS', 0)
    with pytest.raises(ProtocolError) as error:
        load(service, path)
    assert error.value.code == 'symbol_load_timeout'
    assert service.state_snapshot()['symbols'] == before['symbols']
    assert candidates.call_count == 1


def test_failed_source_index_is_retried_instead_of_cached(loading, monkeypatch):
    service, path, candidates = loading
    def broken_dwarf(stream):
        elf = Mock(address=0x20000000)
        elf.has_dwarf_info.return_value = True
        elf.get_dwarf_info.side_effect = ValueError('broken DWARF')
        return elf
    monkeypatch.setattr('elftools.elf.elffile.ELFFile', broken_dwarf)
    load(service, path)
    load(service, path)
    assert candidates.call_count == 2
    assert service._symbol_cache is None
    assert not service.last_symbol_load_timings['cache_hit']


def test_context_hash_and_parsers_use_the_same_snapshot(loading):
    _, path, _ = loading
    original = path.read_bytes()
    with ElfLoadContext(path) as context:
        path.write_bytes(b'B version')
        assert context.fingerprint == hashlib.sha256(original).digest()
        assert context.elf.address == 0x20000000 + original[0]


def test_cache_reuses_freertos_layout_with_the_same_firmware(loading, monkeypatch):
    service, path, candidates = loading
    candidates.side_effect = lambda elf: [SymbolCandidate('pxCurrentTCB', 'STT_OBJECT', elf.address, 4, '.data')]
    layout = Mock()
    parse_layout = Mock(return_value=layout)
    monkeypatch.setattr('take_a_look_backend.services.firmware.FreeRtosLayout.from_context', parse_layout)
    load(service, path)
    load(service, path)
    assert service.last_symbol_load_timings['cache_hit']
    assert parse_layout.call_count == 1
    assert service._symbol_cache[1].freertos_layout is layout


def test_failed_freertos_layout_is_retried_instead_of_cached(loading, monkeypatch):
    service, path, candidates = loading
    candidates.side_effect = lambda elf: [SymbolCandidate('pxCurrentTCB', 'STT_OBJECT', elf.address, 4, '.data')]
    parse_layout = Mock(side_effect=ValueError('incomplete FreeRTOS types'))
    monkeypatch.setattr('take_a_look_backend.services.firmware.FreeRtosLayout.from_context', parse_layout)
    load(service, path)
    load(service, path)
    assert parse_layout.call_count == 2
    assert service._symbol_cache is None
    assert not service.last_symbol_load_timings['cache_hit']


def test_watch_rebinding_retains_only_unambiguous_memory_symbols():
    old = SymbolInfo('gain', 0x20000000, 4, 'float', '.data', 'motor.c')
    new = SymbolInfo('gain', 0x20000040, 4, 'float', '.data', 'motor.c')
    watch = WatchedVariable(old, '#123456', True, False, read_mode='manual',
                            monitor_rate_hz=7, monitor_enabled=False)
    rtt = SymbolInfo('gain', 0, 4, 'float', '', 'motor.c', data_source='rtt')
    result = BackendService._rebind_watches({old.key: watch}, [new, rtt])
    assert list(result) == [new.key]
    rebound = result[new.key]
    assert (rebound.symbol, rebound.color, rebound.plot_enabled, rebound.mode,
            rebound.monitor_rate_hz, rebound.monitor_enabled) == (new, '#123456', True, 'manual', 7, False)
    duplicate = SymbolInfo('gain', 0x20000080, 4, 'float', '.data', 'motor.c')
    assert BackendService._rebind_watches({old.key: watch}, [new, duplicate, rtt]) == {}


def test_real_multidimensional_record_and_pointer_arrays_keep_member_addresses(tmp_path):
    compiler = shutil.which('arm-none-eabi-gcc')
    if compiler is None:
        pytest.skip('ARM GCC is optional')
    source = tmp_path/'arrays.c'
    source.write_text(
        'typedef struct { int gain; int *ptr; int data[2]; } Node;\n'
        'volatile Node grid[2][3];\nvolatile int *pointers[2][2];\n'
        'int main(void) { return grid[1][2].data[1]; }\n', encoding='utf-8')
    path = tmp_path/'arrays.elf'
    subprocess.run([compiler, '-g', '-O0', '-nostdlib', '-Wl,-e,main', str(source), '-o', str(path)],
                   check=True, capture_output=True)
    symbols = {s.name: s for s in load_symbols_from_elf(path)}
    base = symbols['grid'].address
    assert symbols['grid[1]'].address == base + 48
    assert symbols['grid[1]'].size == 48
    assert symbols['grid[1][2].data[1]'].address == base + 92
    assert symbols['grid[1][2].data[1]'].size == 4
    assert not symbols['grid[1][2].data[1]'].is_pointer
    assert symbols['grid[1][2].ptr'].address == base + 84
    assert symbols['grid[1][2].ptr'].is_pointer
    assert symbols['pointers[1][1]'].address == symbols['pointers'].address + 12
    assert symbols['pointers[1][1]'].is_pointer

    # An unrelated linkage name at the same address cannot borrow another
    # variable's type; real C++ aliases are covered by test_symbol_matching.
    with patch('take_a_look_backend.services.symbols.symbol_candidates_from_elf', return_value=[
        SymbolCandidate('_ZN5drive4gridE', 'STT_OBJECT', base, symbols['grid'].size, '.bss')
    ]):
        mangled = {s.name: s for s in load_symbols_from_elf(path)}
    assert mangled['_ZN5drive4gridE'].encoding == 'unsupported'
    assert len(mangled) == 1

    # A cached source index must still reinstall hardware breakpoints after a
    # firmware download clears them. Cache parsed data, never installed state.
    memory = _FakeMemory()
    service = BackendService(lambda *_: None, memory_backend=memory,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
                             recording_directory=tmp_path/'records')
    try:
        load(service, path)
        service.handle(RpcMethod.CONNECT, {})
        source_path = next(p for p in service._debug.info.executable_lines if p.endswith('/arrays.c'))
        line = service._debug.info.executable_lines[source_path][0]
        service.handle(RpcMethod.SET_BREAKPOINTS, {'path': source_path, 'lines': [line]})
        address = service._debug.resolved_breakpoints[0]['address']
        assert memory.breakpoints == {address}
        memory.breakpoints.clear()
        load(service, path)
        assert service.last_symbol_load_timings['cache_hit']
        assert memory.breakpoints == {address}
        assert service._debug.resolved_breakpoints[0]['verified']
    finally:
        service.close()
