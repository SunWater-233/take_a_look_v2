import threading
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from test_service import _FakeMemory, _FakeRtt


@pytest.fixture
def connection(tmp_path):
    memory, normal, plus = _FakeMemory(), _FakeRtt(), _FakeRtt()
    events = []
    service = BackendService(lambda name, payload: events.append((name, payload)),
                             memory_backend=memory, normal_rtt_backend=normal,
                             plus_rtt_backend=plus, recording_directory=tmp_path)
    try:
        yield service, memory, normal, plus, events
    finally:
        service.close()


@pytest.mark.parametrize("failure", ["buffer", "memory_stream", "normal", "plus", "rtt_session", "probe"])
def test_disconnect_attempts_all_cleanup_steps_and_finishes_state(connection, failure):
    service, memory, normal, plus, events = connection
    service.handle(RpcMethod.CONNECT, {})
    steps = {name: Mock(side_effect=RuntimeError(name) if name == failure else None)
             for name in ("buffer", "memory_stream", "normal", "plus", "rtt_session", "probe")}
    with patch.object(service, "_flush_pending_samples_locked", steps["buffer"]), \
            patch.object(service, "_stop_memory_sampling_locked", steps["memory_stream"]), \
            patch.object(normal, "stop", steps["normal"]), patch.object(plus, "stop", steps["plus"]), \
            patch.object(service._rtt_sessions, "close", steps["rtt_session"]), \
            patch.object(memory, "disconnect", steps["probe"]):
        result = service.handle(RpcMethod.DISCONNECT, {})
    assert result["state"]["connectionStatus"] == "disconnected"
    assert result["state"]["debug"]["executionState"] == "unavailable"
    assert service._debug.registers == {}
    for step in steps.values():
        step.assert_called_once()
    assert any(name is EventName.LOG and payload.get("level") == "warning" for name, payload in events)


def test_failed_connect_rolls_back_without_overwriting_the_original_error(connection):
    service, memory, normal, plus, _ = connection
    original = RuntimeError("target setup failed")
    with patch.object(memory, "connect", side_effect=original), \
            patch.object(memory, "disconnect", side_effect=RuntimeError("close failed")) as disconnect, \
            patch.object(normal, "stop") as stop_normal, patch.object(plus, "stop") as stop_plus:
        with pytest.raises(ProtocolError) as failure:
            service.handle(RpcMethod.CONNECT, {})
    assert failure.value.__cause__ is original
    assert any("close failed" in note for note in original.__notes__)
    disconnect.assert_called_once()
    stop_normal.assert_called_once()
    stop_plus.assert_called_once()
    assert service.state_snapshot()["connectionStatus"] == "disconnected"
    assert service._debug.execution_state == "unavailable"
    assert service.handle(RpcMethod.CONNECT, {})["state"]["connectionStatus"] == "connected"


def test_remote_loss_finalizes_state_even_when_cleanup_fails(connection):
    service, memory, normal, plus, _ = connection
    service.handle(RpcMethod.CONNECT, {})
    with service._lock:
        service._connection_kind = "gdb"
        with patch.object(normal, "stop", side_effect=RuntimeError("RTT failed")), \
                patch.object(plus, "stop") as stop_plus, \
                patch.object(memory, "disconnect", side_effect=OSError("already gone")) as disconnect:
            assert service._handle_connection_failure_locked(ConnectionResetError("lost"))
        service._connection_kind = "local"
        assert service._connection_status == "disconnected"
        assert service._sampling_paused
        assert not service._handle_connection_failure_locked(ConnectionResetError("duplicate"))
    stop_plus.assert_called_once()
    disconnect.assert_called_once()


@pytest.mark.parametrize("close_fails", [False, True])
def test_backend_disconnect_is_idempotent_and_releases_target_registry(close_fails):
    backend = PyOcdMemoryBackend()
    session = SimpleNamespace(close=Mock(side_effect=RuntimeError("uninit failed") if close_fails else None),
                              probe=SimpleNamespace(close=Mock()))
    backend._prepare_target(PyOcdConnectionConfig(None, 1_000_000))
    backend.session, backend.target = session, object()
    if close_fails:
        with pytest.raises(RuntimeError, match="uninit failed"):
            backend.disconnect()
        session.probe.close.assert_called_once()
    else:
        backend.disconnect()
        session.probe.close.assert_not_called()
    assert not backend._owns_target_registry
    assert not backend.is_connected
    backend.disconnect()
    session.close.assert_called_once()
    # The process-wide registry can be acquired by the next connection.
    backend._prepare_target(PyOcdConnectionConfig(None, 1_000_000))
    backend.disconnect()


def test_failed_pyocd_open_preserves_error_when_session_close_also_fails():
    backend = PyOcdMemoryBackend()
    original = RuntimeError("SWD open failed")
    session = Mock(target=SimpleNamespace(dp=None), probe=SimpleNamespace(close=Mock()))
    session.open.side_effect = original
    session.close.side_effect = RuntimeError("uninit failed")
    with patch("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", return_value=[object()]), \
            patch("pyocd.core.session.Session", return_value=session):
        with pytest.raises(RuntimeError) as failure:
            backend.connect(PyOcdConnectionConfig(None, 1_000_000))
    assert failure.value is original
    assert any("uninit failed" in note for note in original.__notes__)
    assert backend.session is None
    assert not backend._owns_target_registry
    session.probe.close.assert_called_once()


def test_service_shutdown_releases_probe_when_rtt_cleanup_fails(connection):
    service, memory, normal, plus, _ = connection
    service.handle(RpcMethod.CONNECT, {})
    with patch.object(normal, "stop", side_effect=RuntimeError("RTT failed")), \
            patch.object(plus, "stop") as stop_plus, patch.object(memory, "disconnect") as disconnect:
        service.close()
        service.close()
    stop_plus.assert_called_once()
    disconnect.assert_called_once()
    assert not service._sampler.is_alive()
    assert service._connection_status == "disconnected"


def test_shutdown_waits_for_an_in_progress_open_before_releasing_resources(connection):
    service, memory, _, _, _ = connection
    opening, release, disconnected = threading.Event(), threading.Event(), threading.Event()
    original_connect, original_disconnect = memory.connect, memory.disconnect
    failures = []
    def connect(config):
        opening.set()
        assert release.wait(2)
        original_connect(config)
    def disconnect():
        disconnected.set()
        original_disconnect()
    def run(action):
        try:
            action()
        except Exception as error:
            failures.append(error)
    opener = threading.Thread(target=lambda: run(lambda: service.handle(RpcMethod.CONNECT, {})))
    closer = threading.Thread(target=lambda: run(service.close))
    with patch.object(memory, "connect", side_effect=connect), \
            patch.object(memory, "disconnect", side_effect=disconnect):
        try:
            opener.start()
            assert opening.wait(1)
            closer.start()
            assert service._shutdown.wait(1)
            service._sampler.join(1)
            assert not disconnected.wait(.05), "Cleanup raced with the open driver call"
        finally:
            release.set()
            opener.join(2)
            if closer.ident is not None:
                closer.join(2)
    assert not opener.is_alive() and not closer.is_alive()
    assert not failures
    assert disconnected.is_set()
    assert memory.connected is None
    assert service._connection_status == "disconnected"


def test_shutdown_does_not_allow_a_new_connection(connection):
    service, memory, _, _, _ = connection
    service.close()
    with patch.object(memory, "connect") as connect:
        with pytest.raises(ProtocolError, match="service_closed"):
            service.handle(RpcMethod.CONNECT, {})
    connect.assert_not_called()
