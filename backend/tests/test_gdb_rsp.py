"""Standard RSP sampling: real TCP, packet boundaries and service lifecycle."""
from __future__ import annotations

import time
import socket
from pathlib import Path

import pytest

from test_gdb_remote import CortexMServer
from take_a_look_backend.backends.gdb_rsp import GdbRspMemoryTarget
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import EventName, RpcMethod
from take_a_look_backend.service import BackendService


class MemoryServer(CortexMServer):
    def __init__(self, *, no_ack=True, packet_size=64, fault=None):
        self.no_ack = no_ack
        self.packet_size = packet_size
        self.fault = fault
        super().__init__(flash=True)

    def dispatch(self, command):
        if command.startswith("qSupported"):
            self.commands.append(command)
            return (f"PacketSize={self.packet_size:x};qXfer:memory-map:read+;qXfer:features:read+;hwbreak+" +
                    (";QStartNoAckMode+" if self.no_ack else ""))
        if command == "QStartNoAckMode":
            self.commands.append(command)
            return "OK"
        if command.startswith("m") and self.fault in {"error", "short", "badhex"}:
            self.commands.append(command)
            return {"error": "E01", "short": "00", "badhex": "zzzzzzzz"}[self.fault]
        if command.startswith("m") and self.fault in {"rle", "bad_rle"}:
            self.commands.append(command)
            return "0* 0* " if self.fault == "rle" else "0*"
        return super().dispatch(command)

    def reply(self, data):
        # Split headers, payload and checksum across distinct writes. TCP may
        # still coalesce them; the client must not assume recv() == one frame.
        payload = data.encode()
        frame = b"$" + payload + f"#{sum(payload) & 255:02x}".encode()
        if self.fault == "checksum" and data and all(c in "0123456789abcdef" for c in data):
            frame = frame[:-2] + b"xx"
        assert self.socket is not None
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.socket.sendall(frame[:2])
        self.socket.sendall(frame[2:-1])
        self.socket.sendall(frame[-1:])

    def run(self):
        try:
            super().run()
        except ConnectionResetError:
            pass  # Closing an inspector socket with an unread ACK is valid.


@pytest.mark.parametrize("no_ack", [True, False])
def test_rsp_memory_no_gdb_process_no_implicit_target_controls_and_packet_splitting(no_ack):
    server = MemoryServer(no_ack=no_ack)
    target = GdbRspMemoryTarget("127.0.0.1", server.port)
    try:
        expected = bytes(range(96))
        server.memory.update({0x20000000 + i: value for i, value in enumerate(expected)})
        assert target.read_memory_block8(0x20000000, len(expected)) == expected
        reads = [c for c in server.commands if c.startswith("m")]
        assert reads == ["m20000000,20", "m20000020,20", "m20000040,20"]
        assert target.range_is_ram(0x20000000, 0x20000090)
        assert not target.range_is_ram(0x40000000, 0x40000004)
        assert target.get_state() == "unknown"
        assert ("QStartNoAckMode" in server.commands) is no_ack
    finally:
        target.close()
        server.close()
    assert not any(c.startswith(("c", "s", "M", "X", "Z", "qRcmd", "D")) for c in server.commands)


def test_rsp_exact_reads_and_verified_ram_gap_coalescing():
    server = MemoryServer(packet_size=1024)
    backend = RemoteMemoryBackend("gdb", {"host": "127.0.0.1", "gdbPort": str(server.port), "gdbMode": "memory"})
    backend.connect()
    try:
        symbols = [SymbolInfo(str(i), 0x20000000 + i * 64, 4, "uint32_t", ".data") for i in range(3)]
        assert len(backend.read_symbols(symbols)) == 3
        assert backend.last_read_metrics["block_count"] == 1
        assert [c for c in server.commands if c.startswith("m")] == ["m20000000,84"]
        backend.target.ram_ranges.clear()
        backend._clear_read_plans()
        backend.read_symbols(symbols)
        assert backend.last_read_metrics["block_count"] == 3
        mmio = [SymbolInfo(str(i), 0x40000000 + i * 64, 4, "uint32_t", "") for i in range(3)]
        backend.read_symbols(mmio)
        assert backend.last_read_metrics["block_count"] == 3
        with pytest.raises(RuntimeError, match="只读"):
            backend.write_symbol(symbols[0], "1")
    finally:
        backend.disconnect()
        server.close()


@pytest.mark.parametrize("fault", ["error", "short", "badhex", "checksum", "bad_rle"])
def test_rsp_failure_does_not_retry_reads_or_fall_back_to_halting(fault):
    server = MemoryServer(fault=fault)
    target = GdbRspMemoryTarget("127.0.0.1", server.port)
    try:
        with pytest.raises((ConnectionError, RuntimeError)):
            target.read_memory_block8(0x20000000, 4)
        assert [c for c in server.commands if c.startswith("m")] == ["m20000000,4"]
    finally:
        target.close()
        server.close()


