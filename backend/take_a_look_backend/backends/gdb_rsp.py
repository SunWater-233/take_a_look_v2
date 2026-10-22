"""Read-only, uncached memory access using standard GDB RSP packets.

This connection owns one server socket. It does not attach a second debugger,
implicitly halt/resume the target, install breakpoints, or replay timed-out operations.
"""
from __future__ import annotations

import socket
import select
import threading
import time
import xml.etree.ElementTree as ET

from .gdb_mi import normalize_host


MAX_PACKET = 65536


class GdbRspMemoryTarget:
    def __init__(self, host: str, port: int, *, timeout: float = 3.0) -> None:
        self.timeout = timeout
        self._socket = socket.create_connection((normalize_host(host), port), timeout)
        self._socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._buffer = bytearray()
        self._offset = 0
        self._lock = threading.Lock()
        self._closed = False
        self._state = "unknown"
        self._no_ack = False
        self.packet_size = 1024
        self.ram_ranges: list[tuple[int, int]] = []
        self._other_ranges: list[tuple[int, int]] = []
        try:
            supported = self._request(b"qSupported:QStartNoAckMode+")
            features = supported.decode("ascii").split(";")
            for feature in features:
                if feature.startswith("PacketSize="):
                    self.packet_size = min(MAX_PACKET, int(feature.split("=", 1)[1], 16))
            if self.packet_size < 32:
                raise ConnectionError("GDB Server 返回的 PacketSize 过小。")
            if "QStartNoAckMode+" in features:
                if self._request(b"QStartNoAckMode") == b"OK":
                    self._no_ack = True
            if "qXfer:memory-map:read+" in features:
                self._load_memory_map()
        except Exception:
            self.close()
            raise

    def _read_byte(self, deadline: float) -> int:
        if self._offset == len(self._buffer):
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise TimeoutError("GDB Server 响应超时。")
            self._socket.settimeout(remaining)
            data = self._socket.recv(MAX_PACKET)
            if not data:
                raise ConnectionError("GDB Server 已断开连接。")
            self._buffer = data
            self._offset = 0
        value = self._buffer[self._offset]
        self._offset += 1
        return value

    def _receive(self, deadline: float) -> bytes:
        # Bound chatter as well as packet size: a peer cannot extend a request
        # forever by sending console output, ACKs, or partial packets.
        scanned = 0
        while (value := self._read_byte(deadline)) != ord("$"):
            if value == ord("-"):
                raise ConnectionError("GDB Server 拒绝了请求，未自动重发。")
            scanned += 1
            if scanned > MAX_PACKET or time.perf_counter() >= deadline:
                raise ConnectionError("GDB Server 返回了无效的数据流。")
        wire = bytearray()
        while True:
            value = self._read_byte(deadline)
            if value == ord("#"):
                break
            wire.append(value)
            if len(wire) > MAX_PACKET:
                raise ConnectionError("GDB Server 返回的数据包过大。")
        checksum = bytes([self._read_byte(deadline), self._read_byte(deadline)])
        try:
            valid = int(checksum, 16) == sum(wire) & 255
        except ValueError:
            valid = False
        if not valid:
            raise ConnectionError("GDB Server 返回的数据包校验失败；请重新连接。")
        if not self._no_ack:
            self._socket.sendall(b"+")
        decoded = bytearray()
        cursor = 0
        while cursor < len(wire):
            value = wire[cursor]
            cursor += 1
            if value == ord("}"):
                if cursor == len(wire):
                    raise ConnectionError("GDB Server 返回了不完整的转义数据。")
                value = wire[cursor] ^ 0x20
                cursor += 1
            elif value == ord("*"):
                if not decoded or cursor == len(wire) or not 32 <= wire[cursor] <= 126:
                    raise ConnectionError("GDB Server 返回了无效的重复编码。")
                decoded.extend([decoded[-1]] * (wire[cursor] - 29))
                cursor += 1
                if len(decoded) > MAX_PACKET:
                    raise ConnectionError("GDB Server 返回的解码数据过大。")
                continue
            decoded.append(value)
            if len(decoded) > MAX_PACKET:
                raise ConnectionError("GDB Server 返回的解码数据过大。")
        return bytes(decoded)

    def _stop_reply(self, result: bytes) -> bool:
        if result.startswith((b"T", b"S")):
            self._state = "halted"
            return True
        if result.startswith((b"W", b"X")):
            raise ConnectionError("GDB Server 报告目标已退出。")
        return False

    def _request(self, payload: bytes) -> bytes:
        with self._lock:
            if self._closed:
                raise ConnectionError("GDB 连接已关闭。")
            if len(payload) > self.packet_size:
                raise ValueError("GDB 请求超过服务端 PacketSize。")
            try:
                self._socket.settimeout(self.timeout)
                self._socket.sendall(b"$" + payload + f"#{sum(payload) & 255:02x}".encode())
                deadline = time.perf_counter() + self.timeout
                for _ in range(64):
                    result = self._receive(deadline)
                    if result.startswith(b"O") and result != b"OK":
                        continue  # Standard console output, not a memory reply.
                    if self._stop_reply(result):
                        continue
                    return result
                raise ConnectionError("GDB Server 的控制台输出超过上限。")
            except (OSError, TimeoutError, ConnectionError) as error:
                self.close()
                raise ConnectionError(f"GDB 读取中断，未自动重发，请重新连接：{error}") from error

    def _load_memory_map(self) -> None:
        data = bytearray()
        while len(data) < MAX_PACKET:
            count = min(self.packet_size - 1, 4096)
            result = self._request(f"qXfer:memory-map:read::{len(data):x},{count:x}".encode())
            if not result or result[:1] not in (b"m", b"l"):
                return  # Optional XML is unavailable: merge only exact ranges.
            data.extend(result[1:])
            if result[:1] == b"l":
                try:
                    root = ET.fromstring(data)
                    for region in root.findall("memory"):
                        start = int(region.attrib["start"], 0)
                        length = int(region.attrib["length"], 0)
                        if start >= 0 and length > 0:
                            ranges = self.ram_ranges if region.get("type") == "ram" else self._other_ranges
                            ranges.append((start, start + length))
                except (ET.ParseError, KeyError, ValueError):
                    self.ram_ranges.clear()
                    self._other_ranges.clear()
                return
            if len(result) == 1:
                return

    def range_is_ram(self, address: int, end: int) -> bool:
        return (any(start <= address < end <= stop for start, stop in self.ram_ranges)
                and not any(address < stop and start < end for start, stop in self._other_ranges))

    def read_memory_block8(self, address: int, size: int) -> bytes:
        if address < 0 or size < 0 or address + size > 1 << 64:
            raise ValueError("无效的 GDB 内存读取范围。")
        data = bytearray()
        while len(data) < size:
            count = min(size - len(data), self.packet_size // 2)
            reply = self._request(f"m{address + len(data):x},{count:x}".encode())
            if reply.startswith(b"E.") or (len(reply) == 3 and reply.startswith(b"E")):
                raise RuntimeError("GDB Server 拒绝内存读取；请确认目标支持运行中访问并已正确配置。")
            try:
                block = bytes.fromhex(reply.decode("ascii"))
            except (ValueError, UnicodeError) as error:
                self.close()
                raise ConnectionError("GDB Server 返回了无效的内存数据。") from error
            if len(block) != count:
                self.close()
                raise ConnectionError("GDB Server 未返回完整的内存数据。")
            data.extend(block)
        return bytes(data)

    def get_state(self) -> str:
        if self._closed:
            raise ConnectionError("GDB 连接已关闭。")
        # RSP's '?' reports the last stop reason, not a portable live run state.
        # Only track explicit controls / asynchronous stop replies on this socket.
        with self._lock:
            try:
                if self._offset < len(self._buffer) or select.select([self._socket], [], [], 0)[0]:
                    # A continue in ACK mode may leave just its '+'. Consume it
                    # without waiting for the deferred stop response.
                    self._socket.settimeout(self.timeout)
                    if self._offset == len(self._buffer):
                        data = self._socket.recv(MAX_PACKET)
                        if not data:
                            raise ConnectionError("GDB Server 已断开连接。")
                        self._buffer, self._offset = data, 0
                    while self._offset < len(self._buffer) and self._buffer[self._offset] == ord("+"):
                        self._offset += 1
                    if self._offset < len(self._buffer):
                        result = self._receive(time.perf_counter() + self.timeout)
                        if not self._stop_reply(result):
                            raise ConnectionError("GDB Server 返回了意外的运行控制响应。")
            except (OSError, TimeoutError, ConnectionError) as error:
                self.close()
                raise ConnectionError(str(error)) from error
        return self._state

    def resume(self) -> None:
        if self.get_state() == "running":
            return
        with self._lock:
            try:
                self._socket.settimeout(self.timeout)
                self._socket.sendall(b"$c#63")
                self._state = "running"
            except OSError as error:
                self.close()
                raise ConnectionError("继续运行请求中断，未自动重发。") from error

    def halt(self) -> None:
        if self.get_state() == "halted":
            return
        with self._lock:
            try:
                self._socket.settimeout(self.timeout)
                self._socket.sendall(b"\x03")
                if not self._stop_reply(self._receive(time.perf_counter() + self.timeout)):
                    raise ConnectionError("GDB Server 未确认目标暂停。")
            except (OSError, TimeoutError, ConnectionError) as error:
                self.close()
                raise ConnectionError("暂停目标请求中断，未自动重发。") from error

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._socket.close()

    def _readonly(self, *args, **kwargs):
        raise RuntimeError("当前是只读内存采样模式；单步、复位、写变量或设置断点请切换到断点调试模式。")

    step = reset = reset_and_halt = _readonly
    write_memory_block8 = read_core_registers_raw = set_breakpoint = remove_breakpoint = _readonly
