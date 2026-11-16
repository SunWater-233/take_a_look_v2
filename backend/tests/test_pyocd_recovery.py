from concurrent.futures import ThreadPoolExecutor
import threading
import time
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest
from pylink.errors import JLinkException
from pyocd.core.exceptions import TransferFaultError, TransferTimeoutError
from pyocd.coresight.dap import DebugPort
from pyocd.probe.debug_probe import DebugProbe
from pyocd.probe.jlink_probe import JLinkProbe

from take_a_look_backend.backends.pyocd_compat import guard_dap_error_recovery
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import ProtocolError


class Link:
    def __init__(self, *, read_fails=True, recovery_fails=True):
        self.read_fails, self.recovery_fails = read_fails, recovery_fails
        self.reads, self.writes = [], []

    def target_connected(self):
        return False

    def coresight_read(self, register, ap):
        self.reads.append((register, ap))
        if self.read_fails:
            raise JLinkException("Unspecified error.")
        return 0x12345678

    def coresight_write(self, register, data, ap):
        self.writes.append((register, data, ap))
        if self.recovery_fails and not ap and register == 0:
            raise JLinkException("Unspecified error.")


def make_target(**kwargs):
    # Exercise the real J-Link exception conversion and pyOCD DebugPort without
    # opening USB, halting the MCU, or changing its memory.
    probe = JLinkProbe.__new__(JLinkProbe)
    DebugProbe.__init__(probe)
    probe._is_open = True
    probe._protocol = DebugProbe.Protocol.SWD
    probe._link = Link(**kwargs)
    target = SimpleNamespace(session=Mock())
    target.dp = DebugPort(probe, target)
    target.dp._cached_dp_select = 0
    return target, probe


@pytest.mark.parametrize("recovery_fails", [False, True])
def test_jlink_transfer_fault_stays_bounded_and_releases_probe_lock(recovery_fails):
    target, probe = make_target(recovery_fails=recovery_fails)
    guard_dap_error_recovery(target)
    for _ in range(3):
        target.dp._cached_dp_select = 0
        before = len(probe._link.writes)
        with pytest.raises(TransferFaultError, match="Unspecified error") as caught:
            target.dp.read_ap(0x0C)
        assert len(probe._link.writes) - before == 1
        assert bool(getattr(caught.value, "__notes__", [])) == recovery_fails
        # A different thread must be able to acquire the RLock after failure.
        def acquire_and_release():
            acquired = probe._lock.acquire(timeout=0.2)
            if acquired:
                probe._lock.release()
            return acquired
        with ThreadPoolExecutor(max_workers=1) as executor:
            assert executor.submit(acquire_and_release).result(timeout=1)


def test_timeout_recovery_keeps_the_original_error_and_can_later_read():
    target, probe = make_target()
    guard_dap_error_recovery(target)
    original = TransferTimeoutError("original WAIT timeout")
    with patch.object(probe, "read_ap", side_effect=original):
        with pytest.raises(TransferTimeoutError) as caught:
            target.dp.read_ap(0x0C)
    assert caught.value is original
    assert len(probe._link.writes) == 1
    assert "恢复失败" in original.__notes__[0]
    probe._link.read_fails = probe._link.recovery_fails = False
    assert target.dp.read_ap(0x0C) == 0x12345678


def test_guard_is_idempotent_and_independent_for_each_session():
    first, first_probe = make_target()
    second, second_probe = make_target()
    for target in (first, second):
        guard_dap_error_recovery(target)
        handler = target.dp._handle_error
        guard_dap_error_recovery(target)
        assert target.dp._handle_error is handler
        with pytest.raises(TransferFaultError):
            target.dp.read_ap(0x0C)
    assert len(first_probe._link.writes) == len(second_probe._link.writes) == 1
    guard_dap_error_recovery(None)
    guard_dap_error_recovery(SimpleNamespace())


def test_connect_guards_discovery_before_open_and_retains_h723_8mhz_configuration():
    target, probe = make_target()
    session = Mock(target=target)
    session.open.side_effect = lambda: target.dp.read_ap(0x0C)
    memory = PyOcdMemoryBackend()
    with patch("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", return_value=[probe]), \
            patch("pyocd.core.session.Session", return_value=session) as session_type:
        with pytest.raises(TransferFaultError):
            memory.connect(PyOcdConnectionConfig("stm32h723xx", 8_000_000))
    assert session_type.call_args.kwargs["options"]["frequency"] == 8_000_000
    assert session_type.call_args.kwargs["options"]["target_override"] == "stm32h723xx"
    session.close.assert_called_once()
    assert not memory._owns_target_registry
    assert not memory.is_connected
    assert len(probe._link.writes) == 1


