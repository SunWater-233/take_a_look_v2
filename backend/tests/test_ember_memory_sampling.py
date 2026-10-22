"""Memory capture uses real QUIC and the same service/recording path as the app."""
import struct
import time

import pytest

from test_ember_v2 import fixture_server, client
from take_a_look_backend.backends.ember_v2 import MemorySamples, MEMORY_CHUNK, V2Error
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import RpcMethod, EventName
from take_a_look_backend.service import BackendService


def request(interval=1):
    return {"read": {"session_id": 1, "core": 0, "ranges": [{"address": 0, "length": 4}]},
            "interval_ms": interval}


class FakeCapabilities:
    def __init__(self, *, microseconds=False, max_speed=False):
        self.supports_memory_sampling = True
        self.supports_memory_microseconds = microseconds
        self.supports_memory_max_speed = max_speed


def test_cadence_escalates_only_when_the_timer_misses_the_request():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeCapabilities(microseconds=True, max_speed=True)
    # A new rate is measured on the timer first: no mode change yet.
    backend._evaluate_sampling_mode(1000, 1000)
    backend._sampling_period(1000)
    assert backend.sampling_mode == "timed"
    # The window that still contains the resubscription is discarded.
    backend._evaluate_sampling_mode(1000, 120)
    backend._sampling_period(1000)
    assert backend.sampling_mode == "timed"
    # The settled timer cannot keep up with a fast request: back-to-back reads win.
    backend._evaluate_sampling_mode(1000, 160)
    backend._sampling_period(1000)
    assert backend.sampling_mode == "full"
    # Staying at that rate keeps the choice: the modes cannot oscillate.
    backend._evaluate_sampling_mode(1000, 160)
    backend._sampling_period(1000)
    assert backend.sampling_mode == "full"


def test_cadence_keeps_the_timer_when_it_meets_the_request():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeCapabilities(microseconds=True, max_speed=True)
    backend._evaluate_sampling_mode(100, 100)
    backend._evaluate_sampling_mode(100, 40)  # dirty resubscription window
    backend._evaluate_sampling_mode(100, 96)  # phone timer is accurate at 100 Hz
    backend._sampling_period(100)
    assert backend.sampling_mode == "timed"
    assert backend._sampling_period(100) == {"interval_ms": 10}


def test_cadence_keeps_the_timer_for_slow_rates_and_old_gateways():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeCapabilities(microseconds=True, max_speed=True)
    backend._evaluate_sampling_mode(50, 49)
    backend._evaluate_sampling_mode(50, 40)
    backend._sampling_period(50)
    assert backend.sampling_mode == "timed"
    older = RemoteMemoryBackend("ember", {})
    older.client = FakeCapabilities(microseconds=True, max_speed=False)
    older._evaluate_sampling_mode(1000, 10)
    older._evaluate_sampling_mode(1000, 10)
    older._sampling_period(1000)
    assert older.sampling_mode == "timed"
    assert older._sampling_period(1000) == {"interval_ms": 1}


def test_cadence_uses_microseconds_only_below_one_millisecond():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeCapabilities(microseconds=True, max_speed=False)
    # 1000 Hz is exactly 1 ms: the millisecond timer is the phone's stable path.
    assert backend._sampling_period(1000) == {"interval_ms": 1}
    assert backend._sampling_period(2000) == {"interval_ms": 0, "interval_us": 500}


def test_memory_packet_validation_and_bounded_capture_queue():
    samples = MemorySamples(None, request(), 4)
    packet = lambda seq, stamp=100, epoch=1: MEMORY_CHUNK.pack(seq, stamp, 10, 0, epoch, 1) + b"abcd"
    samples.receive(packet(1))
    samples.receive(packet(4, 400))
    assert samples.dropped == 2
    assert samples.read() == [(100, b"abcd"), (400, b"abcd")]
    assert samples.read() == []
    for payload in [packet(4), packet(5, 399), packet(5, 500, 2), packet(5)[:-1]]:
        with pytest.raises(ConnectionError):
            samples.receive(payload)
    for seq in range(5, 4101):
        samples.receive(packet(seq, seq * 100))
    with pytest.raises(V2Error, match="缓存"):
        samples.receive(packet(4101, 410100))