def test_rsp_run_length_encoded_memory_reply():
    server = MemoryServer(fault="rle")
    target = GdbRspMemoryTarget("127.0.0.1", server.port)
    try:
        assert target.read_memory_block8(0x20000000, 4) == b"\0" * 4
    finally:
        target.close()
        server.close()


def test_service_rsp_capture_pause_monitor_resume_clear_and_disconnect(tmp_path: Path):
    server = MemoryServer(packet_size=1024)
    events = []
    service = BackendService(lambda name, payload: events.append((name, payload)), recording_directory=tmp_path)
    symbol = SymbolInfo("counter", 0x20000000, 4, "uint32_t", ".data")
    with service._lock:
        service._symbols = {symbol.key: symbol}
    try:
        result = service.handle(RpcMethod.CONNECT, {"connectionKind": "gdb", "remoteConfig": {
            "host": "127.0.0.1", "gdbPort": str(server.port), "gdbMode": "memory",
            "gdbPath": "unused-no-GDB-process"}})
        assert result["state"]["connectionCapabilities"]["memorySampling"]
        assert not result["state"]["connectionCapabilities"]["memoryWrite"]
        service.handle(RpcMethod.SET_WATCHES, {"watches": [{"key": symbol.key, "readMode": "capture", "plotted": True}]})
        service.handle(RpcMethod.SET_CONFIG, {"sampleRateHz": 1000})
        deadline = time.perf_counter() + 3
        while not any(name == EventName.SAMPLES for name, _ in events):
            assert time.perf_counter() < deadline
            time.sleep(.01)
        service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
        with service._lock:
            service._flush_pending_samples_locked()
        service._recording_worker.submit(lambda: None).result()
        count = service._recording.sample_count
        time.sleep(.05)
        assert service._recording.sample_count == count
        service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": False})
        deadline = time.perf_counter() + 3
        while service._recording.sample_count == count:
            assert time.perf_counter() < deadline
            time.sleep(.01)
        # Explicit run control works on the same socket; acquisition never sends
        # these operations implicitly and no architecture-specific registers run.
        service.handle(RpcMethod.DEBUG_CONTROL, {"action": "resume"})
        service.handle(RpcMethod.DEBUG_CONTROL, {"action": "halt"})
        assert service._target_execution_state == "halted"
        assert service._stopped_location is None
        service.handle(RpcMethod.DEBUG_CONTROL, {"action": "resume"})
        service.handle(RpcMethod.CLEAR_SAMPLES, {})
        service.handle(RpcMethod.DISCONNECT, {})
    finally:
        service.close()
        server.close()


def test_real_pyocd_gdbserver_negotiation_uncached_reads_and_explicit_resume():
    # The actual installed pyOCD server and its packet I/O run unchanged; only
    # the unavailable physical probe/core are replaced by a memory fixture.
    from types import SimpleNamespace
    from unittest.mock import Mock
    from pyocd.core.session import Session
    from pyocd.core.memory_map import MemoryMap, RamRegion
    from pyocd.core.target import Target
    from pyocd.coresight.cortex_m import CoreArchitecture
    from pyocd.gdbserver.gdbserver import GDBServer

    session = Session(None, auto_open=False, options={
        "gdbserver_port": 0, "telnet_port": 0, "enable_semihosting": False,
        "persist": True, "rtos.enable": False, "cache.enable_memory": False})
    session._inited, session._closed = True, False
    core = Mock()
    core.core_number, core.selected_core = 0, 0
    core.architecture, core.extensions = CoreArchitecture.ARMv7M, []
    core.core_registers.iter_matching.return_value = []
    core.memory_map = MemoryMap(RamRegion(start=0x20000000, length=4096))
    core.get_state.return_value = Target.State.RUNNING
    core.session, core.aps, core.elf = session, {}, None
    context = Mock()
    context.core, context.session = core, session
    context.read_memory_block8.side_effect = [[1, 2, 3, 4], [5, 6, 7, 8]]
    core.get_target_context.return_value = context
    core.cores, core.selected_core_or_raise = {0: core}, core
    session._board = SimpleNamespace(target=core)
    server = GDBServer(session, target_running=True, rtt_config=SimpleNamespace(channels=None))
    server.start()
    target = None
    try:
        target = GdbRspMemoryTarget("127.0.0.1", server.port)
        assert target._no_ack
        assert target.range_is_ram(0x20000000, 0x20000004)
        assert target.read_memory_block8(0x20000000, 4) == bytes([1, 2, 3, 4])
        assert target.read_memory_block8(0x20000000, 4) == bytes([5, 6, 7, 8])
        target.resume()
        deadline = time.perf_counter() + 2
        while not core.resume.called:
            assert time.perf_counter() < deadline
            time.sleep(.005)
        assert target.get_state() == "running"
        assert context.read_memory_block8.call_count == 2
    finally:
        if target is not None:
            target.close()
        server.stop()
        session._inited = False


