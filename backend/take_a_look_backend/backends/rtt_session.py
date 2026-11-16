"""One RTT transport per target; leases own channels, never the probe itself.

Call under the service's probe lock. RTT reads consume bytes, so a channel may
have only one reader. Releasing a decoder must not stop another decoder's RTT.
"""
from __future__ import annotations

import time
import logging
from typing import Any


class RttSessionManager:
    def __init__(self) -> None:
        self._capture: Any = None
        self._key: tuple | None = None
        self._native: Any = None
        self._leases: set[RttLease] = set()
        self._owners: dict[tuple[bool, int], RttLease] = {}
        self.transport_name = ""

    def open(self, target: Any, address: int | None = None, probe: Any = None) -> "RttLease":
        key = (id(target), address, id(probe))
        if self._capture is not None and key != self._key:
            raise RuntimeError("RTT 会话属于另一目标或地址，请先释放现有通道。")
        if self._capture is None:
            from .j_scope_rtt import _find_native_jlink, _connect_native_jlink_target
            native = _find_native_jlink(probe)
            capture = None
            try:
                if callable(getattr(target, "open_rtt", None)):
                    capture = target.open_rtt(address)
                    self.transport_name = capture.transport_name
                    native = None
                elif native is not None:
                    _connect_native_jlink_target(native, target)
                    native.rtt_start(address)
                    deadline = time.monotonic() + .5
                    while True:
                        try:
                            if native.rtt_get_num_up_buffers() > 0:
                                break
                        except Exception:
                            if time.monotonic() >= deadline:
                                raise
                        if time.monotonic() >= deadline:
                            raise RuntimeError("J-Link 原生 RTT 尚未找到控制块。")
                        time.sleep(.01)
                    capture = _NativeCapture(native)
                    self.transport_name = "J-Link 原生 RTT"
                else:
                    from pyocd.debug.rtt import RTTControlBlock
                    capture = (RTTControlBlock.from_target(target) if address is None
                               else RTTControlBlock.from_target(target, address=address))
                    capture.start()
                    self.transport_name = "pyOCD 内存 RTT"
                self._capture, self._native, self._key = capture, native, key
            except BaseException:
                try:
                    if native is not None:
                        native.rtt_stop()
                    elif capture is not None and callable(getattr(capture, "close", None)):
                        capture.close()
                except Exception:
                    logging.getLogger(__name__).debug('RTT 启动失败后的清理异常', exc_info=True)
                raise
        lease = RttLease(self)
        self._leases.add(lease)
        return lease

    def _claim(self, lease: "RttLease", up: bool, number: int) -> None:
        if lease not in self._leases:
            raise RuntimeError("RTT 会话已关闭，请重新启动采集。")
        key = (up, number)
        owner = self._owners.get(key)
        if owner is not None and owner is not lease:
            raise RuntimeError(f"RTT {'上行' if up else '下行'}通道 {number} 已被另一个消费者占用。")
        self._owners[key] = lease

    def release(self, lease: "RttLease") -> None:
        for key, owner in list(self._owners.items()):
            if owner is lease and key[0] and self._capture is not None:
                for index, channel in enumerate(self._capture.up_channels):
                    if getattr(channel, 'number', index) == key[1] and getattr(channel, 'stream', None) is not None:
                        try:
                            channel.stream.close()
                        except Exception:
                            logging.getLogger(__name__).debug('RTT 通道流清理异常', exc_info=True)
                        channel.stream = None
        self._leases.discard(lease)
        self._owners = {key: owner for key, owner in self._owners.items() if owner is not lease}
        if not self._leases:
            self.close()

    def close(self) -> None:
        capture, native = self._capture, self._native
        self._capture = self._native = self._key = None
        self._leases.clear()
        self._owners.clear()
        try:
            if native is not None:
                native.rtt_stop()
            elif capture is not None and callable(getattr(capture, "close", None)):
                capture.close()
        except Exception:
            logging.getLogger(__name__).debug('RTT 会话清理异常', exc_info=True)


class RttLease:
    def __init__(self, manager: RttSessionManager) -> None:
        self.manager = manager
        self.transport_name = manager.transport_name
        self.native = manager._native is not None
        self.up_channels = [_Channel(self, channel, True, index)
                            for index, channel in enumerate(manager._capture.up_channels)]
        self.down_channels = [_Channel(self, channel, False, index)
                              for index, channel in enumerate(getattr(manager._capture, "down_channels", []))]

    def close(self) -> None:
        self.manager.release(self)


class _Channel:
    def __init__(self, lease: RttLease, channel: Any, up: bool, index: int) -> None:
        self._lease, self._channel, self._up = lease, channel, up
        self.number = getattr(channel, "number", index)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._channel, name)

    def claim(self) -> None:
        self._lease.manager._claim(self._lease, self._up, self.number)

    def read(self) -> bytes:
        self.claim()
        return bytes(self._channel.read())

    def write(self, data: bytes, blocking: bool = False) -> Any:
        self.claim()
        return self._channel.write(data, blocking=blocking)


class _NativeCapture:
    def __init__(self, link: Any) -> None:
        self.up_channels = [_NativeChannel(link, i, True) for i in range(link.rtt_get_num_up_buffers())]
        count = getattr(link, "rtt_get_num_down_buffers", lambda: 0)()
        self.down_channels = [_NativeChannel(link, i, False) for i in range(count)]


class _NativeChannel:
    def __init__(self, link: Any, number: int, up: bool) -> None:
        descriptor = link.rtt_get_buf_descriptor(number, up)
        self.link, self.number = link, number
        self.name = str(getattr(descriptor, "name", "") or "")
        self.size = int(getattr(descriptor, "SizeOfBuffer", 0))

    def read(self) -> bytes:
        return bytes(self.link.rtt_read(self.number, 1024 * 1024))

    def write(self, data: bytes, blocking: bool = False) -> int:
        offset, deadline = 0, time.monotonic() + 1
        while offset < len(data):
            written = int(self.link.rtt_write(self.number, list(data[offset:])))
            if not 0 <= written <= len(data) - offset:
                raise RuntimeError("RTT 写入返回无效长度。")
            offset += written
            if not blocking or time.monotonic() >= deadline:
                break
            if not written:
                time.sleep(.001)
        return offset
