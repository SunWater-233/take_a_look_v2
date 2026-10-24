from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
from pyocd.probe.debug_probe import DebugProbe
from pyocd.probe.jlink_probe import JLinkProbe
from pyocd.probe.stlink_probe import StlinkProbe

from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend


def named_probe(driver, description, serial="29734569"):
    class NamedProbe(driver):
        def __init__(self):
            DebugProbe.__init__(self)

        @property
        def description(self):
            return description

        @property
        def unique_id(self):
            return serial

    return NamedProbe()


@pytest.fixture
def connection(monkeypatch):
    # Mock probes must not depend on optional native libraries on the build host.
    monkeypatch.setattr("pyocd.probe.aggregator.PROBE_CLASSES", {
        "cmsisdap": CMSISDAPProbe,
        "jlink": JLinkProbe,
        "stlink": StlinkProbe,
    })
    enumerate_probes = Mock(return_value=[])
    session = Mock(target=SimpleNamespace(dp=None))
    create_session = Mock(return_value=session)
    monkeypatch.setattr("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", enumerate_probes)
    monkeypatch.setattr("pyocd.core.session.Session", create_session)
    backend = PyOcdMemoryBackend()
    try:
        yield backend, enumerate_probes, create_session
    finally:
        backend.disconnect()


@pytest.mark.parametrize("probe_filter,driver,description,other_driver", [
    ("j-link", JLinkProbe, "Segger SAM-ICE", CMSISDAPProbe),
    ("J-Link", JLinkProbe, "Segger J-Link OB", StlinkProbe),
    ("cmsis-dap", CMSISDAPProbe, "Horco Debug Adapter", JLinkProbe),
    ("st-link", StlinkProbe, "STM32 Discovery", CMSISDAPProbe),
])
@pytest.mark.parametrize("serial", [None, "29734569"])
def test_known_probe_choice_uses_driver_instead_of_product_name(
        connection, probe_filter, driver, description, other_driver, serial):
    backend, enumerate_probes, create_session = connection
    # A different driver advertising the selected name must not win selection.
    misleading = named_probe(other_driver, f"Custom {probe_filter} adapter")
    expected = named_probe(driver, description)
    enumerate_probes.return_value = [misleading, expected]

    backend.connect(PyOcdConnectionConfig(None, 4_000_000, unique_id=serial, probe_filter=probe_filter))

    enumerate_probes.assert_called_once_with(blocking=False, unique_id=serial)
    assert create_session.call_args.args[0] is expected
    create_session.return_value.open.assert_called_once()
    assert backend.is_connected


@pytest.mark.parametrize("probe_filter,other_driver", [
    ("j-link", CMSISDAPProbe),
    ("cmsis-dap", StlinkProbe),
    ("st-link", JLinkProbe),
])
def test_known_probe_choice_rejects_other_drivers_even_with_matching_names(
        connection, probe_filter, other_driver):
    backend, enumerate_probes, create_session = connection
    enumerate_probes.return_value = [named_probe(other_driver, probe_filter)]

    with pytest.raises(RuntimeError, match="没有找到可用的调试探针"):
        backend.connect(PyOcdConnectionConfig(None, 4_000_000, probe_filter=probe_filter))

    create_session.assert_not_called()
    assert not backend.is_connected


def test_automatic_probe_choice_preserves_enumeration_order(connection):
    backend, enumerate_probes, create_session = connection
    first = named_probe(CMSISDAPProbe, "Horco Debug Adapter")
    enumerate_probes.return_value = [first, named_probe(JLinkProbe, "Segger SAM-ICE")]

    backend.connect(PyOcdConnectionConfig(None, 4_000_000))

    assert create_session.call_args.args[0] is first


def test_custom_probe_filter_keeps_case_insensitive_description_matching(connection):
    backend, enumerate_probes, create_session = connection
    expected = named_probe(CMSISDAPProbe, "Horco Debug Adapter")
    enumerate_probes.return_value = [named_probe(JLinkProbe, "Segger SAM-ICE"), expected]

    backend.connect(PyOcdConnectionConfig(None, 4_000_000, probe_filter="hOrCo"))

    assert create_session.call_args.args[0] is expected
