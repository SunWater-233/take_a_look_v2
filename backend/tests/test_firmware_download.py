"""Exercise real pyOCD loading with a simulated target; never opens a probe."""
import struct
import time
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from pyocd.core.memory_map import DeviceRegion, FlashRegion, MemoryMap, RamRegion
from pyocd.core.target import Target
from pyocd.coresight.coresight_target import CoreSightTarget
from pyocd.flash.builder import ProgrammingInfo

from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend
from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService


def firmware(path, segments, *, machine=40):
    ident = b'\x7fELF\x01\x01\x01' + b'\0' * 9
    header = struct.pack('<16sHHIIIIIHHHHHH', ident, 2, machine, 1, 0x08000001,
                         52, 0, 0, 52, 32, len(segments), 40, 0, 0)
    offset = 52 + 32 * len(segments)
    headers, contents = [], []
    for address, data in segments:
        headers.append(struct.pack('<IIIIIIII', 1, offset, address, address,
                                   len(data), len(data) + 16, 5, 4))
        contents.append(data)
        offset += len(data)
    path.write_bytes(header + b''.join(headers) + b''.join(contents))
    return str(path)


@pytest.fixture
def device():
    memory = {}
    target = MagicMock(spec=Target)
    target.debug_sequence_delegate = None
    target.selected_core = SimpleNamespace(node_name=None)
    flash_region = FlashRegion(start=0x08000000, length=0x10000, blocksize=256)
    target.memory_map = MemoryMap(flash_region, RamRegion(start=0x20000000, length=0x1000))
    target.read_memory_block8.side_effect = lambda address, size: [memory.get(address+i, 0) for i in range(size)]
    target.write_memory_block8.side_effect = lambda address, data: memory.update(
        {address+i: value for i, value in enumerate(data)})
    chunks = []
    builder = MagicMock()
    builder.region = flash_region
    builder.buffered_data_size = 0
    def add(address, data):
        chunks.append((address, bytes(data)))
        builder.buffered_data_size += len(data)
    def program(**kwargs):
        for address, data in chunks:
            target.write_memory_block8(address, data)
        kwargs['progress_cb'](1)
        return ProgrammingInfo(program_time=.001, total_byte_count=builder.buffered_data_size,
                               program_byte_count=builder.buffered_data_size)
    builder.add_data.side_effect = add
    builder.program.side_effect = program
    flash_region.flash = MagicMock()
    flash_region.flash.get_flash_builder.return_value = builder
    backend = PyOcdMemoryBackend()
    backend.session = SimpleNamespace(board=SimpleNamespace(target=target), target=target, options={}, close=lambda: None)
    backend.target = target
    return SimpleNamespace(backend=backend, target=target, region=flash_region,
                           builder=builder, memory=memory)


@pytest.mark.parametrize('case,code', [
    ('unmapped', 'firmware_address_invalid'),
    ('gap', 'firmware_address_invalid'),
    ('missing_algorithm', 'flash_algorithm_missing'),
    ('generic', 'flash_algorithm_missing'),
    ('ram_only', 'flash_algorithm_missing'),
    ('empty', 'firmware_empty'),
    ('non_arm', 'invalid_firmware'),
    ('peripheral', 'firmware_address_invalid'),
])
def test_preflight_rejects_invalid_firmware_before_any_write(tmp_path, device, case, code):
    segments = [(0x08000000, b'valid'), (0x09000000, b'unmapped')]
    machine = 40
    if case == 'gap':
        segments = [(0x0800FFFE, b'cross boundary')]
    elif case == 'missing_algorithm':
        segments = segments[:1]
        device.region.flash = None
    elif case == 'generic':
        device.target.memory_map = CoreSightTarget._create_default_cortex_m_memory_map(None)
        segments = segments[:1]
    elif case == 'ram_only':
        segments = [(0x20000000, b'RAM')]
    elif case == 'empty':
        segments = [(0x08000000, b'')]
    elif case == 'non_arm':
        segments, machine = segments[:1], 3
    elif case == 'peripheral':
        device.target.memory_map.add_region(DeviceRegion(start=0x40000000, length=0x1000))
        segments = [segments[0], (0x40000000, b'device')]
    with pytest.raises(ProtocolError) as error:
        device.backend.program_firmware(firmware(tmp_path/'app.axf', segments, machine=machine), lambda _: None)
    assert error.value.code == code
    device.builder.erase.assert_not_called()
    device.builder.program.assert_not_called()
    device.target.write_memory_block8.assert_not_called()
    device.target.reset_and_halt.assert_not_called()


