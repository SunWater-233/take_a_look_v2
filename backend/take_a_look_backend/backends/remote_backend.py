"""EmberMobile and GDB adapters for the workstation's typed memory API."""
from __future__ import annotations

import base64
import math
import time
from typing import Any

from take_a_look_backend.backends.ember_transport import EmberClient
from take_a_look_backend.backends.gdb_mi import GdbTarget, normalize_host
from take_a_look_backend.backends.gdb_rsp import GdbRspMemoryTarget
from take_a_look_backend.backends.typed_memory import TypedMemoryBackend, _access_size, decode_symbol_value
from take_a_look_backend.backends.target_backend import capabilities_for_connection


REMOTE_DEFAULTS: dict[str, object] = {
    "host": "127.0.0.1", "gatewayPort": "4242", "gdbPort": "3333",
    "token": "", "gdbPath": "", "core": "0",
    "rttDelivery": "reliable",
    "deviceId": "", "gdbMode": "debug",
}
CONNECTION_KINDS = {"local", "ember", "emberGdb", "gdb"}
# Below this rate the phone's timer is accurate enough and keeps the probe idle
# between samples; above it, back-to-back reads are what the user is asking for.
FAST_SAMPLING_MIN_HZ = 60.0
# Long enough to measure a delivered rate, short enough to settle per rate change.
SAMPLING_MODE_WINDOW_S = 0.75
# Switch to full speed when the timer delivers less than this share of the
# request: at that point back-to-back reads are the closer answer.
ESCALATE_BELOW_FRACTION = 2 / 3


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