@pytest.mark.parametrize("entry", ["single", "coalesced", "deferred_queue", "deferred_resolve"])
def test_memory_read_failure_reports_the_exact_range_and_keeps_its_cause(entry):
    memory = PyOcdMemoryBackend()
    fault = TransferFaultError("original read fault")
    first = SymbolInfo("first", 0x24000000, 4, "uint32_t", ".data")
    second = SymbolInfo("second", 0x24000040, 4, "uint32_t", ".data")
    reads = []

    def block_read(address, size):
        reads.append((address, size))
        raise fault

    def scalar_read(address, transfer_size, now):
        reads.append((address, transfer_size))
        if entry == "deferred_queue" and address == second.address:
            raise fault
        def resolve():
            if address == second.address:
                raise fault
            return 1
        return resolve

    target = SimpleNamespace(read_memory_block8=block_read)
    if entry.startswith("deferred"):
        target.read_memory = scalar_read
    memory.target = target
    with pytest.raises(ProtocolError) as caught:
        if entry == "single":
            memory.read_symbol(first)
        else:
            memory.read_symbols([first] if entry == "coalesced" else [first, second])
    expected_address = second.address if entry.startswith("deferred") else first.address
    assert caught.value.code == "memory_read_failed"
    assert f"0x{expected_address:08X}" in str(caught.value)
    assert "4 字节" in str(caught.value)
    assert caught.value.__cause__ is fault
    assert memory.last_read_metrics["byte_count"] == 0
    assert len(reads) == (2 if entry.startswith("deferred") else 1)


def test_real_mem_ap_block_read_retains_fault_address_after_recovery_failure():
    from pyocd.coresight.ap import APv1Address, MEM_AP

    target, probe = make_target()
    guard_dap_error_recovery(target)
    ap = MEM_AP(target.dp, APv1Address(0), 0)
    ap._transfer_sizes = {8, 16, 32}
    memory = PyOcdMemoryBackend()
    memory.target = SimpleNamespace(selected_core=SimpleNamespace(ap=ap),
                                    read_memory_block8=ap.read_memory_block8)
    item = SymbolInfo("value", 0x24000000, 4, "uint32_t", ".data")
    with pytest.raises(ProtocolError) as caught:
        memory.read_symbols([item])
    cause = caught.value.__cause__
    assert isinstance(cause, TransferFaultError)
    assert cause.fault_address == item.address
    assert cause.fault_length == 4
    assert 1 <= len(probe._link.writes) < 10


def assert_probe_unlocked(probe):
    def acquire_and_release():
        acquired = probe._lock.acquire(timeout=0.2)
        if acquired:
            probe._lock.release()
        return acquired
    with ThreadPoolExecutor(max_workers=1) as executor:
        assert executor.submit(acquire_and_release).result(timeout=1)


@pytest.mark.parametrize("operation", ["ap_read", "ap_read_multiple", "ap_write",
                                       "dp_read", "dp_write"])
def test_select_write_failure_releases_lock_before_next_thread_can_disconnect(operation):
    target, probe = make_target(read_fails=False, recovery_fails=False)
    guard_dap_error_recovery(target)
    # A transfer fault invalidates SELECT. The next read must select the AP
    # again; failing here used to leak a lock before did_lock was assigned.
    target.dp._cached_dp_select = None
    original_write = probe._link.coresight_write
    def fail_select(register, data, ap):
        if not ap and register == 2:
            raise JLinkException("Unspecified error.")
        return original_write(register, data, ap)
    probe._link.coresight_write = fail_select
    calls = {
        "ap_read": lambda: target.dp.read_ap(0x0C),
        "ap_read_multiple": lambda: target.dp.read_ap_multiple(0x0C, 1),
        "ap_write": lambda: target.dp.write_ap(0x0C, 1),
        "dp_read": lambda: target.dp.read_dp(0x04),
        "dp_write": lambda: target.dp.write_dp(0x04, 1),
    }
    for _ in range(3):
        with pytest.raises(TransferFaultError):
            calls[operation]()
        assert_probe_unlocked(probe)
    probe._link.coresight_write = original_write
    with ThreadPoolExecutor(max_workers=1) as executor:
        assert executor.submit(target.dp.read_ap, 0x0C).result(timeout=1) == 0x12345678


