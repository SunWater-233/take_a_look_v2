"""Advisory host-probe presence checks; never read or control the target."""
from __future__ import annotations

import errno
from enum import Enum
from time import perf_counter
from typing import Any

from take_a_look_backend.backends.pyocd_compat import (
    jlink_probe_connected, probe_usb_device, usb_device_location,
)


class ProbePresence(Enum):
    PRESENT = "present"
    MISSING = "missing"
    UNKNOWN = "unknown"


class ProbePresenceMonitor:
    """Call under the owner's probe lock. Forced/error checks bypass the cache."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._next_check_at = 0.0
        self._presence = ProbePresence.UNKNOWN
        self.last_error: Exception | None = None

    def check(self, probe: Any, *, error: Exception | None = None,
              force: bool = False) -> ProbePresence:
        if error is not None and is_probe_disconnect_error(error):
            self.last_error = error
            self._presence = ProbePresence.MISSING
            return self._presence
        now = perf_counter()
        if not force and now < self._next_check_at:
            return self._presence
        self._next_check_at = now + 1.0
        self.last_error = None
        try:
            self._presence = _query_probe(probe)
        except Exception as check_error:
            self.last_error = check_error
            self._presence = (ProbePresence.MISSING if is_probe_disconnect_error(check_error)
                              else ProbePresence.UNKNOWN)
        return self._presence


def _query_probe(probe: Any) -> ProbePresence:
    from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
    from pyocd.probe.debug_probe import DebugProbe
    from pyocd.probe.jlink_probe import JLinkProbe
    from pyocd.probe.stlink_probe import StlinkProbe

    if isinstance(probe, JLinkProbe):
        # target_connected() does not describe the USB link in CoreSight mode.
        connected = jlink_probe_connected(probe)
        if connected is None:
            return ProbePresence.UNKNOWN
        return ProbePresence.PRESENT if connected else ProbePresence.MISSING
    if isinstance(probe, (CMSISDAPProbe, StlinkProbe)):
        device = probe_usb_device(probe)
        if device is not None:
            return _usb_presence(device)
        if isinstance(probe, StlinkProbe):
            # A changed private driver layout is inconclusive. Do not reopen
            # an ST-Link interface that the active session exclusively owns.
            return ProbePresence.UNKNOWN
        # CMSIS-DAP HID transports use their driver's normal enumeration.
    if isinstance(probe, DebugProbe):
        present = type(probe).get_probe_with_id(probe.unique_id) is not None
        return ProbePresence.PRESENT if present else ProbePresence.MISSING
    return ProbePresence.UNKNOWN


def _usb_presence(device: Any) -> ProbePresence:
    location = usb_device_location(device)
    if location is None:
        return ProbePresence.UNKNOWN
    import usb.core

    # Driver discovery reads descriptors via a second handle. WinUSB rejects
    # that while the session owns the interface. Bus/address scans do not open it.
    try:
        present = any((candidate.bus, candidate.address) == (location.bus, location.address)
                      for candidate in usb.core.find(find_all=True, backend=location.backend,
                                                     idVendor=location.vendor_id,
                                                     idProduct=location.product_id))
    except OSError:
        # A system scan failure, even ENODEV from another device, proves nothing
        # about this session. Direct I/O loss is classified separately above.
        return ProbePresence.UNKNOWN
    return ProbePresence.PRESENT if present else ProbePresence.MISSING


def is_probe_disconnect_error(error: Exception) -> bool:
    from pyocd.core.exceptions import ProbeDisconnected

    seen = set()
    while error is not None and id(error) not in seen:
        seen.add(id(error))
        if isinstance(error, (ProbeDisconnected, ConnectionError)):
            return True
        if isinstance(error, OSError) and (
                error.errno in {errno.ENODEV, errno.ENXIO}
                or getattr(error, "winerror", None) in {6, 1167}):
            return True
        error = error.__cause__ or error.__context__
    return False
