from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest
from pyocd.core.exceptions import ProbeDisconnected
from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
from pyocd.probe.debug_probe import DebugProbe
from pyocd.probe.jlink_probe import JLinkProbe
from pyocd.probe.stlink_probe import StlinkProbe
from pyocd.probe.stlink.usb import STLinkUSBInterface

from take_a_look_backend.backends.probe_presence import (
    ProbePresence, ProbePresenceMonitor, is_probe_disconnect_error,
)
from take_a_look_backend.backends.pyocd_compat import probe_usb_device


def jlink_probe():
    probe = JLinkProbe.__new__(JLinkProbe)
    DebugProbe.__init__(probe)
    probe._link = Mock(spec=["connected", "target_connected"])
    return probe


@pytest.mark.parametrize("result,expected", [
    (True, ProbePresence.PRESENT),
    (False, ProbePresence.MISSING),
    (RuntimeError("unsupported query"), ProbePresence.UNKNOWN),
    (ProbeDisconnected("USB removed"), ProbePresence.MISSING),
])
def test_presence_distinguishes_missing_from_inconclusive_queries(result, expected):
    probe = jlink_probe()
    if isinstance(result, Exception):
        probe._link.connected.side_effect = result
    else:
        probe._link.connected.return_value = result
    monitor = ProbePresenceMonitor()
    assert monitor.check(probe) is expected
    assert monitor.last_error is (result if isinstance(result, Exception) else None)
    probe._link.target_connected.assert_not_called()


def test_force_error_and_reset_bypass_cached_presence(monkeypatch):
    monkeypatch.setattr("take_a_look_backend.backends.probe_presence.perf_counter", lambda: 10.0)
    probe = jlink_probe()
    probe._link.connected.return_value = True
    monitor = ProbePresenceMonitor()
    assert monitor.check(probe) is ProbePresence.PRESENT
    probe._link.connected.return_value = False
    assert monitor.check(probe) is ProbePresence.PRESENT
    assert monitor.check(probe, force=True) is ProbePresence.MISSING
    monitor.reset()
    probe._link.connected.return_value = True
    assert monitor.check(probe) is ProbePresence.PRESENT
    assert monitor.check(probe, error=ConnectionResetError("lost")) is ProbePresence.MISSING
    assert probe._link.connected.call_count == 3


def test_unknown_query_is_retried_after_the_presence_interval(monkeypatch):
    clock = [10.0]
    monkeypatch.setattr("take_a_look_backend.backends.probe_presence.perf_counter", lambda: clock[0])
    probe = jlink_probe()
    probe._link.connected.side_effect = [RuntimeError("busy"), True]
    monitor = ProbePresenceMonitor()
    assert monitor.check(probe) is ProbePresence.UNKNOWN
    clock[0] = 10.9
    assert monitor.check(probe) is ProbePresence.UNKNOWN
    clock[0] = 11.0
    assert monitor.check(probe) is ProbePresence.PRESENT
    assert probe._link.connected.call_count == 2


def test_missing_stlink_private_layout_is_unknown_without_driver_rediscovery():
    probe = StlinkProbe(SimpleNamespace())
    with patch.object(StlinkProbe, "get_probe_with_id", return_value=None) as scan:
        assert ProbePresenceMonitor().check(probe) is ProbePresence.UNKNOWN
    scan.assert_not_called()


@pytest.mark.parametrize("present", [True, False])
def test_hid_cmsis_dap_preserves_driver_presence_queries(present):
    probe = CMSISDAPProbe(SimpleNamespace(_interface=SimpleNamespace(), get_unique_id=lambda: "hid-probe"))
    with patch.object(CMSISDAPProbe, "get_probe_with_id", return_value=object() if present else None) as scan:
        expected = ProbePresence.PRESENT if present else ProbePresence.MISSING
        assert ProbePresenceMonitor().check(probe) is expected
    scan.assert_called_once_with("hid-probe")


def test_pinned_stlink_driver_exposes_the_original_pyusb_device():
    device = SimpleNamespace(idVendor=0x0483, idProduct=0x3748,
                             serial_number="123456789012345678901234",
                             manufacturer="STMicroelectronics", product="STLink")
    with patch("usb.util.dispose_resources"):
        interface = STLinkUSBInterface(device)
    # Exercise the actual pinned USB -> command -> probe constructor chain.
    assert probe_usb_device(StlinkProbe(interface)) is device


def test_cyclic_exception_context_does_not_classify_target_fault_as_usb_loss():
    first, second = RuntimeError("target fault"), RuntimeError("recovery fault")
    first.__context__, second.__context__ = second, first
    assert not is_probe_disconnect_error(first)
