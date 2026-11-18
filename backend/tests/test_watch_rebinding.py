"""Watch-tree reconciliation through both declarations and real ARM ELF rebuilds."""
import shutil
import subprocess
from dataclasses import replace

import pytest

from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import RpcMethod
from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.watch_rebinding import rebind_watches
from take_a_look_backend.services.debug_info import DebugInfoIndex
from test_service import _FakeMemory, _FakeRtt


def test_watch_rebinding_retains_only_unambiguous_memory_symbols():
    old = SymbolInfo('gain', 0x20000000, 4, 'float', '.data', 'motor.c')
    new = SymbolInfo('gain', 0x20000040, 4, 'float', '.data', 'motor.c')
    watch = WatchedVariable(old, '#123456', True, False, read_mode='manual',
                            monitor_rate_hz=7, monitor_enabled=False)
    rtt = SymbolInfo('gain', 0, 4, 'float', '', 'motor.c', data_source='rtt')
    result = rebind_watches({old.key: watch}, [new, rtt])
    assert list(result) == [new.key]
    rebound = result[new.key]
    assert (rebound.symbol, rebound.color, rebound.plot_enabled, rebound.mode,
            rebound.monitor_rate_hz, rebound.monitor_enabled) == (new, '#123456', True, 'manual', 7, False)
    duplicate = SymbolInfo('gain', 0x20000080, 4, 'float', '.data', 'motor.c')
    unavailable = rebind_watches({old.key: watch}, [new, duplicate, rtt])[old.key]
    assert unavailable.symbol.missing and not unavailable.captures and not unavailable.symbol.is_writable


def test_watch_rebinding_adds_new_members_without_restoring_omitted_branches():
    old_names = ['motor', 'motor.speed', 'motor.removed', 'motor.current', 'motor.current.q',
                 'motor.samples', 'motor.samples[0]', 'motor.hidden', 'motor.hidden.old',
                 'standalone', 'standalone.value']
    old = {name: SymbolInfo(name, 0x20000000 + i * 4, 4, 'float', '.data', 'motor.c')
           for i, name in enumerate(old_names)}
    watched_names = [name for name in old_names if name not in
                     {'motor.hidden', 'motor.hidden.old', 'standalone'}]
    previous = {old[name].key: WatchedVariable(old[name], '#123456', True, True,
                    read_mode='capture', monitor_rate_hz=5) for name in watched_names}
    previous[old['motor.current'].key].color = '#abcdef'
    added_names = ['motor.added', 'motor.added.value', 'motor.current.d', 'motor.samples[1]']
    new_names = [name for name in old_names if name != 'motor.removed'] + added_names + [
        'motor.hidden.new', 'standalone.sibling', 'motorExtra.member']
    symbols = [SymbolInfo(name, 0x20000100 + i * 8, 8, 'double', '.data', 'motor.c')
               for i, name in enumerate(new_names)]
    symbols += [SymbolInfo('motor.foreign', 0x20000200, 4, 'float', '.data', 'other.c'),
                SymbolInfo('motor.duplicate', 0x20000204, 4, 'float', '.data', 'motor.c'),
                SymbolInfo('motor.duplicate', 0x20000208, 4, 'float', '.data', 'motor.c'),
                SymbolInfo('motor.rtt', 0, 4, 'float', '', 'motor.c', data_source='rtt')]

    result = rebind_watches(previous, symbols, old.values())
    watched = {watch.symbol.name: watch for watch in result.values()}
    retained_names = [name for name in watched_names if name != 'motor.removed']
    assert set(watched) == set(watched_names + added_names)
    assert watched['motor.removed'].symbol.missing and not watched['motor.removed'].captures
    assert [name for name in watched if name in retained_names] == retained_names
    assert list(watched).index('motor.samples[0]') < list(watched).index('motor.samples[1]')
    assert list(watched).index('motor.current.q') < list(watched).index('motor.current.d')
    assert list(watched).index('motor.current.d') < list(watched).index('motor.samples')
    for name in retained_names:
        watch = watched[name]
        assert watch.symbol is next(symbol for symbol in symbols if symbol.name == name)
        assert watch.symbol.size == 8 and watch.symbol.kind == 'double'
        assert watch.mode == 'capture' and watch.plot_enabled and watch.monitor_rate_hz == 5
    for name in added_names:
        watch = watched[name]
        assert watch.mode == 'monitor' and not watch.sampling_enabled and not watch.plot_enabled
        assert watch.monitor_rate_hz is None
        assert watch.value == '' and watch.updated_at_ms is None
    assert watched['motor.current.d'].color == '#abcdef'
    assert watched['motor.added.value'].color == '#123456'


