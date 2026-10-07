from __future__ import annotations

import base64
import json
import socketserver
import struct
import threading
from contextlib import contextmanager
from unittest.mock import patch

import pytest

from take_a_look_backend.backends.ember_transport import EmberClient, EmberError
from take_a_look_backend.backends.j_scope_rtt import JScopeRttBackend
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.backends.rtt_plus import JScopeRttPlusBackend
from take_a_look_backend.models import SymbolInfo, WatchedVariable
from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService


class Phone:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.memory = bytearray(range(256)) * 64
        self.data = struct.pack("<If", 1000, 2.5)
        self.down = bytearray()
        self.max_write = 5
        self.bad_response = ""
        self.drop_after = ""
        self.dropped = 0
        self.rtt_running = False
        self.epoch = 2
        self.plus = False
        self.execution = "running"
        self.session_id = 7
        self.breakpoints: set[int] = set()
        self.gdb = {"running": False, "client": None, "port": 3333, "core": 0}

    def rtt(self) -> dict:
        return {"rtt_id": 9, "session_id": self.session_id, "core": 0, "epoch": self.epoch,
                "running": self.rtt_running, "state": "attached" if self.rtt_running else "stopped",
                "search_revision": 0, "address": 0x20001000,
                "up_channels": [{"number": 3, "name": "JScope_Data_t" if self.plus else "JScope_t4f4",
                                 "buffer_size": 1024, "start_cursor": 0, "next_cursor": len(self.data)}],
                "down_channels": [{"number": 7, "name": "JScope_Config", "buffer_size": 1024}]}

    def dispatch(self, request: dict) -> dict:
        method, params = request["method"], request["params"]
        self.calls.append((method, params))
        if request["version"] != 1 or request["token"] != "test-token":
            return {"ok": False, "error": {"code": "unauthorized", "message": "Bad token"}}
        if "session_id" in params and params["session_id"] != self.session_id:
            return {"ok": False, "error": {"code": "stale_session", "message": "Session changed"}}
        core = {"state": self.execution, "id": 0}
        result: dict = {}
        if method == "hello":
            result = {"protocol": 1, "rtt": True}
        elif method == "backend_state":
            result = {"connection": {"session_id": self.session_id, "attached": True, "core": core},
                      "rtt": self.rtt(), "gdb": dict(self.gdb)}
        elif method == "debug_status":
            result = {"core": core}
        elif method == "read_memory":
            offset = params["address"] - 0x20000000
            result = {"data": list(self.memory[offset:offset + params["length"]])}
        elif method in {"halt", "step", "reset"}:
            self.execution = "halted" if method != "reset" or params.get("halt") else "running"
        elif method == "resume":
            self.execution = "running"
        elif method == "read_registers":
            result = {"registers": [{"name": name, "value": 0x08000100 if name == "PC" else 0}
                                    for name in ["R0", "R1", "R2", "R3", "R12", "SP", "LR", "PC", "XPSR"]]}
        elif method == "set_breakpoint":
            self.breakpoints.add(params["address"])
        elif method == "clear_breakpoint":
            self.breakpoints.discard(params["address"])
        elif method == "rtt_start":
            self.rtt_running = True
            result = self.rtt()
        elif method == "rtt_stop":
            self.rtt_running = False
        elif method == "rtt_read":
            assert params["channel"] == 3
            data = self.data[params["cursor"]:params["cursor"] + params["length"]]
            result = {"data": base64.b64encode(data).decode(), "cursor": params["cursor"],
                      "next_cursor": params["cursor"] + len(data), "dropped": self.dropped,
                      "epoch": self.epoch, "rtt_id": 9, "channel": 3, "running": self.rtt_running}
        elif method == "rtt_write":
            assert params["channel"] == 7
            data = base64.b64decode(params["data"])
            written = min(self.max_write, len(data))
            self.down.extend(data[:written])
            if self.plus and len(self.down) >= 24:
                self.data += bytes(256) + struct.pack("<If", 2000, 4.5)
            result = {"written": written, "requested": len(data)}
        elif method == "gdb_start":
            self.gdb.update(running=True, port=params["port"], core=params["core"])
        elif method == "gdb_stop":
            self.gdb["running"] = False
        else:
            raise AssertionError(method)
        return {"ok": True, "result": result}


@contextmanager
def phone_server(phone: Phone):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                request = json.loads(line)
                response = {"id": request["id"], **phone.dispatch(request)}
                if phone.drop_after == request["method"]:
                    return
                if phone.bad_response == "wrong_id":
                    response["id"] += 1
                payload = json.dumps(response).encode() + b"\n"
                # Deliberately split the JSON response across writes.
                self.wfile.write(payload[:5])
                self.wfile.flush()
                self.wfile.write(payload[5:])
                self.wfile.flush()

    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    worker.start()
    try:
        yield {"host": "127.0.0.1", "gatewayPort": str(server.server_address[1]), "token": "test-token"}
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


def test_private_memory_coalescing_debug_and_readonly():
    phone = Phone()
    with phone_server(phone) as options:
        backend = RemoteMemoryBackend("ember", options)
        backend.connect()
        try:
            first = SymbolInfo("one", 0x20000000, 4, "uint32_t", ".data")
            second = SymbolInfo("two", 0x20000008, 4, "uint32_t", ".data")
            values = backend.read_symbols([first, second])
            assert values[first.key] == 0x03020100
            assert values[second.key] == 0x0b0a0908
            assert backend.last_read_metrics["block_count"] == 1
            assert len(backend.target.read_memory_block8(0x20000000, 5000)) == 5000
            assert [p["length"] for m, p in phone.calls if m == "read_memory"] == [12, 4096, 904]
            backend.halt()
            assert backend.debug_state() == "halted"
            assert backend.read_core_registers()["pc"] == 0x08000100
            backend.set_breakpoint(0x08000100)
            assert phone.breakpoints == {0x08000100}
            backend.remove_breakpoint(0x08000100)
            with pytest.raises(RuntimeError, match="不提供内存写入"):
                backend.write_symbol(first, "4")
        finally:
            backend.disconnect()
    assert not phone.breakpoints


