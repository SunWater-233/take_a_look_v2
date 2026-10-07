"""EmberMobile and GDB adapters for the workstation's typed memory API."""
from __future__ import annotations

import base64
import time
from typing import Any

from take_a_look_backend.backends.ember_transport import EmberClient
from take_a_look_backend.backends.gdb_mi import GdbTarget, normalize_host
from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend


REMOTE_DEFAULTS: dict[str, object] = {
    "host": "127.0.0.1", "gatewayPort": "4242", "gdbPort": "3333",
    "token": "", "gdbPath": "", "core": "0",
    "rttDelivery": "reliable",
}
CONNECTION_KINDS = {"local", "ember", "emberGdb", "gdb"}


def _integer(config: dict[str, object], key: str, minimum: int, maximum: int) -> int:
    raw = config[key]
    if isinstance(raw, bool):
        raise ValueError(f"{key} 必须是整数。")
    try:
        value = int(str(raw), 10)
    except ValueError as error:
        raise ValueError(f"{key} 必须是整数。") from error
    if not minimum <= value <= maximum:
        raise ValueError(f"{key} 必须在 {minimum}..{maximum} 之间。")
    return value


class RemoteMemoryBackend(PyOcdMemoryBackend):
    """Reuse typed codecs/coalesced reads; never enumerate a local USB probe."""

    def __init__(self, kind: str, options: dict[str, object]) -> None:
        super().__init__()
        self.kind = kind
        self.options = {**REMOTE_DEFAULTS, **options}
        self.client: EmberClient | None = None
        self.ember: EmberTarget | None = None
        self.rtt_target: Any | None = None
        self.supports_running_memory = kind == "ember"
        self.supports_memory_write = kind != "ember"
        self.supports_rtt = kind != "gdb"
        self.manages_breakpoint_step = kind != "ember"
        self._owns_gdb = False

    @property
    def is_connected(self) -> bool:
        return self.target is not None

    @property
    def probe(self) -> None:
        return None

    def connect(self, _config: Any = None) -> None:
        host = normalize_host(str(self.options["host"]))
        core = _integer(self.options, "core", 0, 255)
        gdb_port = _integer(self.options, "gdbPort", 1, 65535)
        started = time.perf_counter()
        try:
            if self.kind in {"ember", "emberGdb"}:
                gateway_port = _integer(self.options, "gatewayPort", 1, 65535)
                self.client = EmberClient(host, gateway_port, str(self.options["token"]))
                self.client.call("hello")
                if self.options["rttDelivery"] not in {"reliable", "latest"}:
                    raise ValueError("RTT delivery must be reliable or latest")
                if self.options["rttDelivery"] == "latest" and self.client.protocol_version != 2:
                    raise ValueError("实时优先模式需要 EmberMobile v2 网关。")
                state = self.client.call("backend_state")
                connection = state.get("connection") or {}
                if not connection.get("attached") or not isinstance(connection.get("session_id"), int):
                    raise RuntimeError("请先在手机上授权 USB 探针并连接目标芯片。")
                self.ember = EmberTarget(self.client, connection["session_id"], core,
                                         latest=self.options["rttDelivery"] == "latest")
                if self.client.protocol_version == 2:
                    self.MAX_COALESCED_READ_BYTES = 4096
                self.rtt_target = self.ember
                gdb = state.get("gdb") or {}
                if self.kind == "ember":
                    if gdb.get("running"):
                        raise RuntimeError("手机 GDB 已开启，请选择 EmberMobile + GDB，或先在手机停止 GDB。")
                    self.target = self.ember
                else:
                    if gdb.get("running"):
                        if gdb.get("client"):
                            raise RuntimeError("手机 GDB 已被其他客户端占用。")
                        if gdb.get("port") != gdb_port or gdb.get("core") != core:
                            raise RuntimeError("手机已开启的 GDB 端口或核心与连接设置不一致。")
                    else:
                        self.client.call("gdb_start", {"session_id": self.ember.session_id,
                                                       "core": core, "port": gdb_port})
                        self._owns_gdb = True
            if self.kind in {"emberGdb", "gdb"}:
                self.target = GdbTarget(host, gdb_port, str(self.options["gdbPath"]))
            self.last_connect_timings = {"total_s": time.perf_counter() - started}
        except Exception:
            self.disconnect()
            raise

    def disconnect(self) -> None:
        target, self.target = self.target, None
        try:
            if target is not None and self.manages_breakpoint_step:
                try:
                    target.close()
                except (ConnectionError, RuntimeError, TimeoutError):
                    pass  # close() already terminates the MI process in finally.
        finally:
            if self.ember is not None:
                self.ember.close_rtt()
            if self._owns_gdb and self.client is not None and self.ember is not None:
                try:
                    self.client.call("gdb_stop", {"session_id": self.ember.session_id})
                except Exception:
                    pass
            self._owns_gdb = False
            if self.client is not None:
                self.client.close()
            self.client = None
            self.ember = None
            self.rtt_target = None
            self._read_plan_signature = None
            self._read_plan = ()

    def _require_target(self) -> Any:
        if self.target is None:
            raise RuntimeError("远程目标尚未连接。")
        return self.target