def test_missing_watch_keeps_recording_and_settings_without_accessing_old_memory(tmp_path):
    old = SymbolInfo('motor.removed', 0x20000004, 4, 'float', '.data', 'motor.c', encoding='float')
    current = [old]
    memory = _FakeMemory()
    service = BackendService(lambda *_: None, memory_backend=memory,
        normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
        recording_directory=tmp_path / 'records', symbol_loader=lambda *a, **k: current,
        debug_info_loader=lambda *a, **k: DebugInfoIndex())
    service._shutdown.set(); service._wake.set()
    service._sampler.join(2); service._firmware_watch_thread.join(2)
    firmware = tmp_path / 'motor.axf'
    firmware.write_bytes(b'old')
    try:
        service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
        service.handle(RpcMethod.SET_WATCHES, {'watches': [
            {'key': old.key, 'readMode': 'capture', 'plotted': True, 'color': '#abcdef'}]})
        service._queue_samples_locked([(1.0, {old.key: 12.5})])
        service._flush_pending_samples_locked()
        raw_path = service._recording.path
        current = [SymbolInfo('other', 0x20000004, 4, 'float', '.data', 'motor.c')]
        firmware.write_bytes(b'new')
        service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
        service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
        missing = service._watches[old.key]
        assert missing.symbol.missing and not missing.captures
        assert missing.plot_enabled and missing.mode == 'capture' and missing.color == '#abcdef'
        service._connection_status = 'connected'
        service._debug.execution_state = 'running'
        assert service._read_memory_locked(False, 'normal') == {}
        service._poll_monitors_locked(100)
        service._remember_values_locked({old.key: 99})
        assert missing.value != 99 and memory.values == {}
        capabilities = memory.capabilities
        memory.capabilities = replace(capabilities, memory_sampling=False)
        memory.execution_state = 'halted'
        service._refresh_debug_state_locked(force=True)
        assert memory.values == {}
        memory.execution_state = 'running'
        memory.capabilities = capabilities
        for method, params in [
            (RpcMethod.READ_WATCH, {'key': old.key}),
            (RpcMethod.WRITE_WATCH, {'key': old.key, 'value': '1'}),
            (RpcMethod.WRITE_WATCHES, {'writes': [{'key': old.key, 'value': '1'}]}),
        ]:
            with pytest.raises(ProtocolError) as error:
                service.handle(method, params)
            assert error.value.code in {'symbol_missing', 'readonly_symbol'}
        csv = tmp_path / 'samples.csv'
        service.handle(RpcMethod.EXPORT_CSV, {'path': str(csv)})
        assert raw_path.exists() and service._recording.path == raw_path
        assert 'motor.removed' in csv.read_text(encoding='utf-8-sig')
        assert '12.5' in csv.read_text(encoding='utf-8-sig')
        # Removing/reloading the same generation cannot reactivate the old address.
        service.handle(RpcMethod.SET_WATCHES, {'watches': [{'key': old.key, 'readMode': 'monitor'}]})
        service._poll_monitors_locked(101)
        assert memory.values == {}
        saved = service._symbol_json(service._watches[old.key].symbol)
        service._symbols.pop(old.key)
        service._watches = {}
        restored = service.handle(RpcMethod.SET_WATCHES, {'watches': [
            {'key': old.key, 'symbol': saved, 'readMode': 'capture', 'plotted': True}]})['state']
        assert next(s for s in restored['symbols'] if s['key'] == old.key)['missing']
        assert not service._watches[old.key].captures
        current = [SymbolInfo('motor.removed', 0x20000100, 4, 'float', '.data', 'motor.c')]
        firmware.write_bytes(b'restored')
        service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})
        rebound = next(iter(service._watches.values()))
        assert not rebound.symbol.missing and rebound.symbol.address == 0x20000100
    finally:
        service.close()