class RemoteMemoryBackend(TypedMemoryBackend):
    """Reuse typed codecs/coalesced reads; never enumerate a local USB probe."""

    def __init__(self, kind: str, options: dict[str, object]) -> None:
        super().__init__()
        self.kind = kind
        self.options = {**REMOTE_DEFAULTS, **options}
        self.client: EmberClient | None = None
        self.ember: EmberTarget | None = None
        self.rtt_target: Any | None = None
        self.capabilities = capabilities_for_connection(kind, self.options)
        if kind == "gdb" and self.options["gdbMode"] == "memory":
            self.MAX_COALESCED_GAP_BYTES = 128
        self._owns_gdb = False
        self._memory_samples = None
        self._sampling_signature = None
        self._sampling_origin = None
        self._sampling_elapsed = 0.0
        self._sampling_full_speed = False
        self._phone_read_us = 0.0
        self._phone_read_us_values: list[float] = []
        self._mode_rate = 0.0
        self._mode_settle_windows = 0
        self._mode_window_frames = 0
        self._mode_window_started = time.perf_counter()
        self.sampling_mode = "timed"

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
            if self.options["gdbMode"] not in {"debug", "memory"}:
                raise ValueError("gdbMode 必须是 debug 或 memory。")
            if self.kind == "gdb" and self.options["gdbMode"] == "memory":
                self.target = GdbRspMemoryTarget(host, gdb_port)
                self.last_connect_timings = {"total_s": time.perf_counter() - started}
                return
            if self.kind in {"ember", "emberGdb"}:
                gateway_port = _integer(self.options, "gatewayPort", 1, 65535)
                token = str(self.options["token"])
                if not token and self.options["deviceId"]:
                    from .ember_pairing import PairingStore, discover
                    phone = PairingStore().find(str(self.options["deviceId"]))
                    try:
                        nearby = discover(1)
                    except OSError:
                        nearby = []  # Direct saved endpoints still work without multicast.
                    for found in nearby:
                        if found["id"] == phone["id"]:
                            phone = {**phone, **found}
                            break
                    host, gateway_port, token = phone["host"], int(phone["port"]), phone["token"]
                self.client = EmberClient(host, gateway_port, token)
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
        self.stop_sampling()
        target, self.target = self.target, None
        try:
            if target is not None and (self.manages_breakpoint_step or isinstance(target, GdbRspMemoryTarget)):
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
            self._clear_read_plans()

    def stop_sampling(self):
        samples, self._memory_samples = self._memory_samples, None
        self._sampling_signature = self._sampling_origin = None
        if samples is not None:
            samples.close()

    def _can_merge_read_range(self, address, end):
        if isinstance(self.target, GdbRspMemoryTarget):
            return self.target.range_is_ram(address, end)
        return True

    def read_core_registers(self):
        if isinstance(self.target, GdbRspMemoryTarget):
            return {}  # Memory-only RSP does not assume a CPU register layout.
        return super().read_core_registers()

    @property
    def phone_read_us(self) -> int:
        """Smoothed cost of one phone-side read of the current capture set."""
        return int(self._phone_read_us)

    def _sampling_period(self, rate_hz: float) -> dict:
        """Map the current cadence mode to the phone's SampleRequest.

        The phone's timer is coarser than one probe read on this link and also
        sleeps the remainder of every period, so it can deliver less than half of
        what back-to-back reads achieve. ``_evaluate_sampling_mode`` decides which
        one is delivering closer to the requested rate.
        """
        requested_us = 1e6 / rate_hz if rate_hz > 0 else 0.0
        self.sampling_mode = "full" if self._sampling_full_speed else "timed"
        if self._sampling_full_speed:
            return {"interval_ms": 0}
        if requested_us < 1000 and self.client.supports_memory_microseconds:
            # Sub-millisecond periods are what the microsecond field is for; the
            # millisecond path is the phone's long-standing, better-tested timer.
            return {"interval_ms": 0, "interval_us": max(1, min(60_000_000, math.ceil(requested_us)))}
        return {"interval_ms": max(1, min(60000, math.ceil(requested_us / 1000)))}

    def _evaluate_sampling_mode(self, rate_hz: float, delivered_hz: float) -> None:
        """Pick full speed or a timer from what each mode actually delivers.

        A timer that cannot meet the request is worse than back-to-back reads on
        both counts: fewer samples and irregular ones. The decision is made once
        per requested rate -- escalating is one-way for that rate, so the two
        modes cannot oscillate -- and slow rates keep the timer so the probe is
        not pinned at maximum speed for no benefit.
        """
        if not self.client.supports_memory_max_speed or rate_hz <= 0:
            self._sampling_full_speed = False
            self._mode_rate = rate_hz
            return
        if delivered_hz <= 0:
            return
        if self._mode_rate <= 0 or abs(rate_hz - self._mode_rate) > rate_hz * 0.2:
            # New rate: measure the timer again before preferring full speed, and
            # discard the window that still contains the resubscription.
            self._mode_rate = rate_hz
            self._sampling_full_speed = False
            self._mode_settle_windows = 1
            return
        if self._mode_settle_windows > 0:
            self._mode_settle_windows -= 1
            return
        if self._sampling_full_speed:
            return
        # Prefer whichever mode lands closer to the requested rate: the timer is
        # accurate at low rates but tops out around one read plus its own coarse
        # scheduling, so a big miss means back-to-back reads are the better answer.
        if rate_hz >= FAST_SAMPLING_MIN_HZ and delivered_hz < rate_hz * ESCALATE_BELOW_FRACTION:
            self._sampling_full_speed = True

    def read_sample_frames(self, symbols, rate_hz, elapsed):
        if self.kind != "ember" or not self.client or not self.client.supports_memory_sampling:
            return None
        symbols = tuple(symbols)
        sizes = tuple(_access_size(symbol) for symbol in symbols)
        if not symbols or len(symbols) > 128 or sum(sizes) > 65536:
            self.stop_sampling()
            return None
        period = self._sampling_period(rate_hz)
        signature = (symbols, tuple(period.items()))
        if signature != self._sampling_signature:
            self.stop_sampling()
            self._memory_samples = self.client.sample_memory({
                "read": {"session_id": self.ember.session_id, "core": self.ember.core,
                         "ranges": [{"address": s.address, "length": n} for s, n in zip(symbols, sizes)],
                         "merge": True}, **period})
            self._sampling_signature = signature
            self._sampling_elapsed = elapsed
        samples = self._memory_samples
        from .ember_v2 import V2Error
        from .ember_transport import EmberError
        try:
            packets = samples.read()
        except V2Error as error:
            raise EmberError(error.code, str(error)) from error
        measured = samples.duration_us
        if measured:
            # A median ignores the occasional wedged USB read, which says nothing
            # about the cadence the probe can sustain.
            self._phone_read_us_values.append(float(measured))
            del self._phone_read_us_values[:-16]
            ordered = sorted(self._phone_read_us_values)
            self._phone_read_us = ordered[len(ordered) // 2] if len(ordered) >= 4 else 0.0
        self._mode_window_frames += len(packets)
        window = time.perf_counter() - self._mode_window_started
        if window >= SAMPLING_MODE_WINDOW_S:
            delivered = self._mode_window_frames / window
            self._mode_window_frames = 0
            self._mode_window_started = time.perf_counter()
            self._evaluate_sampling_mode(rate_hz, delivered)
        frames = []
        for stamp, data in packets:
            if self._sampling_origin is None:
                self._sampling_origin = stamp
            offset, values = 0, {}
            for symbol, size in zip(symbols, sizes):
                values[symbol.key] = decode_symbol_value(symbol, data[offset:offset + size])
                offset += size
            frames.append((self._sampling_elapsed + (stamp - self._sampling_origin) / 1e6, values))
        self.last_read_metrics = {"symbol_count": len(symbols), "block_count": samples.reads,
            "byte_count": sum(sizes), "dropped_samples": samples.dropped,
            "skipped_ticks": samples.skipped_ticks, "duration_us": samples.duration_us}
        return frames

    def reset(self, halt=False):
        self.stop_sampling()
        super().reset(halt)

    def halt(self):
        self.stop_sampling()
        super().halt()

    def read_symbols(self, symbols):
        if self.kind != "ember" or not self.client or not self.client.supports_memory_batch:
            return super().read_symbols(symbols)
        # Give the phone exact symbol ranges. Its memory map decides which reads
        # can merge; do not fill gaps or coalesce MMIO on the PC.
        symbols = tuple(symbols)
        batches, reads, byte_count = [], 0, 0
        buffers = [bytearray() for _ in symbols]
        batch, size = [], 0
        for index, symbol in enumerate(symbols):
            length = _access_size(symbol)
            for offset in range(0, length, 65536):
                count = min(length - offset, 65536)
                if batch and (len(batch) == 128 or size + count > 65536):
                    batches.append(batch)
                    batch, size = [], 0
                batch.append((index, symbol.address + offset, count))
                size += count
        if batch:
            batches.append(batch)
        epoch = None
        for batch in batches:
            result = self.ember.call("read_memory_batch", ranges=[
                {"address": address, "length": count} for _, address, count in batch], merge=True)
            if epoch is not None and epoch != result["epoch"]:
                raise ConnectionError("批量读取期间目标已复位，请重新连接。")
            epoch = result["epoch"]
            reads += result["reads"]
            for (index, address, count), block in zip(batch, result["ranges"], strict=True):
                if len(block["data"]) != count or block["address"] != address:
                    raise ConnectionError("EmberMobile 未返回完整的批量内存数据。")
                buffers[index].extend(block["data"])
                byte_count += count
        self.last_read_metrics = {"symbol_count": len(symbols), "block_count": reads, "byte_count": byte_count}
        return {symbol.key: decode_symbol_value(symbol, bytes(data)) for symbol, data in zip(symbols, buffers)}

    def set_breakpoint(self, address: int) -> bool:
        # Remote adapters apply changes through their own protocol, without a
        # local pyOCD breakpoint manager or probe write queue.
        return bool(self._require_target().set_breakpoint(address))

    def program_firmware(self, path: str, progress) -> None:
        if not self.capabilities.firmware_download:
            return super().program_firmware(path, progress)
        from .remote_firmware import firmware_image, flash_phone
        data, sections = firmware_image(path)
        target = self._require_target()
        if self.kind == "emberGdb":
            target.program_firmware(path, sections, progress)
        else:
            flash_phone(self.client, self.ember.session_id, path, data, progress)

    def remove_breakpoint(self, address: int) -> None:
        self._require_target().remove_breakpoint(address)

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