class EmberTarget:
    def __init__(self, client: EmberClient, session_id: int, core: int, *, latest: bool = False) -> None:
        self.client, self.session_id, self.core = client, session_id, core
        self._owned_rtt: int | None = None
        self.latest = latest

    def call(self, method: str, **params: Any) -> dict[str, Any]:
        return self.client.call(method, {"session_id": self.session_id, "core": self.core, **params})

    def read_memory_block8(self, address: int, size: int) -> bytes:
        result = bytearray()
        while len(result) < size:
            count = min(65536 if self.client.protocol_version == 2 else 4096, size - len(result))
            block = self.call("read_memory", address=address + len(result), length=count)
            data = bytes(block["data"])
            if len(data) != count:
                raise RuntimeError("EmberMobile 未返回完整的内存数据。")
            result.extend(data)
        return bytes(result)

    def write_memory_block8(self, _address: int, _values: list[int]) -> None:
        raise RuntimeError("EmberMobile 私有协议不提供内存写入；请选择 EmberMobile + GDB 并暂停目标。")

    def halt(self) -> None:
        self.call("halt")

    def resume(self) -> None:
        self.call("resume")

    def step(self) -> None:
        self.call("step")

    def reset(self) -> None:
        self.close_rtt()
        self.call("reset", halt=False)

    def reset_and_halt(self) -> None:
        self.close_rtt()
        self.call("reset", halt=True)

    def get_state(self) -> str:
        return str(self.call("debug_status")["core"]["state"])

    def set_breakpoint(self, address: int) -> bool:
        self.call("set_breakpoint", address=address)
        return True

    def remove_breakpoint(self, address: int) -> None:
        self.call("clear_breakpoint", address=address)

    def read_core_registers_raw(self, names: list[str]) -> list[int]:
        registers = {item["name"].lower(): int(item["value"]) for item in self.call("read_registers")["registers"]}
        for alias, source in {"sp": "r13", "lr": "r14", "pc": "r15", "xpsr": "psr"}.items():
            if alias not in registers and source in registers:
                registers[alias] = registers[source]
        return [registers[name] for name in names]

    def rtt_state(self) -> dict[str, Any]:
        state = self.client.call("backend_state")
        if (state.get("connection") or {}).get("session_id") != self.session_id:
            raise RuntimeError("手机探针会话已改变，请重新连接。")
        return state.get("rtt") or {}

    def open_rtt(self, address: int | None) -> RemoteRttCapture:
        state = self.rtt_state()
        if not state.get("running"):
            params: dict[str, Any] = {"session_id": self.session_id, "core": self.core}
            if address is not None:
                params["address"] = address
            state = self.client.call("rtt_start", params)
            self._owned_rtt = int(state["rtt_id"])
        if state.get("core") != self.core:
            raise RuntimeError("手机现有 RTT 采集属于另一核心。")
        if address is not None and state.get("address") not in {None, address}:
            raise RuntimeError("手机现有 RTT 地址不同，请先在手机停止该采集。")
        if state.get("state") != "attached":
            raise RuntimeError("手机正在等待 RTT 控制块；请确保目标已运行并初始化 RTT。")
        return RemoteRttCapture(self, state)

    def close_rtt(self) -> None:
        owned, self._owned_rtt = self._owned_rtt, None
        if owned is not None:
            try:
                self.client.call("rtt_stop", {"session_id": self.session_id, "rtt_id": owned})
            except Exception:
                pass