@pytest.mark.parametrize('refresh', ['reload', 'settings', 'automatic'])
@pytest.mark.parametrize('language,initial,changed,expected', [
    ('c', 'struct Motor { float speed; int removed; }; volatile struct Motor motor;',
     'struct Motor { int added; double speed; struct { int value; } nested; float samples[2]; }; volatile struct Motor motor;',
     {'motor', 'motor.speed', 'motor.added', 'motor.nested', 'motor.nested.value',
      'motor.samples', 'motor.samples[0]', 'motor.samples[1]'}),
    ('c', 'volatile float motor[2];', 'volatile double motor[3];',
     {'motor', 'motor[0]', 'motor[1]', 'motor[2]'}),
    ('c', 'volatile int motor[1][2];', 'volatile int motor[2][1];',
     {'motor', 'motor[0]', 'motor[0][0]', 'motor[1]', 'motor[1][0]'}),
    ('c', 'struct Entry { int old; }; volatile struct Entry motor[1];',
     'struct Entry { double value; }; volatile struct Entry motor[2];',
     {'motor', 'motor[0]', 'motor[0].value', 'motor[1]', 'motor[1].value'}),
    ('c', 'union Motor { int old; float value; }; volatile union Motor motor;',
     'union Motor { double value; int added[2]; }; volatile union Motor motor;',
     {'motor', 'motor.value', 'motor.added', 'motor.added[0]', 'motor.added[1]'}),
    ('c++', 'class Motor { public: int old; float value; }; volatile Motor motor;',
     'class Motor { public: double value; int added[2]; }; volatile Motor motor;',
     {'motor', 'motor.value', 'motor.added', 'motor.added[0]', 'motor.added[1]'}),
    ('c', 'volatile int motor;', 'volatile int motor[2];',
     {'motor', 'motor[0]', 'motor[1]'}),
    ('c', 'volatile int motor[3];', 'volatile int motor[1];', {'motor', 'motor[0]'}),
], ids=['struct', 'array-growth', 'matrix', 'record-array', 'union', 'class',
        'scalar-to-array', 'array-shrink'])
def test_real_elf_rebuild_refreshes_watched_members(tmp_path, refresh, language, initial, changed, expected):
    compiler = shutil.which('arm-none-eabi-g++' if language == 'c++' else 'arm-none-eabi-gcc')
    if compiler is None:
        pytest.skip('ARM compiler is optional')
    source, firmware = tmp_path / ('motor.cpp' if language == 'c++' else 'motor.c'), tmp_path / 'motor.elf'

    def build(declarations, data_address):
        entry = 'extern "C" ' if language == 'c++' else ''
        source.write_text(declarations + entry + 'void _start(void) { for (;;) {} }')
        subprocess.run([compiler, '-g', '-gdwarf-4', '-O0', '-mcpu=cortex-m3', '-mthumb',
                        '-nostdlib', '-Wl,--entry=_start', '-Wl,-Ttext=0x08000000',
                        f'-Wl,-Tbss={data_address:#x}', str(source), '-o', str(firmware)],
                       check=True, capture_output=True, timeout=30)

    build(initial, 0x20000000)
    service = BackendService(lambda *_: None, memory_backend=_FakeMemory(),
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt(),
                             recording_directory=tmp_path / 'records')
    # Drive the refresh explicitly so the poller cannot race these assertions.
    service._shutdown.set()
    service._wake.set()
    service._sampler.join(2)
    service._firmware_watch_thread.join(2)
    try:
        first = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
        original = {symbol['name'] for symbol in first['symbols'] if
                    symbol['name'] == 'motor' or symbol['name'].startswith(('motor.', 'motor['))}
        service.handle(RpcMethod.SET_WATCHES, {'watches': [
            {'key': symbol['key'], 'color': '#123456', 'readMode': 'capture', 'plotted': True,
             'monitorRateHz': 5} for symbol in first['symbols'] if symbol['name'] in original
        ]})
        build(changed, 0x20000100)
        if refresh == 'reload':
            state = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
        elif refresh == 'settings':
            state = service.handle(RpcMethod.SET_SOURCE_PROJECT, {'firmwarePath': str(firmware)})['state']
        else:
            assert service._refresh_changed_firmware(firmware)
            state = service.state_snapshot()
        symbols = {symbol['key']: symbol for symbol in state['symbols']}
        watches = {symbols[watch['key']]['name']: watch for watch in state['watches']}
        assert set(watches) == expected | original
        assert {name for name, watch in watches.items() if not symbols[watch['key']].get('missing')} == expected
        assert symbols[watches['motor']['key']]['address'] == 0x20000100
        for name, watch in watches.items():
            assert watch['color'] == '#123456'
            if name not in expected:
                assert symbols[watch['key']]['missing'] and not service._watches[watch['key']].captures
            else:
                assert symbols[watch['key']]['address'] >= 0x20000100
            if name in original:
                assert watch['readMode'] == 'capture' and watch['plotted']
                assert watch['monitorRateHz'] == 5
            else:
                assert watch['readMode'] == 'monitor' and not watch['plotted']
        if language == 'c' and 'motor.speed' in watches:
            speed = symbols[watches['motor.speed']['key']]
            assert speed['address'] == 0x20000108 and speed['size'] == 8 and speed['encoding'] == 'float'
        again = service.handle(RpcMethod.LOAD_FIRMWARE, {'path': str(firmware)})['state']
        assert len(again['watches']) == len(watches)
        assert service.last_symbol_load_timings['cache_hit']
    finally:
        service.close()