def test_memory_stream_is_continuous_and_cancel_releases_reader(client):
    stream = client.sample_memory(request())
    owner = stream.owner
    packets = []
    deadline = time.perf_counter() + 3
    try:
        while len(packets) < 20 and time.perf_counter() < deadline:
            packets.extend(stream.read())
            assert client.call("ping", {})["pong"]
        assert len(packets) >= 20
        assert all(data == bytes(range(4)) for _, data in packets)
        assert all(a[0] < b[0] for a, b in zip(packets, packets[1:]))
        assert len(owner._protocol.subscriptions) == 1
    finally:
        stream.close()
    assert not owner._protocol.subscriptions
    assert stream.stream_id not in owner._protocol._stream_readers


def test_remote_capture_reconfigures_without_polling_and_preserves_phone_time(client):
    from take_a_look_backend.backends.ember_transport import EmberClient
    from take_a_look_backend.backends.remote_backend import EmberTarget
    transport = EmberClient("127.0.0.1", 4242, "fixture")
    transport._v2 = client
    backend = RemoteMemoryBackend("ember", {})
    backend.client = transport
    backend.ember = EmberTarget(transport, 1, 0)
    backend.target = backend.ember
    symbol = SymbolInfo("value", 0, 4, "uint32_t", ".data")
    frames = []
    try:
        deadline = time.perf_counter() + 3
        while len(frames) < 10 and time.perf_counter() < deadline:
            frames.extend(backend.read_sample_frames([symbol], 2000, 10.0))
            time.sleep(.002)
        assert len(frames) >= 10
        assert frames[0][0] == 10.0
        assert all(v[symbol.key] == 0x03020100 for _, v in frames)
        assert all(a[0] < b[0] for a, b in zip(frames, frames[1:]))
        old = backend._memory_samples
        assert old.request["interval_us"] == 500
        backend.read_sample_frames([symbol], 500, 11.0)
        assert backend._memory_samples is not old
        assert old.stream_id not in old.owner._protocol.subscriptions
        backend.stop_sampling()
        assert not old.owner._protocol.subscriptions
    finally:
        backend.stop_sampling()
        transport._v2 = None  # client fixture owns the connection


def test_service_push_recording_pause_clear_resume_and_watch_removal(fixture_server, tmp_path):
    events = []
    service = BackendService(lambda name, value: events.append((name, value)),
                             recording_directory=tmp_path)
    symbol = SymbolInfo("value", 0, 4, "uint32_t", ".data")
    try:
        service.handle(RpcMethod.SET_CONFIG, {"connectionKind": "ember", "sampleRateHz": 2000,
            "remoteConfig": {"host": "127.0.0.1", "gatewayPort": str(fixture_server["tcp_port"]),
                             "token": fixture_server["token"]}})
        with service._lock:
            service._symbols = {symbol.key: symbol}
        service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": symbol.key}]})
        service.handle(RpcMethod.CONNECT, {})
        deadline = time.perf_counter() + 3
        while service._recording.sample_count < 20 and time.perf_counter() < deadline:
            time.sleep(.01)
        assert service._recording.sample_count >= 20
        assert service._memory._memory_samples is not None
        service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
        assert service._memory._memory_samples is None
        service.handle(RpcMethod.CLEAR_SAMPLES, {})
        assert service._recording.sample_count == 0
        service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": False})
        deadline = time.perf_counter() + 3
        while service._recording.sample_count < 10 and time.perf_counter() < deadline:
            time.sleep(.01)
        assert service._recording.sample_count >= 10
        service.handle(RpcMethod.SET_WATCHES, {"watches": []})
        deadline = time.perf_counter() + 1
        while service._memory._memory_samples is not None and time.perf_counter() < deadline:
            time.sleep(.01)
        assert service._memory._memory_samples is None
        assert not [p for n, p in events if n == EventName.LOG and p.get("level") == "error"]
    finally:
        service.close()
