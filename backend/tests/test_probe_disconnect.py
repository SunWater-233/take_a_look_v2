import errno
import threading
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest
from pylink.errors import JLinkException
from pyocd.core.exceptions import ProbeDisconnected, TransferFaultError, TransferTimeoutError
from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
from pyocd.probe.debug_probe import DebugProbe
from pyocd.probe.jlink_probe import JLinkProbe

from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from test_service import _FakeRtt


def memory_backend():
    probe = JLinkProbe.__new__(JLinkProbe)
    DebugProbe.__init__(probe)
    probe._link = Mock(spec=["connected", "target_connected", "close"])
    probe._link.connected.return_value = True
    probe._link.target_connected.return_value = False
    probe.close = Mock()
    memory = PyOcdMemoryBackend()
    memory.session = SimpleNamespace(probe=probe, close=Mock())
    memory.target = SimpleNamespace(get_state=Mock(return_value="running"),
                                    read_memory_block8=Mock(return_value=[0, 0, 128, 63]))
    return memory, probe


def wrapped_read_error(cause):
    try:
        raise ProtocolError("memory_read_failed", "read failed") from cause
    except ProtocolError as error:
        return error


def cmsis_dap_memory_backend():
    memory, _ = memory_backend()
    device = SimpleNamespace(bus=3, address=10, idVendor=0xFAED, idProduct=0x4873,
                             _ctx=SimpleNamespace(backend=object()))
    probe = CMSISDAPProbe(SimpleNamespace(_interface=SimpleNamespace(dev=device),
                                         get_unique_id=lambda: "active-probe"))
    probe.close = Mock()
    memory.session.probe = probe
    return memory, probe, device


def test_open_cmsis_dap_uses_usb_location_without_reopening_exclusive_interface():
    memory, probe, device = cmsis_dap_memory_backend()
    with patch.object(CMSISDAPProbe, "get_probe_with_id", return_value=None) as driver_scan, \
            patch("usb.core.find", return_value=[device]) as usb_scan:
        memory.check_connection(force=True)
    driver_scan.assert_not_called()
    usb_scan.assert_called_once_with(find_all=True, backend=device._ctx.backend,
                                     idVendor=device.idVendor, idProduct=device.idProduct)
    assert memory.is_connected
    probe.close.assert_not_called()


@pytest.mark.parametrize("remaining", [[], [SimpleNamespace(bus=3, address=11)]])
def test_cmsis_dap_loss_checks_active_location_even_with_another_identical_probe(remaining):
    memory, _, _ = cmsis_dap_memory_backend()
    with patch.object(CMSISDAPProbe, "get_probe_with_id", return_value=object()) as driver_scan, \
            patch("usb.core.find", return_value=remaining):
        with pytest.raises(ProbeDisconnected):
            memory.check_connection(force=True)
    driver_scan.assert_not_called()


@pytest.mark.parametrize("field", ["bus", "address"])
def test_cmsis_dap_unknown_usb_location_is_inconclusive(field):
    memory, _, device = cmsis_dap_memory_backend()
    setattr(device, field, None)
    with patch.object(CMSISDAPProbe, "get_probe_with_id", return_value=None) as driver_scan, \
            patch("usb.core.find") as usb_scan:
        memory.check_connection(force=True)
    driver_scan.assert_not_called()
    usb_scan.assert_not_called()
    assert memory.is_connected


@pytest.mark.parametrize("cause", [PermissionError(errno.EACCES, "interface already open"),
                                   OSError(errno.ENODEV, "another USB device disappeared")])
def test_cmsis_dap_failed_system_enumeration_does_not_prove_active_probe_loss(cause):
    memory, _, _ = cmsis_dap_memory_backend()
    with patch.object(CMSISDAPProbe, "get_probe_with_id", return_value=object()), \
            patch("usb.core.find", side_effect=cause):
        memory.check_connection(force=True)
    assert memory.is_connected