def test_authentication_and_stale_session_are_not_retried():
    phone = Phone()
    with phone_server(phone) as options:
        client = EmberClient(options["host"], int(options["gatewayPort"]), "wrong-token")
        with pytest.raises(EmberError, match="unauthorized"):
            client.call("hello")
        client.close()
        backend = RemoteMemoryBackend("ember", options)
        backend.connect()
        phone.session_id += 1
        with pytest.raises(EmberError, match="stale_session"):
            backend.halt()
        backend.disconnect()
    assert sum(method == "halt" for method, _ in phone.calls) == 1


def test_ambiguous_mutation_is_not_replayed_and_bad_ids_close_socket():
    phone = Phone()
    with phone_server(phone) as options:
        client = EmberClient(options["host"], int(options["gatewayPort"]), options["token"])
        phone.drop_after = "halt"
        with pytest.raises(ConnectionError):
            client.call("halt", {"session_id": 7, "core": 0})
        assert phone.execution == "halted"
        assert sum(method == "halt" for method, _ in phone.calls) == 1
        phone.drop_after = ""
        phone.bad_response = "wrong_id"
        with pytest.raises(ValueError, match="ID"):
            client.call("hello")
        assert client._socket is None


def test_rtt_sparse_channel_decode_and_partial_down_writes():
    phone = Phone()
    with phone_server(phone) as options:
        backend = RemoteMemoryBackend("ember", options)
        backend.connect()
        normal = JScopeRttBackend()
        try:
            symbols = normal.start(backend.rtt_target)
            assert normal.channel_index == 3
            assert normal.transport_name == "EmberMobile v1 RTT"
            assert normal.read_frames(0)[0][1][symbols[0].key] == 2.5
            capture = normal.control_block
            assert capture.down_channels[0].write(b"abcdefghijk", blocking=True) == 11
            assert phone.down == b"abcdefghijk"
            phone.epoch += 1
            with pytest.raises(RuntimeError, match="代次"):
                normal.read_frames(1)
        finally:
            normal.stop()
            backend.disconnect()
    assert not phone.rtt_running


def test_rtt_plus_remote_configuration_and_sample():
    phone = Phone()
    phone.plus = True
    phone.data = b""
    with phone_server(phone) as options:
        backend = RemoteMemoryBackend("ember", options)
        backend.connect()
        plus = JScopeRttPlusBackend()
        symbol = SymbolInfo("speed", 0x20000000, 4, "float", ".data")
        try:
            plus.start(backend.rtt_target, None, None, [WatchedVariable(symbol, "")])
            assert phone.down == struct.pack("<QI", symbol.address, symbol.size) + bytes(12)
            assert plus.read_frames(0)[0][1][symbol.key] == 4.5
        finally:
            plus.stop()
            backend.disconnect()


def test_shared_rtt_is_not_stopped_and_overflow_is_reported():
    phone = Phone()
    phone.rtt_running = True
    with phone_server(phone) as options:
        backend = RemoteMemoryBackend("ember", options)
        backend.connect()
        normal = JScopeRttBackend()
        try:
            normal.start(backend.rtt_target)
            phone.dropped = 100
            with pytest.raises(RuntimeError, match="丢失 100"):
                normal.read_frames(0)
        finally:
            normal.stop()
            backend.disconnect()
    assert phone.rtt_running
    assert not any(m == "rtt_stop" for m, _ in phone.calls)


def test_service_remote_config_lifecycle_and_gdb_capability():
    phone = Phone()
    with phone_server(phone) as options:
        service = BackendService(lambda *_: None)
        try:
            service.handle(RpcMethod.SET_CONFIG, {"connectionKind": "ember", "remoteConfig": options})
            connected = service.handle(RpcMethod.CONNECT, {})["state"]
            assert connected["connectionKind"] == "ember"
            assert connected["connectionCapabilities"]["memoryWrite"] is False
            with pytest.raises(ProtocolError) as error:
                service.handle(RpcMethod.SET_CONFIG, {"remoteConfig": {"host": "different"}})
            assert error.value.code == "already_connected"
            service.handle(RpcMethod.DISCONNECT, {})
            service.handle(RpcMethod.SET_CONFIG, {"connectionKind": "gdb"})
            assert not service.state_snapshot()["connectionCapabilities"]["memorySampling"]
            with pytest.raises(ProtocolError):
                service.handle(RpcMethod.SET_RTT, {"enabled": True})
        finally:
            service.close()


def test_owned_gdb_is_stopped_after_failed_connect_but_existing_server_is_preserved():
    for existing in (False, True):
        phone = Phone()
        phone.gdb["running"] = existing
        with phone_server(phone) as options:
            with patch("take_a_look_backend.backends.remote_backend.GdbTarget", side_effect=RuntimeError("GDB unavailable")):
                backend = RemoteMemoryBackend("emberGdb", options)
                with pytest.raises(RuntimeError, match="GDB unavailable"):
                    backend.connect()
        assert phone.gdb["running"] == existing
        assert any(m == "gdb_stop" for m, _ in phone.calls) == (not existing)
