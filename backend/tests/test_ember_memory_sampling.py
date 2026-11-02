"""Memory capture uses real QUIC and the same service/recording path as the app."""
import struct
import csv
import io
import json
import time
from types import SimpleNamespace

import pytest

from test_ember_v2 import fixture_server, client
from take_a_look_backend.backends.ember_v2 import MemorySamples, MEMORY_CHUNK, V2Error
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend, expand_burst_frames
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
    assert samples.read() == [(100, 10, b"abcd"), (400, 10, b"abcd")]
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
        assert all(data == bytes(range(4)) for _, _, data in packets)
        assert all(a[0] < b[0] for a, b in zip(packets, packets[1:]))
        assert len(owner._protocol.subscriptions) == 1
    finally:
        stream.close()
    assert not owner._protocol.subscriptions
    assert stream.stream_id not in owner._protocol._stream_readers


def test_burst_stream_returns_repeat_reads_per_tick(client):
    stream = client.sample_memory(request(), repeat=2)
    try:
        deadline = time.perf_counter() + 3
        packets = []
        while not packets and time.perf_counter() < deadline:
            packets.extend(stream.read())
            time.sleep(.002)
        assert packets
        _, _, data = packets[0]
        # The fixture copies one 4-byte read per repeat.
        assert data == bytes(range(4)) * 2
    finally:
        stream.close()


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
        assert all(a[0] <= b[0] for a, b in zip(frames, frames[1:]))
        assert all(frame.timing["quality"] == "transaction_window" for frame in frames)
        old = backend._memory_samples
        # A 2 kHz request packs two reads per transaction and ticks at 1 kHz.
        assert old.request["repeat"] == 2
        assert old.request["interval_ms"] == 1
        assert "interval_us" not in old.request
        # Falling back to 500 Hz resubscribes without the burst.
        backend.read_sample_frames([symbol], 500, 11.0)
        assert backend._memory_samples is not old
        assert "repeat" not in backend._memory_samples.request
        assert old.stream_id not in old.owner._protocol.subscriptions
        backend.stop_sampling()
        assert not old.owner._protocol.subscriptions
    finally:
        backend.stop_sampling()
        transport._v2 = None  # client fixture owns the connection


class FakeRepeatCapabilities(FakeCapabilities):
    def __init__(self, limit):
        super().__init__(max_speed=True)
        self.memory_repeat_limit = limit


def test_burst_repeat_only_packs_reads_when_a_transaction_cannot_keep_up():
    backend = RemoteMemoryBackend("ember", {})
    symbol = SymbolInfo("value", 0x20000000, 4, "uint32_t", ".data")
    single = ([symbol], (4,))
    # An old gateway, a slow rate and unaligned ranges all keep one read per tick.
    backend.client = FakeRepeatCapabilities(0)
    assert backend._burst_repeat(*single, 2000) == 1
    backend.client = FakeRepeatCapabilities(8)
    assert backend._burst_repeat(*single, 500) == 1
    unaligned = SymbolInfo("odd", 0x20000001, 4, "uint32_t", ".data")
    assert backend._burst_repeat([unaligned], (4,), 2000) == 1
    # 2 kHz needs two reads per transaction; 8 kHz needs eight.
    assert backend._burst_repeat(*single, 2000) == 2
    assert backend._burst_repeat(*single, 4000) == 4
    assert backend._burst_repeat(*single, 20000) == 8
    # Eight words per burst leave no room for a second read in one response packet.
    wide = [SymbolInfo(f"v{index}", 0x20000000 + index * 4, 4, "uint32_t", ".data")
            for index in range(8)]
    assert backend._burst_repeat(wide, (4,) * 8, 2000) == 1