@pytest.mark.parametrize("failure_stage", ["queue", "resolve"])
def test_deferred_batch_failure_drains_all_real_dp_callbacks(failure_stage):
    from pyocd.coresight.ap import APv1Address, MEM_AP

    target, probe = make_target(read_fails=False, recovery_fails=False)
    guard_dap_error_recovery(target)
    ap = MEM_AP(target.dp, APv1Address(0), 0)
    ap._transfer_sizes = {8, 16, 32}
    memory = PyOcdMemoryBackend()
    memory.target = SimpleNamespace(selected_core=SimpleNamespace(ap=ap), read_memory=ap.read_memory)
    items = [SymbolInfo(f"value{i}", 0x24000B64 + i * 0x40, 4, "uint32_t", ".data")
             for i in range(3)]
    original_read = probe.read_ap
    queued, resolved = [], []
    def read_ap(address, now=True):
        index = len(queued)
        queued.append(index)
        if failure_stage == "queue" and index == 2:
            raise TransferFaultError("queue fault")
        callback = original_read(address, now=False)
        def resolve():
            resolved.append(index)
            value = callback()
            if failure_stage == "resolve" and index == 0:
                raise TransferFaultError("resolve fault")
            return value
        return resolve() if now else resolve
    probe.read_ap = read_ap
    with pytest.raises(ProtocolError, match=f"{failure_stage} fault") as caught:
        memory.read_symbols(items)
    assert f"0x{items[2 if failure_stage == 'queue' else 0].address:08X}" in str(caught.value)
    assert resolved == ([0, 1] if failure_stage == "queue" else [0, 1, 2])
    assert_probe_unlocked(probe)


def test_sampler_fault_does_not_block_pause_disconnect_or_reconnect(tmp_path):
    from pyocd.coresight.ap import APv1Address, MEM_AP
    from take_a_look_backend.models import WatchedVariable
    from take_a_look_backend.protocol import EventName, RpcMethod
    from take_a_look_backend.service import BackendService
    from test_service import _FakeRtt

    target, probe = make_target(read_fails=False, recovery_fails=False)
    guard_dap_error_recovery(target)
    ap = MEM_AP(target.dp, APv1Address(0), 0)
    ap._transfer_sizes = {8, 16, 32}
    target.selected_core = SimpleNamespace(ap=ap)
    target.read_memory_block8 = ap.read_memory_block8
    target.get_state = lambda: (target.dp.read_dp(0), "running")[1]
    memory = PyOcdMemoryBackend()
    session = SimpleNamespace(probe=probe, close=Mock(side_effect=lambda: target.dp.read_dp(0)))
    memory.target, memory.session = target, session
    fault_seen = threading.Event()
    def event(name, payload):
        if name is EventName.LOG and "采样失败" in payload.get("message", ""):
            fault_seen.set()
    service = BackendService(event, memory_backend=memory, recording_directory=tmp_path,
                             normal_rtt_backend=_FakeRtt(), plus_rtt_backend=_FakeRtt())
    original_write = probe._link.coresight_write
    def fail_select(register, data, ap):
        if not ap and register == 2:
            raise JLinkException("Unspecified error.")
        return original_write(register, data, ap)
    probe._link.coresight_write = fail_select
    try:
        item = SymbolInfo("position", 0x24000B64, 4, "float", "RW_IRAM2")
        with service._lock:
            service._connection_status = "connected"
            service._reconcile_acquisition_clock_locked()
            service._debug.execution_state = "running"
            service._next_debug_poll_at = float("inf")
            service._watches[item.key] = WatchedVariable(item, "#00ff00")
            target.dp._cached_dp_select = None
        service._wake.set()
        assert fault_seen.wait(2), "The real sampler did not encounter the injected fault"
        assert_probe_unlocked(probe)
        with ThreadPoolExecutor(max_workers=1) as controls:
            paused = controls.submit(service.handle, RpcMethod.SET_SAMPLING_PAUSED,
                                     {"paused": True}).result(timeout=2)
            assert paused["state"]["samplingPaused"]
            disconnected = controls.submit(service.handle, RpcMethod.DISCONNECT, {}).result(timeout=2)
            assert disconnected["state"]["connectionStatus"] == "disconnected"
            session.close.assert_called_once()
            assert not memory.is_connected
            probe._link.coresight_write = original_write
            with patch("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", return_value=[probe]), \
                    patch("pyocd.core.session.Session", return_value=Mock(target=target, probe=probe)):
                connected = controls.submit(service.handle, RpcMethod.CONNECT, {}).result(timeout=2)
            assert connected["state"]["connectionStatus"] == "connected"
            read = controls.submit(service.handle, RpcMethod.READ_WATCH,
                                   {"key": item.key}).result(timeout=2)
            assert read["values"][0]["key"] == item.key
            assert read["values"][0]["value"] is not None
    finally:
        service.close()