def test_jlink_presence_uses_emulator_status_and_throttles_healthy_checks(monkeypatch):
    memory, probe = memory_backend()
    clock = [10.0]
    monkeypatch.setattr("take_a_look_backend.backends.pyocd_memory.perf_counter", lambda: clock[0])
    memory.check_connection()
    for _ in range(20):
        memory.check_connection()
    probe._link.connected.assert_called_once()
    probe._link.target_connected.assert_not_called()
    probe._link.connected.return_value = False
    clock[0] = 11.0
    with pytest.raises(ProbeDisconnected):
        memory.check_connection()


@pytest.mark.parametrize("fault", [TransferFaultError("bad address"), TransferTimeoutError("WAIT timeout")])
def test_target_access_fault_is_not_a_probe_disconnect(fault):
    memory, probe = memory_backend()
    error = wrapped_read_error(fault)
    for _ in range(3):
        memory.check_connection(error=error, force=True)
    assert memory.is_connected
    probe.close.assert_not_called()


@pytest.mark.parametrize("cause", [ProbeDisconnected("device removed"),
                                   ConnectionResetError("connection lost"),
                                   OSError(errno.ENODEV, "device removed")])
def test_definite_transport_loss_is_recognised_through_wrapped_errors(cause):
    memory, probe = memory_backend()
    error = wrapped_read_error(cause)
    with pytest.raises(ProbeDisconnected):
        memory.check_connection(error=error)
    probe._link.connected.assert_not_called()


def test_unknown_presence_query_failure_does_not_disconnect():
    memory, probe = memory_backend()
    probe._link.connected.side_effect = JLinkException("query failed")
    memory.check_connection(force=True)
    assert memory.is_connected


def test_missing_probe_handle_is_an_inconclusive_check():
    memory, _ = memory_backend()
    memory.session = SimpleNamespace(close=Mock())
    memory.check_connection(force=True)
    assert memory.is_connected


def test_unexpected_presence_check_failure_does_not_escape_sampler_error_handling(tmp_path):
    memory, _ = memory_backend()
    memory.check_connection = Mock(side_effect=RuntimeError("unsupported driver query"))
    service = BackendService(lambda *_: None, memory_backend=memory, recording_directory=tmp_path,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt())
    try:
        with service._lock:
            service._connection_status = "connected"
            service._poll_debug_state_locked()
            assert service._connection_status == "connected"
            assert not service._handle_connection_failure_locked(TransferFaultError("bad address"))
    finally:
        service.close()


def test_generic_probe_checks_the_active_unique_id_without_opening_it():
    class EnumeratedProbe(DebugProbe):
        present = True
        seen = []

        @property
        def unique_id(self):
            return "active-probe"

        @classmethod
        def get_probe_with_id(cls, unique_id, is_explicit=False):
            cls.seen.append(unique_id)
            return object() if cls.present else None

    memory, _ = memory_backend()
    memory.session.probe = EnumeratedProbe()
    memory.check_connection(force=True)
    EnumeratedProbe.present = False
    with pytest.raises(ProbeDisconnected):
        memory.check_connection(force=True)
    assert EnumeratedProbe.seen == ["active-probe", "active-probe"]


@pytest.mark.parametrize("close_fails", [False, True])
def test_lost_probe_close_releases_host_resources_without_target_io(close_fails):
    memory, probe = memory_backend()
    session = memory.session
    memory._release_target_registry = Mock()
    if close_fails:
        probe.close.side_effect = OSError("already removed")
        with pytest.raises(OSError):
            memory.disconnect_lost_probe()
    else:
        memory.disconnect_lost_probe()
    probe.close.assert_called_once()
    session.close.assert_not_called()
    memory._release_target_registry.assert_called_once()
    assert session._closed
    assert not memory.is_connected
    assert memory.probe is None


