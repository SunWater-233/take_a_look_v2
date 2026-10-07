"""Ember v2 QUIC client; network I/O runs independently of sampling and UI."""
from __future__ import annotations

import asyncio
import base64
import collections
from contextlib import suppress
import hashlib
import json
import ssl
import socket
import struct
import threading
import time

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, DatagramFrameReceived, StreamDataReceived, StreamReset

HEADER = struct.Struct("<4sB3xI")
CHUNK = struct.Struct("<8Q")
AUTH, RPC, SUBSCRIBE, UPLOAD, RTT_WRITE, MEMORY_READ = range(1, 7)
OK, DATA, END, ERROR = 128, 129, 130, 255
BLOCK = 65536
MAX_FRAME = BLOCK + 128


class V2Error(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(f"EmberMobile [{code}]: {message}")
        self.code = code


def frame(kind: int, data: bytes) -> bytes:
    if len(data) > MAX_FRAME:
        raise ValueError("v2 frame exceeds limit")
    return HEADER.pack(b"EMB2", kind, len(data)) + data


def encoded(value: dict) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


async def read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    header = await reader.readexactly(HEADER.size)
    magic, kind, size = HEADER.unpack(header)
    if magic != b"EMB2" or header[5:8] != bytes(3) or size > MAX_FRAME:
        raise ConnectionError("Invalid v2 frame")
    data = await reader.readexactly(size)
    if kind == ERROR:
        error = json.loads(data)
        raise V2Error(str(error["code"]), str(error["message"]))
    return kind, data


class _Protocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.subscriptions: dict[int, Subscription] = {}
        self.finished_streams: set[int] = set()
        self.terminated = False

    def connection_made(self, transport):
        super().connection_made(transport)
        connection = transport.get_extra_info("socket")
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 2 * 1024 * 1024)

    def release_reader(self, stream_id):
        self._stream_readers.pop(stream_id, None)
        self.finished_streams.discard(stream_id)

    def quic_event_received(self, event):
        if isinstance(event, StreamDataReceived):
            # All Ember streams are client-initiated. Completed/cancelled RPCs
            # must not recreate readers when a late FIN or retransmission arrives.
            reader = self._stream_readers.get(event.stream_id)
            if reader is None or self.terminated:
                return
            if event.data:
                if event.stream_id in self.finished_streams:
                    reader.set_exception(ConnectionError("QUIC data arrived after stream completion"))
                    return
                reader.feed_data(event.data)
            if event.end_stream:
                self.finished_streams.add(event.stream_id)
                reader.feed_eof()
            return
        if isinstance(event, StreamReset):
            reader = self._stream_readers.get(event.stream_id)
            if reader is not None:
                reader.set_exception(ConnectionError("QUIC stream was reset"))
            return
        if isinstance(event, ConnectionTerminated):
            self.terminated = True
        super().quic_event_received(event)
        if isinstance(event, DatagramFrameReceived) and len(event.data) >= 8:
            stream_id = int.from_bytes(event.data[:8], "little")
            subscription = self.subscriptions.get(stream_id)
            if subscription is not None:
                subscription.receive(event.data[8:])
        elif isinstance(event, ConnectionTerminated):
            for subscription in tuple(self.subscriptions.values()):
                subscription.fail(ConnectionError("QUIC 连接已断开，请重新连接。"))