def test_burst_frames_preserve_order_without_inventing_read_times():
    symbol = SymbolInfo("value", 0x20000000, 4, "float", ".data")
    data = struct.pack("<3f", 1.0, 2.0, 3.0)
    frames = expand_burst_frames([symbol], (4,), 10.0, 90, data, 3)
    assert [elapsed for elapsed, _ in frames] == [10.0, 10.0, 10.0]
    assert [frame.timing["index"] for frame in frames] == [0, 1, 2]
    assert all(frame.timing["start"] == 10.0 and frame.timing["end"] == 10.00009 for frame in frames)
    assert [values[symbol.key] for _, values in frames] == [1.0, 2.0, 3.0]


def test_burst_packets_carry_one_timestamp_and_repeat_samples():
    samples = MemorySamples(None, request(), 4, 2)
    samples.receive(MEMORY_CHUNK.pack(1, 100, 40, 0, 1, 2) + b"abcdefgh")
    assert samples.read() == [(100, 40, b"abcdefgh")]
    samples.receive(MEMORY_CHUNK.pack(4, 400, 40, 0, 1, 2) + b"ijklmnop")
    assert samples.dropped_batches == 2
    assert samples.dropped_samples == 4
    assert samples.read_packets() == [(4, 400, 40, b"ijklmnop")]
    with pytest.raises(ConnectionError):
        samples.receive(MEMORY_CHUNK.pack(2, 200, 40, 0, 1, 2) + b"abcd")


class FakeSamples:
    reads = 1
    dropped = 0
    skipped_ticks = 0
    duration_us = 90

    def __init__(self, packets):
        self._packets = packets

    def read_packets(self):
        packets, self._packets = self._packets, []
        return [(index + 1, *packet) for index, packet in enumerate(packets)]

    def close(self):
        pass


class FakeStreamingClient(FakeRepeatCapabilities):
    supports_memory_sampling = True

    def __init__(self, packets):
        super().__init__(8)
        self.packets = packets
        self.subscriptions = []

    def sample_memory(self, request, repeat=1):
        self.subscriptions.append((request, repeat))
        return FakeSamples(list(self.packets))


def test_high_rate_capture_requests_a_burst_and_expands_every_sample():
    symbol = SymbolInfo("value", 0x20000000, 4, "float", ".data")
    client = FakeStreamingClient([
        (100, 90, struct.pack("<2f", 1.0, 2.0)),
        (900, 90, struct.pack("<2f", 3.0, 4.0)),
    ])
    backend = RemoteMemoryBackend("ember", {})
    backend.client = client
    backend.ember = SimpleNamespace(session_id=1, core=0)
    frames = backend.read_sample_frames([symbol], 2000, 5.0)
    request, repeat = client.subscriptions[0]
    assert repeat == 2
    # A 2 kHz request needs the timer to tick 1 kHz, one transaction each.
    assert request["interval_ms"] == 1
    assert request["repeat"] == 2
    assert [values[symbol.key] for _, values in frames] == [1.0, 2.0, 3.0, 4.0]
    assert [round(elapsed, 6) for elapsed, _ in frames] == [
        5.0, 5.0, 5.0008, 5.0008]
    assert [frame.timing["batchSequence"] for frame in frames] == [1, 1, 2, 2]


def test_burst_adaptation_counts_samples_and_drops_instead_of_batches(monkeypatch):
    symbol = SymbolInfo("value", 0x20000000, 4, "float", ".data")
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeStreamingClient([(100, 90, struct.pack("<2f", 1, 2))] * 1000)
    backend.ember = SimpleNamespace(session_id=1, core=0)
    backend._mode_rate = 2000
    clock = backend._mode_window_started
    monkeypatch.setattr("take_a_look_backend.backends.remote_backend.time.perf_counter", lambda: clock + 1)
    backend.read_sample_frames([symbol], 2000, 0)
    assert not backend._sampling_full_speed  # 1000 bursts carry 2000 samples.
    backend._memory_samples.dropped = 3
    backend.read_sample_frames([symbol], 2000, 1)
    assert backend.last_read_metrics["dropped_batches"] == 3
    assert backend.last_read_metrics["dropped_samples"] == 6


