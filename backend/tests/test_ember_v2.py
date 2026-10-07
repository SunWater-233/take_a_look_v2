from __future__ import annotations

import asyncio
import hashlib
import heapq
import json
import os
from pathlib import Path
import random
import select
import socket
import socketserver
import struct
import subprocess
import threading
import time

import pytest

from take_a_look_backend.backends.ember_v2 import (
    QuicClient, Subscription, CHUNK, DATA, END, OK, UPLOAD, V2Error, encoded, frame, read_frame,
)
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.backends.ember_transport import EmberClient


@pytest.fixture(scope="module")
def fixture_server():
    suffix = ".exe" if os.name == "nt" else ""
    default = Path(__file__).resolve().parents[2].parent / "EmberMobile" / "target" / "debug" / "examples" / f"loopback{suffix}"
    executable = Path(os.environ.get("EMBER_V2_FIXTURE", str(default)))
    if not executable.is_file():
        pytest.skip("Build EmberMobile: cargo build -p ember-v2 --example loopback")
    process = subprocess.Popen([str(executable), "120"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    try:
        info = json.loads(process.stdout.readline())
        yield info
    finally:
        process.terminate()
        process.communicate(timeout=5)


@pytest.fixture
def client(fixture_server):
    connection = QuicClient("127.0.0.1", fixture_server["v2"], fixture_server["token"])
    try:
        connection.call("rtt_start", {})
        yield connection
    finally:
        connection.close()


def request(latest=False):
    return {"session_id": 1, "rtt_id": 1, "channel": 0, "cursor": 0, "epoch": 1,
            "revision": 0, "latest": latest, "frame_bytes": 8 if latest else 0}


def test_binary_memory_and_push_do_not_block_control(client):
    data = client.call("read_memory", {"session_id": 1, "address": 0, "length": 65536})["data"]
    assert data == bytes(range(256)) * 256
    client.call("rtt_start", {})
    stream = client.subscribe(request())
    total = 0
    latencies = []
    deadline = time.monotonic() + 0.3
    try:
        while time.monotonic() < deadline:
            before = time.perf_counter()
            assert client.call("ping", {})["pong"]
            latencies.append(time.perf_counter() - before)
            chunk = stream.read()
            assert len(chunk) % 8 == 0
            total += len(chunk)
            time.sleep(0.005)
        assert total > 100_000
        assert max(latencies) < 1.0
        assert stream.dropped == 0
    finally:
        stream.close()


def test_streamed_upload_has_one_completion_and_valid_hash(client):
    payload = bytes(range(256)) * 4096
    client.call("firmware_begin", {"size": len(payload)})
    async def send():
        reader, writer = await client._protocol.create_stream()
        writer.write(frame(UPLOAD, encoded({"upload_id": 1, "offset": 0})))
        for offset in range(0, len(payload), 65536):
            writer.write(frame(DATA, payload[offset:offset + 65536]))
            client._protocol.transmit()
            await asyncio.sleep(0)
        writer.write(frame(END, b""))
        writer.write_eof()
        kind, result = await read_frame(reader)
        assert kind == OK
        assert json.loads(result)["received"] == len(payload)
    client.submit(send())
    result = client.call("firmware_finish", {"upload_id": 1})
    assert result["sha256"] == hashlib.sha256(payload).hexdigest()


def test_certificate_pin_and_authentication(fixture_server):
    with pytest.raises(ConnectionError, match="证书"):
        QuicClient("127.0.0.1", fixture_server["v2"], "invalid." + "0" * 64)
    wrong = "invalid-secret." + fixture_server["token"].rsplit(".", 1)[1]
    with pytest.raises((V2Error, ConnectionError, asyncio.IncompleteReadError)):
        QuicClient("127.0.0.1", fixture_server["v2"], wrong)


def test_explicit_tcp_compatibility_accepts_the_new_token(fixture_server, monkeypatch):
    monkeypatch.setenv("EMBER_PROTOCOL", "1")
    client = EmberClient("127.0.0.1", fixture_server["tcp_port"], fixture_server["token"])
    try:
        assert client.call("ping", {})["pong"]
        assert client.protocol_version == 1
    finally:
        client.close()


def test_slow_reliable_consumer_fails_without_unbounded_memory(client):
    stream = client.subscribe(request())
    try:
        time.sleep(0.85)
        with pytest.raises(V2Error, match="缓存"):
            stream.read()
        assert stream._bytes <= 1024 * 1024
        assert client.call("ping", {})["pong"]
    finally:
        stream.close()


def test_latest_reorders_drops_whole_samples_and_rejects_epoch_change():
    stream = Subscription(None, request(True), 4)
    def packet(seq, cursor, value, epoch=1):
        return CHUNK.pack(1, epoch, 0, 0, seq, cursor, 0, 0) + struct.pack("<If", cursor, value)
    stream.receive(packet(1, 0, 1.0))
    stream.receive(packet(3, 16, 3.0))
    stream.receive(packet(2, 8, 2.0))
    assert list(struct.iter_unpack("<If", stream.read())) == [(0, 1.0), (16, 3.0)]
    assert stream.dropped == 8
    stream.receive(packet(4, 24, 4.0, epoch=2))
    with pytest.raises(V2Error, match="代次"):
        stream.read()


def test_v2_bootstrap_never_sends_the_secret_over_tcp(fixture_server):
    observed = []
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                body = json.loads(line)
                observed.append(body)
                self.wfile.write(json.dumps({"id": body["id"], "ok": True,
                                            "result": {"v2": fixture_server["v2"]}}).encode() + b"\n")
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
    worker.start()
    backend = RemoteMemoryBackend("ember", {"host": "127.0.0.1", "gatewayPort": str(server.server_address[1]),
                                            "token": fixture_server["token"]})
    normal = JScopeRttBackend()
    try:
        backend.connect()
        assert backend.client.protocol_version == 2
        assert backend.read_symbol(SymbolInfo("value", 0, 4, "uint32_t", ".data")) == 0x03020100
        backend.client.call("rtt_start", {})
        normal.start(backend.rtt_target)
        frames = []
        deadline = time.monotonic() + 1
        while not frames and time.monotonic() < deadline:
            frames.extend(normal.read_frames(0))
            time.sleep(.005)
        assert frames
        assert all(item["method"] == "v2_info" and item["token"] == "" for item in observed)
        assert normal.transport_name == "EmberMobile v2 QUIC"
    finally:
        normal.stop()
        backend.disconnect()
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


class LossyUdpRelay:
    """Deterministic UDP impairment; introduces real QUIC loss and reordering."""
    def __init__(self, target_port, loss=.01, delay=.005):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 2 * 1024 * 1024)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.setblocking(False)
        self.port = self.socket.getsockname()[1]
        self.remote = ("127.0.0.1", target_port)
        self.loss, self.delay = loss, delay
        self.stop = threading.Event()
        self.upstreams = {}
        self.worker = threading.Thread(target=self.run, daemon=True)
        self.worker.start()

    def run(self):
        randomizer = random.Random(19)
        pending = []
        serial = 0
        while not self.stop.is_set():
            ready, _, _ = select.select([self.socket, *self.upstreams.values()], [], [], .001)
            for incoming in ready:
                packet, address = incoming.recvfrom(65536)
                if incoming is self.socket:
                    if address not in self.upstreams:
                        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
                        upstream.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 2 * 1024 * 1024)
                        upstream.bind(("127.0.0.1", 0))
                        upstream.setblocking(False)
                        self.upstreams[address] = upstream
                    destination, outgoing = self.remote, self.upstreams[address]
                else:
                    destination = next(peer for peer, sock in self.upstreams.items() if sock is incoming)
                    outgoing = self.socket
                if destination is not None and randomizer.random() >= self.loss and len(pending) < 2048:
                    serial += 1
                    heapq.heappush(pending, (time.monotonic() + self.delay + randomizer.random() * .005,
                                            serial, packet, destination, outgoing))
            while pending and pending[0][0] <= time.monotonic():
                _, _, packet, destination, outgoing = heapq.heappop(pending)
                outgoing.sendto(packet, destination)

    def close(self):
        self.stop.set()
        self.worker.join(timeout=2)
        self.socket.close()
        for upstream in self.upstreams.values():
            upstream.close()


def test_quic_control_and_latest_survive_packet_loss_and_reordering(fixture_server):
    relay = LossyUdpRelay(fixture_server["v2"]["port"])
    advertisement = {**fixture_server["v2"], "port": relay.port}
    client = None
    try:
        client = QuicClient("127.0.0.1", advertisement, fixture_server["token"])
        client.call("rtt_start", {})
        stream = client.subscribe(request(True))
        total = 0
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            assert client.call("ping", {})["pong"]
            data = stream.read()
            assert len(data) % 8 == 0
            total += len(data)
        assert total > 0
        assert stream.dropped > 0
        stream.close()
    finally:
        if client is not None:
            client.close()
        relay.close()
