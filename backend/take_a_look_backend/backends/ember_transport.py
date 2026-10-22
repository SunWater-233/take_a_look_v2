"""Bounded, persistent client for EmberMobile's version 1 control gateway."""
from __future__ import annotations

import json
import os
import socket
import threading
import time
from typing import Any


class EmberError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"EmberMobile [{code}]: {message}")
        self.code = code


class EmberClient:
    MAX_REQUEST = 8192
    MAX_RESPONSE = 1024 * 1024

    def __init__(self, host: str, port: int, token: str, *, timeout: float = 3.0) -> None:
        if not host.strip() or not token:
            raise ValueError("请填写手机地址和 EmberMobile 本次访问令牌。")
        self.host, self.port, self.token = host.strip(), port, token
        self.timeout = timeout
        self._socket: socket.socket | None = None
        self._buffer = bytearray()
        self._lock = threading.RLock()
        self._next_id = 0
        self._last_used = 0.0
        self._v2 = None

    @property
    def protocol_version(self) -> int:
        return 2 if self._v2 is not None else 1

    def close(self) -> None:
        with self._lock:
            v2, self._v2 = self._v2, None
            if v2 is not None:
                v2.close()
            connection, self._socket = self._socket, None
            self._buffer.clear()
            if connection is not None:
                connection.close()

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        with self._lock:
            if self.token.startswith("pair:") and os.environ.get("EMBER_PROTOCOL") == "1":
                raise ValueError("长期配对凭据只能通过 QUIC 使用，请取消 EMBER_PROTOCOL=1。")
            if self._v2 is None and "." in self.token and os.environ.get("EMBER_PROTOCOL") != "1":
                from take_a_look_backend.backends.ember_v2 import QuicClient
                info = self._legacy_call("v2_info", {})
                v2 = QuicClient(self.host, info.get("v2") or {}, self.token, self.timeout)
                if self._socket is not None:
                    self._socket.close()
                    self._socket = None
                    self._buffer.clear()
                self._v2 = v2
            v2 = self._v2
        if v2 is not None:
            from take_a_look_backend.backends.ember_v2 import V2Error
            try:
                return v2.call(method, params or {})
            except V2Error as error:
                raise EmberError(error.code, str(error)) from error
        return self._legacy_call(method, params)

    def subscribe(self, params: dict):
        return self._v2.subscribe(params) if self._v2 is not None else None

    def upload_bytes(self, upload_id: int, data: bytes, *, progress=None):
        if self._v2 is not None:
            return self._v2.upload_bytes(upload_id, data, progress=progress)
        import base64
        for offset in range(0, len(data), 4096):
            self.call("firmware_chunk", {"upload_id": upload_id, "offset": offset,
                      "data": base64.b64encode(data[offset:offset + 4096]).decode("ascii")})
            if progress is not None:
                progress(min(1.0, (offset + 4096) / len(data)))
        return {"received": len(data)}

    @property
    def supports_memory_batch(self):
        return self._v2 is not None and self._v2._address[1].get("memory_batch") == 1

    @property
    def supports_memory_sampling(self):
        return self._v2 is not None and self._v2._address[1].get("memory_sampling") == 1

    @property
    def supports_memory_microseconds(self):
        return self._v2 is not None and self._v2._address[1].get("memory_sampling_us") == 1

    @property
    def supports_memory_max_speed(self):
        return self._v2 is not None and self._v2._address[1].get("memory_sampling_max_speed") == 1

    @property
    def memory_repeat_limit(self) -> int:
        """Reads of the same ranges the gateway can pack into one transaction."""
        if self._v2 is None:
            return 0
        return int(self._v2._address[1].get("memory_sampling_repeat") or 0)

    def sample_memory(self, request, repeat: int = 1):
        if not self.supports_memory_sampling:
            raise ValueError("请更新手机网关以启用持续内存采样。")
        if repeat > 1 and self.memory_repeat_limit < repeat:
            raise ValueError("请更新手机网关以启用突发采样。")
        from .ember_v2 import V2Error
        try:
            return self._v2.sample_memory(request, repeat=repeat)
        except V2Error as error:
            raise EmberError(error.code, str(error)) from error

    @property
    def memory_burst_word_limit(self) -> int:
        if self._v2 is None:
            return 0
        # Old repeat gateways did not account for TAR writes. Stay conservative.
        return min(8, int(self._v2._address[1].get("memory_sampling_max_words") or 8))

    def _legacy_call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        # A timed-out mutation is never replayed: the phone may have executed it.
        with self._lock:
            if self._socket is not None and time.monotonic() - self._last_used > 8:
                self.close()  # The v1 server closes idle readers after 10 seconds.
            if self._socket is None:
                self._socket = socket.create_connection((self.host, self.port), self.timeout)
                self._socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._next_id += 1
            request = json.dumps({"id": self._next_id, "version": 1, "token": "" if method == "v2_info" else self.token,
                                  "method": method, "params": params or {}},
                                 ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            if len(request) > self.MAX_REQUEST:
                raise ValueError("EmberMobile 请求超过 8192 字节。")
            deadline = time.monotonic() + self.timeout
            try:
                self._socket.settimeout(self.timeout)
                self._socket.sendall(request + b"\n")
                while b"\n" not in self._buffer:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("EmberMobile 响应超时；操作结果可能未知，请刷新状态。")
                    self._socket.settimeout(remaining)
                    chunk = self._socket.recv(min(65536, self.MAX_RESPONSE + 1 - len(self._buffer)))
                    if not chunk:
                        raise ConnectionError("EmberMobile 已断开连接。")
                    self._buffer.extend(chunk)
                    if len(self._buffer) > self.MAX_RESPONSE:
                        raise ValueError("EmberMobile 响应超过大小限制。")
                raw, _, tail = self._buffer.partition(b"\n")
                self._buffer = bytearray(tail)
                response = json.loads(raw)
                if not isinstance(response, dict) or response.get("id") != self._next_id:
                    raise ValueError("EmberMobile 响应 ID 不匹配。")
                if response.get("ok") is not True:
                    error = response.get("error", {})
                    if not isinstance(error, dict):
                        raise ValueError("EmberMobile 错误响应无效。")
                    raise EmberError(str(error.get("code", "unknown")), str(error.get("message", "请求失败")))
                result = response.get("result")
                if not isinstance(result, dict):
                    raise ValueError("EmberMobile 返回了无效结果。")
                return result
            except EmberError:
                raise
            except Exception:
                self.close()
                raise
            finally:
                self._last_used = time.monotonic()