class RemoteRttCapture:
    def __init__(self, target: EmberTarget, state: dict[str, Any]) -> None:
        self.target = target
        self.id = int(state["rtt_id"])
        self.epoch = state.get("epoch")
        self.revision = state.get("search_revision")
        self._last_checked = time.monotonic()
        self.transport_name = "EmberMobile v2 QUIC" if target.client.protocol_version == 2 else "EmberMobile v1 RTT"
        self.up_channels = [RemoteRttUpChannel(self, channel) for channel in state["up_channels"]]
        self.down_channels = [RemoteRttDownChannel(self, channel) for channel in state["down_channels"]]

    def check(self) -> None:
        state = self.target.rtt_state()
        if (state.get("rtt_id") != self.id or state.get("epoch") != self.epoch
                or state.get("search_revision") != self.revision or state.get("state") != "attached"):
            raise RuntimeError("RTT 已复位、重连或改变配置；请重新启动采样，避免拼接不同代次的数据。")
        self._last_checked = time.monotonic()

    def call(self, method: str, **params: Any) -> dict[str, Any]:
        return self.target.client.call(method, {"session_id": self.target.session_id,
                                               "rtt_id": self.id, **params})

    def close(self) -> None:
        for channel in self.up_channels:
            if channel.stream is not None:
                channel.stream.close()
        if self.target._owned_rtt == self.id:
            self.target.close_rtt()


class RemoteRttUpChannel:
    def __init__(self, capture: RemoteRttCapture, descriptor: dict[str, Any]) -> None:
        self.capture = capture
        self.number = int(descriptor["number"])
        self.name = descriptor.get("name", "")
        self.size = int(descriptor.get("buffer_size", 0))
        self.cursor = int(descriptor.get("epoch_start_cursor", 0)) if capture.target.client.protocol_version == 2 else 0
        self.frame_bytes = 0
        self.stream = None

    def set_frame_bytes(self, size: int) -> None:
        if self.capture.target.latest and self.cursor % size:
            raise RuntimeError("当前 RTT 起点未按样本对齐，请在手机重新启动 RTT 或选择可靠传输。")
        self.frame_bytes = size

    def read(self) -> bytes:
        if self.capture.target.client.protocol_version == 2:
            if self.stream is None:
                latest = self.capture.target.latest and self.frame_bytes > 0
                self.stream = self.capture.target.client.subscribe({
                    "session_id": self.capture.target.session_id, "rtt_id": self.capture.id,
                    "channel": self.number, "cursor": self.cursor,
                    "epoch": self.capture.epoch, "revision": self.capture.revision or 0,
                    "latest": latest, "frame_bytes": self.frame_bytes if latest else 0,
                })
            data = self.stream.read()
            self.cursor = self.stream.cursor
            return data
        if time.monotonic() - self.capture._last_checked >= 0.25:
            self.capture.check()
        result = self.capture.call("rtt_read", channel=self.number, cursor=self.cursor, length=4096)
        if "epoch" in result:
            if result["epoch"] != self.capture.epoch:
                raise RuntimeError("目标已复位，RTT 数据代次改变，请重新启动采样。")
        else:
            # Older v1 servers lack the epoch on the read itself.
            self.capture.check()
        if result.get("rtt_id") != self.capture.id or result.get("channel") != self.number:
            raise RuntimeError("RTT 响应通道或采集 ID 不匹配。")
        if result.get("dropped"):
            raise RuntimeError(f"手机 RTT 缓存丢失 {result['dropped']} 字节；请在手机重启 RTT 后重新采样。")
        data = base64.b64decode(result["data"], validate=True)
        if result.get("cursor") != self.cursor or result.get("next_cursor") != self.cursor + len(data):
            raise RuntimeError("RTT 游标不连续，已停止解码。")
        self.cursor += len(data)
        return data


class RemoteRttDownChannel:
    def __init__(self, capture: RemoteRttCapture, descriptor: dict[str, Any]) -> None:
        self.capture = capture
        self.number = int(descriptor["number"])
        self.name = descriptor.get("name", "")

    def write(self, data: bytes, blocking: bool = False) -> int:
        self.capture.check()
        total = 0
        deadline = time.monotonic() + 3.0
        while total < len(data):
            chunk = data[total:total + 4096]
            result = self.capture.call("rtt_write", channel=self.number,
                                       data=base64.b64encode(chunk).decode("ascii"))
            written = int(result["written"])
            if not 0 <= written <= len(chunk):
                raise RuntimeError("RTT 写入长度无效。")
            total += written
            if not blocking or time.monotonic() >= deadline:
                break
            if written == 0:
                time.sleep(0.005)
        return total