def test_valid_flash_and_ram_are_loaded_and_fully_verified(tmp_path, device):
    segments = [(0x08000000, bytes(range(256)) * 33), (0x20000010, b'RAM data')]
    progress = []
    device.backend.program_firmware(firmware(tmp_path/'app.elf', segments), progress.append)
    assert progress[-1] == 1
    assert progress == sorted(progress)
    assert device.target.read_memory_block8.call_count == 4
    for address, data in segments:
        assert bytes(device.memory[address+i] for i in range(len(data))) == data
    # p_memsz includes uninitialised data that must not be written or verified.
    assert 0x20000010 + len(b'RAM data') not in device.memory
    device.builder.erase.assert_called_once()
    device.builder.program.assert_called_once()
    device.target.reset_and_halt.assert_called_once()


def test_reset_clocks_before_flash_algorithm_changes_wait_states(tmp_path, device):
    # Model the GD32E50x pack: Init clears Flash wait states, so reads fail
    # while the application's high-speed clocks are still active.
    reset_clocks = False
    def reset():
        nonlocal reset_clocks
        reset_clocks = True
    device.target.reset_and_halt.side_effect = reset
    device.builder.erase.side_effect = lambda **_: reset_clocks or pytest.fail('erase before reset')
    device.target.read_memory_block8.side_effect = lambda address, size: [
        device.memory.get(address+i, 0) if reset_clocks else 255 for i in range(size)]
    device.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    assert reset_clocks


def test_reset_failure_prevents_erase_and_programming(tmp_path, device):
    device.target.reset_and_halt.side_effect = RuntimeError('reset failed')
    with pytest.raises(RuntimeError, match='reset failed'):
        device.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    device.builder.erase.assert_not_called()
    device.builder.program.assert_not_called()


@pytest.mark.parametrize('readback', [b'bad', b'', b'go', b'good!'])
def test_bad_or_short_readback_never_reports_success(tmp_path, device, readback):
    device.target.read_memory_block8.side_effect = lambda *_: readback
    progress = []
    with pytest.raises(ProtocolError) as error:
        device.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), progress.append)
    assert error.value.code == 'firmware_verify_failed'
    assert '0x080000' in error.value.details
    assert '期望 ' in error.value.details
    assert '实际 ' in error.value.details
    assert 1 not in progress


@pytest.mark.parametrize('stage', ['add_data', 'program', 'readback'])
def test_loading_and_probe_errors_propagate(tmp_path, device, stage):
    operation = {'add_data': device.builder.add_data, 'program': device.builder.program,
                 'readback': device.target.read_memory_block8}[stage]
    error_type = ValueError if stage == 'add_data' else RuntimeError
    operation.side_effect = error_type('probe failure')
    with pytest.raises(error_type, match='probe failure'):
        device.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    if stage == 'add_data':
        device.builder.erase.assert_not_called()


def test_truncated_elf_is_rejected_before_erase(tmp_path, device):
    path = tmp_path/'app.elf'
    firmware(path, [(0x08000000, b'good')])
    path.write_bytes(path.read_bytes()[:-1])
    with pytest.raises(ProtocolError) as error:
        device.backend.program_firmware(str(path), lambda _: None)
    assert error.value.code == 'invalid_firmware'
    device.builder.erase.assert_not_called()


def test_elf_uses_flash_load_address_for_ram_initialisers(tmp_path, device):
    path = tmp_path/'app.elf'
    firmware(path, [(0x08000000, b'data')])
    data = bytearray(path.read_bytes())
    struct.pack_into('<I', data, 52 + 8, 0x20000000)  # p_vaddr differs from p_paddr.
    path.write_bytes(data)
    device.backend.program_firmware(str(path), lambda _: None)
    assert bytes(device.memory[0x08000000+i] for i in range(4)) == b'data'
    assert 0x20000000 not in device.memory


def test_failed_verification_fails_async_task_without_post_download_reset_or_resume(tmp_path, device):
    device.target.read_memory_block8.side_effect = lambda *_: b'bad!'
    firmware(tmp_path/'app.elf', [(0x08000000, b'good')])
    service = BackendService(lambda *_: None, memory_backend=device.backend,
                             recording_directory=tmp_path/'records')
    service._connection_status = 'connected'
    try:
        service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(tmp_path), 'firmwarePath': 'app.elf',
                                                      'afterDownload': 'run'})
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        deadline = time.monotonic() + 5
        while service._source_tasks.running and time.monotonic() < deadline:
            time.sleep(.01)
        result = service._source_tasks.snapshot()
        assert result['status'] == 'failed', result
        assert '校验失败' in result['message']
        assert service._sampling_paused and not service._rtt_enabled
        # Only the reset before programming is allowed; a failed verification
        # must not trigger the service's post-download reset or resume.
        device.target.reset_and_halt.assert_called_once()
        device.target.resume.assert_not_called()
    finally:
        service.close()