class Subscription:
    def __init__(self, owner: QuicClient, request: dict, stream_id: int):
        self.owner, self.request, self.stream_id = owner, request, stream_id
        self.latest = bool(request.get("latest"))
        self.cursor = int(request["cursor"])
        self.sequence = 0
        self.dropped = 0
        self._queue = collections.deque()
        self._bytes = 0
        self._lock = threading.Lock()
        self._error: Exception | None = None
        self._ended = False
        self._task: asyncio.Task | None = None

    def fail(self, error: Exception) -> None:
        with self._lock:
            self._error = error
            self._queue.clear()
            self._bytes = 0

    def receive(self, packet: bytes) -> None:
        try:
            if len(packet) < CHUNK.size:
                raise ConnectionError("Truncated RTT chunk")
            rtt_id, epoch, revision, channel, sequence, cursor, _time_us, dropped = CHUNK.unpack_from(packet)
            payload = packet[CHUNK.size:]
            r = self.request
            if (rtt_id, epoch, revision, channel) != (r["rtt_id"], r["epoch"], r["revision"], r["channel"]):
                raise V2Error("stale_rtt", "RTT 会话、代次或通道已改变。")
            with self._lock:
                if self._error or self._ended:
                    return
                if sequence <= self.sequence:
                    if self.latest:
                        return
                    raise ConnectionError("RTT sequence repeated")
                if cursor < self.cursor:
                    raise ConnectionError("RTT cursor moved backwards")
                gap = cursor - self.cursor
                if self.latest:
                    width = r["frame_bytes"]
                    if cursor % width or len(payload) % width:
                        raise ConnectionError("Latest RTT packet is not sample-aligned")
                elif gap or dropped or sequence != self.sequence + 1:
                    raise V2Error("rtt_overflow", "可靠 RTT 流出现数据缺口，已停止解码。")
                self.dropped += gap
                self.sequence = sequence
                self.cursor = cursor + len(payload)
                limit = 64 * 1024 if self.latest else 1024 * 1024
                if not self.latest and self._bytes + len(payload) > limit:
                    raise V2Error("client_overflow", "电脑 RTT 缓存已满，请降低采样量或提高处理速度。")
                while self._queue and self._bytes + len(payload) > limit:
                    _, old = self._queue.popleft()
                    self._bytes -= len(old)
                    self.dropped += len(old)
                self._queue.append((time.monotonic(), payload))
                self._bytes += len(payload)
        except Exception as error:
            self.fail(error)

    async def consume(self, reader: asyncio.StreamReader) -> None:
        try:
            while True:
                kind, payload = await read_frame(reader)
                if kind == END:
                    with self._lock:
                        self._ended = True
                    break
                if kind != DATA or self.latest:
                    raise ConnectionError("Unexpected RTT frame")
                self.receive(payload)
                if self._error:
                    await self.owner._cancel_subscription(self)
                    return
        except asyncio.CancelledError:
            pass
        except Exception as error:
            self.fail(error)
            with suppress(ValueError):
                self.owner._protocol._quic.stop_stream(self.stream_id, 1)
            self.owner._protocol.transmit()

    def read(self) -> bytes:
        with self._lock:
            if self._error:
                raise self._error
            if self.latest:
                while len(self._queue) > 1 and time.monotonic() - self._queue[0][0] > 0.020:
                    _, old = self._queue.popleft()
                    self._bytes -= len(old)
                    self.dropped += len(old)
            result = bytearray()
            while self._queue and len(result) < BLOCK:
                _, data = self._queue.popleft()
                self._bytes -= len(data)
                result.extend(data)
            if self._ended and not result:
                raise V2Error("rtt_stopped", "手机 RTT 采集已停止。")
            return bytes(result)

    def close(self) -> None:
        if self.owner._loop.is_running():
            self.owner.submit(self.owner._cancel_subscription(self))