def test_unplug_during_memory_read_bypasses_cached_presence_and_stops_retrying(tmp_path):
    memory, probe = memory_backend()
    lost = threading.Event()
    events = []
    def emit(name, payload):
        events.append((name, payload))
        if name is EventName.ERROR and payload.get("code") == "probe_disconnected":
            lost.set()
    service = BackendService(emit, memory_backend=memory, recording_directory=tmp_path,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt())
    target = memory.target
    def unplug(address, size):
        probe._link.connected.return_value = False
        raise TransferFaultError("Unspecified error.")
    target.read_memory_block8.side_effect = unplug
    try:
        with service._lock:
            memory.check_connection()
            item = SymbolInfo("position", 0x24000B64, 4, "float", "RW_IRAM2")
            service._watches[item.key] = WatchedVariable(item, "#00ff00")
            service._connection_status = "connected"
            service._debug.execution_state = "running"
            service._next_debug_poll_at = float("inf")
        service._wake.set()
        assert lost.wait(2)
        assert service.state_snapshot()["connectionStatus"] == "disconnected"
        target.read_memory_block8.assert_called_once_with(item.address, 4)
        assert probe._link.connected.call_count == 2
        assert not any(n is EventName.LOG and "采样失败" in p.get("message", "") for n, p in events)
    finally:
        service.close()


@pytest.mark.parametrize("paused,watch,cleanup_fails", [(False, True, False),
                                                       (True, True, False),
                                                       (False, False, False),
                                                       (False, True, True)])
def test_unplug_auto_disconnects_once_preserves_recording_and_allows_reconnect(
        tmp_path, paused, watch, cleanup_fails):
    memory, probe = memory_backend()
    events = []
    lost = threading.Event()
    def emit(name, payload):
        events.append((name, payload))
        if name is EventName.ERROR and payload.get("code") == "probe_disconnected":
            lost.set()
    normal, plus = _FakeRtt(), _FakeRtt()
    service = BackendService(emit, memory_backend=memory, recording_directory=tmp_path,
                             normal_rtt_backend=normal, plus_rtt_backend=plus)
    session, target = memory.session, memory.target
    normal.stop = Mock(side_effect=RuntimeError("RTT stop failed") if cleanup_fails else None)
    plus.stop = Mock()
    probe.close.side_effect = OSError("USB close failed") if cleanup_fails else None
    try:
        item = SymbolInfo("position", 0x24000B64, 4, "float", "RW_IRAM2")
        with service._lock:
            service._watches[item.key] = WatchedVariable(item, "#00ff00")
            service._queue_samples_locked([(0.1, {item.key: 1.0})])
            service._flush_pending_samples_locked()
            service._recording_worker.drain()
            path, count = service._recording.path, service._recording.sample_count
            service._connection_status = "connected"
            service._sampling_paused = paused
            service._debug.execution_state = "running"
            service._debug.registers = {"pc": 0x08000100}
            service._debug.stopped_location = {"address": 0x08000100}
            if not watch:
                service._watches.clear()
            probe._link.connected.return_value = False
        service._wake.set()
        assert lost.wait(2), "Probe loss was not detected by the running sampler"
        with service._lock:
            assert service._connection_status == "disconnected"
            assert service._sampling_paused
            assert not service._rtt_enabled
            assert service._debug.execution_state == "unavailable"
            assert service._debug.registers == {}
            assert service._debug.stopped_location is None
            assert service._recording.path == path and path.is_file()
            assert service._recording.sample_count == count == 1
            assert not service._handle_connection_failure_locked(ProbeDisconnected("already handled"))
        assert service._sampler.is_alive()
        assert sum(n is EventName.ERROR and p.get("code") == "probe_disconnected" for n, p in events) == 1
        assert not any(n is EventName.LOG and "本地调试探针连接已中断" in p.get("message", "")
                       for n, p in events), "The ERROR event already creates the frontend log entry"
        probe.close.assert_called_once()
        plus.stop.assert_called_once()
        session.close.assert_not_called()
        target.read_memory_block8.assert_not_called()
        states = [p for n, p in events if n is EventName.STATE]
        assert any(p.get("connectionStatus") == "disconnected" and p.get("samplingPaused") for p in states)
        # Reinsertion is inert until the user explicitly connects again.
        probe._link.connected.return_value = True
        probe.close.side_effect = None
        normal.stop.side_effect = None
        with patch("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", return_value=[probe]), \
                patch("pyocd.core.session.Session", return_value=Mock(target=target, probe=probe)):
            result = service.handle(RpcMethod.CONNECT, {})
        assert result["state"]["connectionStatus"] == "connected"
    finally:
        normal.stop.side_effect = None
        probe.close.side_effect = None
        service.close()