def test_repeat_budget_reserves_tar_and_configuration_writes():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeRepeatCapabilities(8)
    symbols = [SymbolInfo(f"v{i}", 0x20000000 + i * 64, 4, "float", ".data") for i in range(3)]
    assert backend._burst_repeat(symbols, (4, 4, 4), 4000) == 2


def test_burst_timer_that_misses_throughput_switches_to_full_speed():
    backend = RemoteMemoryBackend("ember", {})
    backend.client = FakeRepeatCapabilities(8)
    backend._sampling_repeat = 2
    backend._mode_rate = 2000
    backend._evaluate_sampling_mode(2000, 1400)
    assert backend._sampling_full_speed
    # The decision stays one-way at this rate; it cannot flap on later windows.
    backend._evaluate_sampling_mode(2000, 2700)
    assert backend._sampling_full_speed


def test_aligned_unknown_region_falls_back_once_without_masking_other_errors():
    from take_a_look_backend.backends.ember_transport import EmberError
    backend = RemoteMemoryBackend("ember", {})
    client = FakeStreamingClient([(100, 90, struct.pack("<f", 1))])
    def subscribe(request, repeat=1):
        client.subscriptions.append((request, repeat))
        if repeat > 1:
            raise EmberError("invalid_params", "not RAM")
        return FakeSamples(list(client.packets))
    client.sample_memory = subscribe
    backend.client, backend.ember = client, SimpleNamespace(session_id=1, core=0)
    symbol = SymbolInfo("peripheral", 0x40000000, 4, "float", "")
    backend.read_sample_frames([symbol], 2000, 0)
    backend.read_sample_frames([symbol], 2000, 1)
    assert [repeat for _, repeat in client.subscriptions] == [2, 1]


def test_burst_timing_survives_service_recording_csv_and_binary_pipe(tmp_path):
    from take_a_look_backend.stdio import StdioServer
    from take_a_look_backend.services.recording import export_recording_csv
    output = io.BytesIO()
    server = StdioServer(io.StringIO(), output)
    service = server._service
    service._recording.directory = tmp_path
    symbol = SymbolInfo("value", 0x20000000, 4, "float", ".data")
    frames = expand_burst_frames([symbol], (4,), 10.0, 650, struct.pack("<2f", 1, 2), 2, 7)
    try:
        with service._lock:
            service._symbols = {symbol.key: symbol}
        service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": symbol.key}]})
        with service._lock:
            service._queue_samples_locked(frames)
            service._flush_pending_samples_locked()
        source, boundary, count = service._recording.snapshot()
        records = [json.loads(line) for line in source.read_text().splitlines()]
        captured = next(record for record in records if "frames" in record)
        assert count == 2
        assert [row[0] for row in captured["frames"]] == [10.0, 10.0]
        assert captured["timing"] == [frame.timing for frame in frames]
        csv_path = tmp_path / "capture.csv"
        assert export_recording_csv(source, csv_path, boundary) == 2
        with csv_path.open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.DictReader(stream))
        assert [row["timing_index"] for row in rows] == ["0", "1"]
        assert all(row["timing_quality"] == "transaction_window" for row in rows)
        server._output_worker.drain()
        wire = output.getvalue()
        marker = wire.index(b"\x00")
        size = struct.unpack_from("<I", wire, marker + 1)[0]
        payload = wire[marker + 5:marker + 5 + size]
        assert payload[0] == 3
        offset = 23
        for index in range(2):
            assert struct.unpack_from("<dBd", payload, offset) == (10.0, 1, float(index + 1))
            offset += 17
            assert struct.unpack_from("<BQHHdd", payload, offset) == (1, 7, index, 2, 10.0, 10.00065)
            offset += 29
        assert offset == len(payload)
    finally:
        server.close()


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
