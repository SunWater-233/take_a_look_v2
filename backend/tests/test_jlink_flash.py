"""Exercise the J-Link dispatch and file boundary without opening hardware."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
import time

from intelhex import IntelHex
from pylink.errors import JLinkException
from pyocd.core.memory_map import FlashRegion
from pyocd.core.target import Target
from pyocd.probe.jlink_probe import JLinkProbe
import pytest

from take_a_look_backend.backends.jlink_flash import resolve_device
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig
from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from test_firmware_download import device, firmware


@pytest.fixture
def native(device):
    link = Mock()
    def lookup(name):
        if name.casefold() == 'stm32h723vg':
            return 7
        raise JLinkException('Unsupported device selected.')
    link.get_device_index.side_effect = lookup
    link.supported_device.return_value = SimpleNamespace(name='STM32H723VG')
    staged = []
    paths = []
    def download(path, address, on_progress):
        paths.append(Path(path))
        image = IntelHex(path)
        chunks = [(start, bytes(image.tobinarray(start=start, end=end-1)))
                  for start, end in image.segments()]
        staged.extend(chunks)
        # Model the native algorithm using RAM before RAM payloads are loaded.
        device.memory[0x20000010] = 0xFF
        for start, data in chunks:
            device.memory.update({start+i: byte for i, byte in enumerate(data)})
        for action in ('Compare', 'Erase', 'Flash', 'Verify'):
            for percent in (0, 50, 100):
                on_progress(action.encode(), action.encode(), percent)
        return 0  # JLINK_DownloadFile's result is not a byte count.
    def write(address, data):
        device.memory.update({address+i: byte for i, byte in enumerate(data)})
        return len(data)
    link.flash_file.side_effect = download
    link.memory_write8.side_effect = write
    link.memory_read8.side_effect = lambda address, size: [device.memory.get(address+i, 0) for i in range(size)]
    probe = JLinkProbe.__new__(JLinkProbe)
    probe._link = link
    device.backend.session.probe = probe
    device.backend.session.notify = Mock()
    device.backend._config = PyOcdConnectionConfig(
        'stm32h723xx', 4_000_000, part_number='STM32H723VGTx')
    device.target.part_number = 'STM32H723xx'
    return SimpleNamespace(**vars(device), link=link, staged=staged, paths=paths)


def test_native_download_groups_sparse_flash_and_loads_ram_after_algorithm(tmp_path, native):
    native.target.memory_map.add_region(FlashRegion(start=0x08010000, length=0x10000, blocksize=256))
    chunks = [(0x08000000, b'first'), (0x08000040, b'same sector'),
              (0x0800FFFE, b'cross 64K'), (0x20000010, b'RAM')]
    progress = []
    native.backend.program_firmware(firmware(tmp_path/'app.axf', chunks), progress.append)
    assert native.staged == chunks[:3]
    native.link.flash_file.assert_called_once()
    native.link.connect.assert_called_once_with('STM32H723VG', speed=4000)
    native.link.reset.assert_called_once_with(halt=True)
    native.link.memory_write8.assert_called_once_with(0x20000010, list(b'RAM'))
    for address, data in chunks:
        assert bytes(native.memory[address+i] for i in range(len(data))) == data
        assert address + len(data) not in native.memory
    assert progress == sorted(progress)
    assert progress[-1] == 1
    assert native.backend.last_flash_stats['engine'] == 'jlink'
    assert native.backend.last_flash_stats['device'] == 'STM32H723VG'
    assert all(not path.exists() for path in native.paths)
    native.builder.program.assert_not_called()
    native.target.read_memory_block8.assert_not_called()
    native.target.reset_and_halt.assert_not_called()
    assert native.backend.session.notify.call_args_list[0].args == (
        Target.Event.PRE_RESET, native.target.selected_core)
    assert native.backend.session.notify.call_args_list[-1].args == (
        Target.Event.POST_RESET, native.target.selected_core)


def test_native_flash_does_not_require_pyocd_flash_algorithm(tmp_path, native):
    native.region.flash = None
    native.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    native.link.flash_file.assert_called_once()


@pytest.mark.parametrize('keep', [False, True])
def test_native_preservation_setting_matches_session_options(tmp_path, native, keep):
    native.backend.session.options['keep_unwritten'] = keep
    native.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    native.link.exec_command.assert_any_call(f'SetFlashDLNoRMWThreshold = {0xFFFFFFFF if keep else 0}')


@pytest.mark.parametrize('segments', [
    [(0x08000000, b'good'), (0x09000000, b'bad')],
    [(0x08000000, b'overlap'), (0x08000001, b'bad')],
])
def test_native_preflight_completes_before_device_connect(tmp_path, native, segments):
    with pytest.raises((ProtocolError, ValueError)):
        native.backend.program_firmware(firmware(tmp_path/'app.elf', segments), lambda _: None)
    native.link.connect.assert_not_called()
    native.link.flash_file.assert_not_called()


def test_ambiguous_builtin_alias_is_rejected_before_reset_or_erase(tmp_path, native):
    native.backend._config = PyOcdConnectionConfig('stm32h723xx', 4_000_000)
    with pytest.raises(ProtocolError) as error:
        native.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), lambda _: None)
    assert error.value.code == 'jlink_device_unsupported'
    native.link.connect.assert_not_called()
    native.link.reset.assert_not_called()
    native.link.flash_file.assert_not_called()
    native.builder.program.assert_not_called()


@pytest.mark.parametrize('readback', [b'bad', b'', b'go', b'good!'])
def test_native_verification_checks_payload_and_length(tmp_path, native, readback):
    native.link.memory_read8.side_effect = lambda *_: readback
    progress = []
    with pytest.raises(ProtocolError) as error:
        native.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), progress.append)
    assert error.value.code == 'firmware_verify_failed'
    assert 1 not in progress
    assert native.backend.last_flash_stats is None


@pytest.mark.parametrize('stage', ['connect', 'reset', 'flash_file', 'memory_read8'])
def test_native_errors_propagate_without_retrying_pyocd(tmp_path, native, stage):
    getattr(native.link, stage).side_effect = JLinkException('native failure')
    progress = []
    with pytest.raises(JLinkException, match='native failure'):
        native.backend.program_firmware(firmware(tmp_path/'app.elf', [(0x08000000, b'good')]), progress.append)
    assert 1 not in progress
    assert native.backend.last_flash_stats is None
    native.builder.program.assert_not_called()
    assert native.backend.session.notify.call_args.args == (
        Target.Event.POST_RESET, native.target.selected_core)


def test_native_ram_short_write_prevents_completion(tmp_path, native):
    native.link.memory_write8.side_effect = lambda *_: 1
    progress = []
    with pytest.raises(ProtocolError) as error:
        native.backend.program_firmware(firmware(tmp_path/'app.elf', [
            (0x08000000, b'good'), (0x20000010, b'ram')]), progress.append)
    assert error.value.code == 'firmware_write_failed'
    assert 1 not in progress


def test_device_name_resolution_uses_dll_canonical_name(native):
    assert resolve_device(native.link, ['stm32h723vg']) == 'STM32H723VG'
    assert resolve_device(native.link, ['STM32H723VGTx']) == 'STM32H723VG'


def test_device_lookup_errors_are_not_misreported_as_unsupported(native):
    native.link.get_device_index.side_effect = OSError('DLL failed')
    with pytest.raises(OSError, match='DLL failed'):
        resolve_device(native.link, ['STM32H723VG'])


def test_native_verification_failure_does_not_reset_or_resume_application(tmp_path, native):
    native.link.memory_read8.side_effect = lambda *_: b'bad!'
    firmware(tmp_path/'app.elf', [(0x08000000, b'good')])
    service = BackendService(lambda *_: None, memory_backend=native.backend,
                             recording_directory=tmp_path/'records')
    service._connection_status = 'connected'
    try:
        service.handle(RpcMethod.SET_SOURCE_PROJECT, {'sourceRoot': str(tmp_path), 'firmwarePath': 'app.elf',
                                                     'afterDownload': 'run'})
        service.handle(RpcMethod.START_SOURCE_TASK, {'kind': 'download'})
        deadline = time.monotonic() + 5
        while service._source_tasks.running and time.monotonic() < deadline:
            time.sleep(.01)
        assert service._source_tasks.snapshot()['status'] == 'failed'
        assert service._sampling_paused and not service._rtt_enabled
        native.target.reset_and_halt.assert_not_called()
        native.target.resume.assert_not_called()
        native.link.reset.assert_called_once_with(halt=True)
    finally:
        service.close()
