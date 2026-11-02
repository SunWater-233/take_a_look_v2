from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

import pytest

from take_a_look_backend.backends import ember_pairing as pairing
from take_a_look_backend.backends.ember_transport import EmberClient
from take_a_look_backend.backends.ember_v2 import QuicClient
from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import RpcMethod
from take_a_look_backend.service import BackendService
from test_gdb_remote import arm_firmware


def until(operation, predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = operation()
        if predicate(result):
            return result
        time.sleep(.02)
    raise AssertionError(f"Timed out: {result}")


class Phone:
    def __init__(self, executable, directory):
        self.process = subprocess.Popen([str(executable), str(directory)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.messages = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        threading.Thread(target=read, daemon=True).start()
        try:
            self.info = self.messages.get(timeout=15)
        except queue.Empty:
            self.process.terminate()
            _, error = self.process.communicate(timeout=5)
            raise AssertionError(f"Rust fixture did not start: {error}")

    def local(self, operation, **params):
        self.process.stdin.write(json.dumps({"operation": operation, **params}) + "\n")
        self.process.stdin.flush()
        return self.messages.get(timeout=8)

    def pending(self):
        return until(lambda: self.local("snapshot"), lambda s: bool(s["pending"]))["pending"][0]

    def close(self):
        self.process.terminate()
        self.process.communicate(timeout=5)


@pytest.fixture
def phone_factory(tmp_path):
    suffix = ".exe" if os.name == "nt" else ""
    executable = Path(os.environ.get("TAL_EMBER_FIXTURE", str(Path(__file__).resolve().parents[2]
        / "build" / "ember-fixture" / "debug" / f"tal-ember-fixture{suffix}")))
    if not executable.is_file():
        pytest.skip("Build backend/tests/fixtures/ember_gateway with --target-dir build/ember-fixture")
    phones = []
    def create():
        phone = Phone(executable, tmp_path / "phone")
        phones.append(phone)
        return phone
    yield create
    for phone in phones:
        if phone.process.poll() is None:
            phone.close()


def approve(manager, phone):
    manager.start("127.0.0.1", phone.info["tcp_port"], name="Take A Look test")
    state = until(manager.status, lambda s: s["status"] in {"waiting", "failed"})
    assert state["status"] == "waiting", state
    pending = phone.pending()
    assert state["code"] == pending["code"]
    assert len(state["code"]) == 8
    phone.local("decide", id=pending["id"], accept=True)
    state = until(manager.status, lambda s: s["status"] in {"paired", "failed"})
    assert state["status"] == "paired", state
    return state["device"]


def test_store_roundtrip_public_metadata_and_atomic_failure(tmp_path, monkeypatch):
    store = pairing.PairingStore(tmp_path)
    phone = dict(id="a" * 64, name="手机", host="127.0.0.1", port="4242", token="pair:private.secret")
    store.save(phone, phone["id"])
    assert store.find(phone["id"]) == phone
    if os.name == "nt":
        assert b"private" not in store.path.read_bytes()
    else:
        assert store.path.stat().st_mode & 0o777 == 0o600
    manager = pairing.PairingManager(store)
    assert "token" not in json.dumps(manager.devices())
    monkeypatch.setattr(pairing.os, "replace", lambda *_: (_ for _ in ()).throw(OSError("disk")))
    with pytest.raises(OSError):
        store.save(None, phone["id"])
    assert store.find(phone["id"]) == phone
    assert not list(tmp_path.glob("*.tmp"))


def test_pairing_credential_never_downgrades_to_plaintext(monkeypatch):
    monkeypatch.setenv("EMBER_PROTOCOL", "1")
    client = EmberClient("127.0.0.1", 1, "pair:secret." + "0" * 64)
    with pytest.raises(ValueError, match="QUIC"):
        client.call("hello")
    assert client._socket is None


def test_rust_pairing_codes_saved_reconnect_batch_and_bilateral_forget(phone_factory, tmp_path, monkeypatch):
    monkeypatch.delenv("EMBER_PROTOCOL", raising=False)
    monkeypatch.setenv("TAL_EMBER_CONFIG_DIR", str(tmp_path / "computer"))
    manager = pairing.PairingManager()
    phone = phone_factory()
    device = approve(manager, phone)
    credential = manager.store.find(device["id"])
    assert "token" not in json.dumps(manager.status())
    assert "token" not in json.dumps(manager.devices())
    client = QuicClient("127.0.0.1", phone.info["v2"], credential["token"])
    try:
        assert client.call("ping", {})["pong"]
        data = client.call("read_memory_batch", {"session_id": 1, "ranges": [
            {"address": 7, "length": 4}, {"address": 0, "length": 3}, {"address": 7, "length": 4}]})
        assert [r["data"] for r in data["ranges"]] == [bytes([7, 8, 9, 10]), bytes([0, 1, 2]), bytes([7, 8, 9, 10])]
        assert data["epoch"] == 7
    finally:
        client.close()
    phone.close()
    # Persistent phone identity, new TCP/UDP ports and temporary token.
    phone = phone_factory()
    monkeypatch.setattr(pairing, "discover", lambda *_: [{**device, "host": "127.0.0.1", "port": str(phone.info["tcp_port"])}])
    backend = RemoteMemoryBackend("ember", {"deviceId": device["id"]})
    try:
        backend.connect()
        values = backend.read_symbols([SymbolInfo("first", 7, 4, "uint32_t", ".data"),
                                       SymbolInfo("next", 21, 4, "uint32_t", ".data")])
        assert list(values.values()) == [0x0A090807, 0x18171615]
        assert backend.last_read_metrics["block_count"] == 2
        assert backend.client.protocol_version == 2
    finally:
        backend.disconnect()
    manager.store.save({**credential, "port": str(phone.info["tcp_port"])}, device["id"])
    live = QuicClient("127.0.0.1", phone.info["v2"], credential["token"])
    data_client = live._data()
    try:
        result = manager.forget(device["id"])
        assert result["warning"] is None
        assert not manager.store.phones()
        until(lambda: live._protocol.terminated and data_client._protocol.terminated, bool)
        assert not phone.local("snapshot")["devices"]
        with pytest.raises(Exception):
            QuicClient("127.0.0.1", phone.info["v2"], credential["token"])
    finally:
        live.close()
        manager.close()


def test_rust_rejection_cancellation_and_phone_revocation(phone_factory, tmp_path):
    phone = phone_factory()
    manager = pairing.PairingManager(pairing.PairingStore(tmp_path / "computer"))
    try:
        manager.start("127.0.0.1", phone.info["tcp_port"], name="Rejected")
        request = phone.pending()
        phone.local("decide", id=request["id"], accept=False)
        assert until(manager.status, lambda s: s["status"] == "failed")["message"]
        assert not manager.store.phones()
        manager.start("127.0.0.1", phone.info["tcp_port"], name="Cancelled")
        phone.pending()
        manager.cancel()
        until(manager.status, lambda s: s["status"] == "cancelled")
        until(lambda: phone.local("snapshot"), lambda s: not s["pending"])
        assert not manager.store.phones()
        device = approve(manager, phone)
        token = manager.store.find(device["id"])["token"]
        client = QuicClient("127.0.0.1", phone.info["v2"], token)
        try:
            phone.local("forget", id=phone.local("snapshot")["devices"][0]["id"])
            until(lambda: client._protocol.terminated, bool)
            with pytest.raises(Exception):
                QuicClient("127.0.0.1", phone.info["v2"], token)
        finally:
            client.close()
    finally:
        manager.close()


def test_offline_forget_removes_local_secret_and_reports_phone_cleanup(tmp_path, monkeypatch):
    store = pairing.PairingStore(tmp_path)
    store.save(dict(id="a", name="Phone", host="127.0.0.1", port="1", token="secret"), "a")
    monkeypatch.setattr(pairing, "advertisement", lambda *_: (_ for _ in ()).throw(ConnectionError("offline")))
    result = pairing.PairingManager(store).forget("a")
    assert result["warning"]
    assert store.phones() == []


def test_rust_timeout_and_local_save_failure_leave_no_phone_grant(phone_factory, tmp_path, monkeypatch):
    phone = phone_factory()
    manager = pairing.PairingManager(pairing.PairingStore(tmp_path / "computer"))
    try:
        monkeypatch.setattr(pairing, "PAIR_TIMEOUT", .25)
        manager.start("127.0.0.1", phone.info["tcp_port"], name="Timeout")
        phone.pending()
        state = until(manager.status, lambda s: s["status"] == "failed")
        assert "超时" in state["message"]
        until(lambda: phone.local("snapshot"), lambda s: not s["pending"])
        assert not manager.store.phones()
        monkeypatch.setattr(pairing, "PAIR_TIMEOUT", 125)
        monkeypatch.setattr(manager.store, "save", lambda *_: (_ for _ in ()).throw(OSError("磁盘不可写")))
        manager.start("127.0.0.1", phone.info["tcp_port"], name="Save failure")
        request = phone.pending()
        phone.local("decide", id=request["id"], accept=True)
        assert "磁盘不可写" in until(manager.status, lambda s: s["status"] == "failed")["message"]
        assert not phone.local("snapshot")["devices"]
    finally:
        manager.close()


def test_rust_rejects_saved_certificate_swap_before_auth(phone_factory, tmp_path):
    first = phone_factory()
    manager = pairing.PairingManager(pairing.PairingStore(tmp_path / "computer"))
    try:
        device = approve(manager, first)
        token = manager.store.find(device["id"])["token"]
        # A different identity even when discovery claims the saved device ID.
        changed = {**first.info["v2"], "certificate_der": "AA=="}
        with pytest.raises(ConnectionError, match="证书"):
            QuicClient("127.0.0.1", changed, token)
    finally:
        manager.close()


def test_service_rejects_invalid_pairing_and_does_not_expose_secrets(tmp_path, monkeypatch):
    monkeypatch.setenv("TAL_EMBER_CONFIG_DIR", str(tmp_path))
    service = BackendService(lambda *_: None)
    try:
        assert service.handle(RpcMethod.EMBER, {"operation": "devices"}) == {"devices": []}
        with pytest.raises(Exception):
            service.handle(RpcMethod.EMBER, {"operation": "pair", "host": "", "port": "-1"})
        assert "token" not in json.dumps(service.handle(RpcMethod.EMBER, {"operation": "status"}))
    finally:
        service.close()


@pytest.mark.skipif(not os.environ.get("TAL_BACKEND_EXE"), reason="Set TAL_BACKEND_EXE for packaged runtime smoke")
def test_packaged_runtime_pairing_connect_and_forget(phone_factory, tmp_path, arm_firmware):
    phone = phone_factory()
    environment = {**os.environ, "TAL_EMBER_CONFIG_DIR": str(tmp_path / "computer"),
                   "TAL_SOURCE_SETTINGS": str(tmp_path / "source.json")}
    environment.pop("EMBER_PROTOCOL", None)
    process = subprocess.Popen([os.environ["TAL_BACKEND_EXE"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", env=environment,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    messages = queue.Queue()
    def read():
        for line in process.stdout:
            messages.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    sequence = 0
    def send(method, **params):
        nonlocal sequence
        sequence += 1
        process.stdin.write(json.dumps({"v": 2, "id": sequence, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        return sequence
    def receive(request_id):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            message = messages.get(timeout=20)
            if message.get("id") == request_id:
                assert "error" not in message, message
                return message["result"]
        raise AssertionError("Packaged backend response missing")
    def call(method, **params):
        return receive(send(method, **params))
    try:
        assert call("handshake")["protocolVersion"] == 2
        assert call("ember", operation="devices") == {"devices": []}
        discovery_id = send("ember", operation="discover")
        before = time.monotonic()
        assert call("getState")["state"]["connectionStatus"] == "disconnected"
        assert time.monotonic() - before < 1.5  # Discovery cannot block the control pipe.
        receive(discovery_id)
        call("ember", operation="pair", host="127.0.0.1", port=str(phone.info["tcp_port"]))
        state = until(lambda: call("ember", operation="status"), lambda s: s["status"] in {"waiting", "failed"})
        pending = phone.pending()
        assert state["code"] == pending["code"]
        phone.local("decide", id=pending["id"], accept=True)
        state = until(lambda: call("ember", operation="status"), lambda s: s["status"] in {"paired", "failed"})
        assert state["status"] == "paired", state
        assert "token" not in json.dumps(state)
        device = state["device"]
        call("setConfig", connectionKind="ember", remoteConfig={"deviceId": device["id"]})
        connected = call("connect")["state"]
        assert connected["gatewayProtocolVersion"] == 2
        assert connected["remoteConfig"]["token"] == ""
        _, image = arm_firmware
        call('setSourceProject', sourceRoot=str(tmp_path), firmwarePath=str(image), afterDownload='halt')
        call('startSourceTask', kind='download')
        task = until(lambda: call('getState')['state']['sourceTask'], lambda s: s['status'] in {'succeeded', 'failed'})
        assert task['status'] == 'succeeded', task.get('message', task)
        assert phone.local('backend')['firmware']['ready']
        call("disconnect")
        forgotten = call("ember", operation="forget", deviceId=device["id"])
        assert forgotten["warning"] is None
        assert call("getState")["state"]["remoteConfig"]["deviceId"] == ""
        assert not phone.local("snapshot")["devices"]
        call("shutdown")
        process.stdin.close()
        assert process.wait(timeout=8) == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