class QuicClient:
    def __init__(self, host: str, advertisement: dict, token: str, timeout: float = 5.0, *, data_connection=False):
        certificate = base64.b64decode(advertisement["certificate_der"], validate=True)
        expected = token.rsplit(".", 1)[-1]
        if len(expected) != 64 or hashlib.sha256(certificate).hexdigest() != expected:
            raise ConnectionError("手机证书与访问令牌不匹配，未建立连接。")
        if advertisement.get("version") != 2 or advertisement.get("alpn") != "ember/2":
            raise ConnectionError("Unsupported Ember v2 transport")
        self.timeout = timeout
        self._address = (host, dict(advertisement), token)
        self._data_connection = data_connection
        self._data_client: QuicClient | None = None
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, name="ember-quic", daemon=True)
        self._thread.start()
        self._context = None
        self._protocol: _Protocol
        self._closed = False
        try:
            self.submit(self._connect(host, int(advertisement["port"]), certificate, token))
        except Exception:
            self.close()
            raise

    def submit(self, coroutine):
        future = asyncio.run_coroutine_threadsafe(coroutine, self._loop)
        try:
            return future.result(timeout=self.timeout + 1)
        except TimeoutError as error:
            future.cancel()
            raise ConnectionError("QUIC 响应超时；操作结果可能未知，未自动重发。") from error

    async def _connect(self, host: str, port: int, certificate: bytes, token: str):
        config = QuicConfiguration(is_client=True, alpn_protocols=["ember/2"], server_name="ember.local",
                                   cadata=ssl.DER_cert_to_PEM_cert(certificate).encode(), verify_mode=ssl.CERT_REQUIRED,
                                   idle_timeout=15, max_data=2 * 1024 * 1024, max_stream_data=256 * 1024,
                                   max_datagram_frame_size=65536)
        self._context = connect(host, port, configuration=config, create_protocol=_Protocol)
        self._protocol = await asyncio.wait_for(self._context.__aenter__(), self.timeout)
        kind, _ = await self._exchange(AUTH, token.encode())
        if kind != OK:
            raise ConnectionError("Invalid QUIC authentication response")

    async def _exchange(self, kind: int, metadata: bytes, data: bytes | None = None):
        reader, writer = await self._protocol.create_stream()
        stream_id = writer.get_extra_info("stream_id")
        try:
            writer.write(frame(kind, metadata))
            if data is not None:
                writer.write(frame(DATA, data))
            writer.write_eof()
            self._protocol.transmit()
            return await asyncio.wait_for(read_frame(reader), self.timeout)
        except (asyncio.IncompleteReadError, TimeoutError) as error:
            raise ConnectionError("QUIC 响应中断或超时，未重发操作。") from error
        finally:
            with suppress(ValueError):
                self._protocol._quic.stop_stream(stream_id, 0)
            self._protocol.release_reader(stream_id)
            self._protocol.transmit()

    def call(self, method: str, params: dict) -> dict:
        async def operation():
            if method == "read_memory":
                kind, payload = await self._exchange(MEMORY_READ, encoded(params))
                if kind != DATA:
                    raise ConnectionError("Invalid memory response")
                return {"address": params["address"], "data": payload}
            if method == "rtt_write":
                metadata = dict(params)
                payload = base64.b64decode(metadata.pop("data"), validate=True)
                kind, data = await self._exchange(RTT_WRITE, encoded(metadata), payload)
            else:
                kind, data = await self._exchange(RPC, encoded({"method": method, "params": params}))
            if kind != OK:
                raise ConnectionError("Invalid RPC response")
            result = json.loads(data)
            if not isinstance(result, dict):
                raise ConnectionError("Invalid RPC result")
            return result
        if self._closed:
            raise ConnectionError("QUIC client is closed")
        return self.submit(operation())

    def subscribe(self, request: dict) -> Subscription:
        if not self._data_connection:
            return self._data().subscribe(request)
        async def operation():
            reader, writer = await self._protocol.create_stream()
            stream_id = writer.get_extra_info("stream_id")
            subscription = Subscription(self, request, stream_id)
            self._protocol.subscriptions[stream_id] = subscription
            try:
                writer.write(frame(SUBSCRIBE, encoded(request)))
                writer.write_eof()
                self._protocol.transmit()
                kind, _ = await asyncio.wait_for(read_frame(reader), self.timeout)
                if kind != OK:
                    raise ConnectionError("Invalid subscription response")
                subscription._task = asyncio.create_task(subscription.consume(reader))
                return subscription
            except BaseException:
                await self._cancel_subscription(subscription)
                raise
        return self.submit(operation())

    def upload_bytes(self, upload_id: int, data: bytes, offset: int = 0) -> dict:
        if not self._data_connection:
            return self._data().upload_bytes(upload_id, data, offset)
        if not data or len(data) > 64 * 1024 * 1024 or offset < 0:
            raise ValueError("Invalid firmware upload size or offset")
        async def operation():
            reader, writer = await self._protocol.create_stream()
            try:
                writer.write(frame(UPLOAD, encoded({"upload_id": upload_id, "offset": offset})))
                for start in range(0, len(data), BLOCK):
                    writer.write(frame(DATA, data[start:start + BLOCK]))
                    self._protocol.transmit()
                    await asyncio.sleep(0)
                writer.write(frame(END, b""))
                writer.write_eof()
                self._protocol.transmit()
                kind, result = await asyncio.wait_for(read_frame(reader), self.timeout)
                if kind != OK:
                    raise ConnectionError("Invalid upload completion")
                return json.loads(result)
            finally:
                with suppress(ValueError):
                    self._protocol._quic.stop_stream(writer.get_extra_info("stream_id"), 0)
                self._protocol.release_reader(writer.get_extra_info("stream_id"))
                self._protocol.transmit()
        return self.submit(operation())

    def _data(self) -> QuicClient:
        # Isolate congestion/backpressure from interactive control requests.
        # Both connections authenticate independently against the same pinned identity.
        if self._data_client is None or self._data_client._closed or self._data_client._protocol.terminated:
            if self._data_client is not None:
                self._data_client.close()
            self._data_client = QuicClient(*self._address, self.timeout, data_connection=True)
        return self._data_client

    async def _cancel_subscription(self, subscription: Subscription):
        if self._protocol.subscriptions.pop(subscription.stream_id, None) is None:
            return
        with suppress(ValueError):
            self._protocol._quic.stop_stream(subscription.stream_id, 0)
        self._protocol.release_reader(subscription.stream_id)
        self._protocol.transmit()
        if subscription._task is not None and subscription._task is not asyncio.current_task():
            subscription._task.cancel()
            await asyncio.gather(subscription._task, return_exceptions=True)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._data_client is not None:
            self._data_client.close()
            self._data_client = None
        async def cleanup():
            protocol = getattr(self, "_protocol", None)
            if protocol is not None:
                for subscription in tuple(protocol.subscriptions.values()):
                    await self._cancel_subscription(subscription)
            if self._context is not None:
                try:
                    await asyncio.wait_for(self._context.__aexit__(None, None, None), 1)
                except (TimeoutError, RuntimeError):
                    pass
        try:
            self.submit(cleanup())
        finally:
            self._loop.call_soon_threadsafe(self._loop.stop)
            self._thread.join(timeout=2)
            if not self._thread.is_alive():
                self._loop.close()
