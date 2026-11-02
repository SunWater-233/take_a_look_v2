"""Phone-approved Ember pairing. Secrets never enter UI/project snapshots."""
from __future__ import annotations

import asyncio
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import ssl
import tempfile
import threading
import time

from aioquic.asyncio import connect
from aioquic.tls import hkdf_expand_label

from .ember_v2 import _Protocol, QuicClient, V2Error, PAIR, OK, encoded, frame, read_frame

PAIR_TIMEOUT = 125


def _protect(data: bytes, encrypt: bool) -> bytes:
    if os.name != "nt":
        return data
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    source = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    incoming, outgoing = Blob(len(data), source), Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    function = crypt.CryptProtectData if encrypt else crypt.CryptUnprotectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                         ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if not function(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(outgoing.data, outgoing.size)
    finally:
        kernel.LocalFree(outgoing.data)


class PairingStore:
    def __init__(self, directory: Path | None = None):
        from ..services.source_project import default_settings_file
        self.directory = directory or Path(os.environ.get(
            "TAL_EMBER_CONFIG_DIR", str(default_settings_file().parent / "ember")))
        self.path = self.directory / "paired-devices.dat"
        self.lock = threading.RLock()

    def phones(self) -> list[dict]:
        with self.lock:
            if not self.path.exists():
                return []
            phones = json.loads(_protect(self.path.read_bytes(), False))
            if not isinstance(phones, list) or any(not isinstance(p, dict) or not all(
                    isinstance(p.get(k), str) and p[k] for k in ("id", "name", "host", "port", "token"))
                    for p in phones):
                raise ValueError("已保存的手机配对数据损坏，请检查本机配置。")
            return phones

    def save(self, phone: dict | None, device_id: str):
        with self.lock:
            phones = [p for p in self.phones() if p["id"] != device_id]
            if phone is not None:
                phones.append(phone)
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            if os.name != "nt":
                self.directory.chmod(0o700)
            data = _protect(encoded(phones), True)
            descriptor, name = tempfile.mkstemp(dir=self.directory, suffix=".tmp")
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name, self.path)
            finally:
                Path(name).unlink(missing_ok=True)

    def find(self, device_id: str) -> dict:
        for phone in self.phones():
            if phone["id"] == device_id:
                return phone
        raise ValueError("未找到已保存的手机配对，请重新配对或使用访问令牌。")


def public_phone(phone: dict) -> dict:
    return {key: phone[key] for key in ("id", "name", "host", "port")}


def advertisement(host: str, port: int) -> dict:
    from .ember_transport import EmberClient
    client = EmberClient(host, port, "discovery")
    try:
        return client._legacy_call("v2_info", {})["v2"]
    finally:
        client.close()


def discover(seconds: float = 2) -> list[dict]:
    from zeroconf import IPVersion, ServiceBrowser, ServiceStateChange, Zeroconf
    found, lock = {}, threading.Lock()

    def changed(zeroconf, service_type, name, state_change):
        if state_change is ServiceStateChange.Removed:
            return
        info = zeroconf.get_service_info(service_type, name, timeout=700)
        if info is None:
            return
        device_id = info.properties.get(b"id", b"").decode(errors="replace")
        if len(device_id) != 64 or any(c not in "0123456789abcdef" for c in device_id):
            return
        for host in sorted(info.parsed_addresses(IPVersion.V4Only)):
            phone = {"id": device_id, "name": info.properties.get(b"name", b"EmberMobile").decode(errors="replace")[:96],
                     "host": host, "port": str(info.port)}
            with lock:
                found[device_id] = phone
            break

    with Zeroconf(ip_version=IPVersion.V4Only) as zeroconf:
        browser = ServiceBrowser(zeroconf, "_embermobile._tcp.local.", handlers=[changed])
        try:
            time.sleep(seconds)
        finally:
            browser.cancel()
    return list(found.values())


class _PairProtocol(_Protocol):
    """Capture exporter at server Finished, before the client transcript changes.

    aioquic has no public exporter API. This instance-local adapter follows
    RFC 8446 sections 7.1/7.5 and is checked against Ember's Rust TLS server.
    """
    comparison_code: str | None = None

    def connect(self, addr, transmit=True):
        super().connect(addr, transmit=transmit)
        tls = self._quic.tls
        original = tls._setup_traffic_protection

        def setup(direction, epoch, label):
            if label == b"s ap traffic":
                schedule = tls.key_schedule
                exporter = schedule.derive_secret(b"exp master")
                secret = hkdf_expand_label(schedule.algorithm, exporter, b"ember-pairing-v1",
                                           schedule.hash_empty_value, schedule.algorithm.digest_size)
                output = hkdf_expand_label(schedule.algorithm, secret, b"exporter", schedule.hash_empty_value, 4)
                self.comparison_code = f"{int.from_bytes(output, 'big') % 100_000_000:08d}"
            original(direction, epoch, label)
        tls._setup_traffic_protection = setup


async def pair(host: str, info: dict, name: str, on_code) -> dict:
    from aioquic.quic.configuration import QuicConfiguration
    certificate = base64.b64decode(info["certificate_der"], validate=True)
    pin = hashlib.sha256(certificate).hexdigest()
    device = info.get("device") or {}
    if device.get("pairing") != 1 or not isinstance(device.get("id"), str):
        raise ValueError("请更新手机 EmberMobile，以使用配对功能。")
    config = QuicConfiguration(is_client=True, alpn_protocols=["ember/2"], server_name="ember.local",
                               cadata=ssl.DER_cert_to_PEM_cert(certificate).encode(), verify_mode=ssl.CERT_REQUIRED,
                               idle_timeout=135)
    async with connect(host, int(info["port"]), configuration=config, create_protocol=_PairProtocol) as protocol:
        if not protocol.comparison_code:
            raise RuntimeError("无法生成本次 TLS 配对校验码。")
        secret = secrets.token_hex(32)
        reader, writer = await protocol.create_stream()
        writer.write(frame(PAIR, encoded({"name": name, "secret": secret})))
        writer.write_eof()
        protocol.transmit()
        on_code(protocol.comparison_code)
        kind, payload = await asyncio.wait_for(read_frame(reader), PAIR_TIMEOUT)
        if kind != OK:
            raise ConnectionError("手机返回了无效的配对响应。")
        result = json.loads(payload)
        if result.get("server_id") != device["id"] or not isinstance(result.get("pair_id"), str):
            raise ConnectionError("手机身份发生变化，请重新配对。")
        return {"id": device["id"], "name": str(device.get("name") or "EmberMobile"),
                "token": f"pair:{result['pair_id']}:{secret}.{pin}"}


class PairingManager:
    def __init__(self, store: PairingStore | None = None):
        self.store = store or PairingStore()
        self.lock = threading.RLock()
        self.cancelled = threading.Event()
        self.job = None
        self.state = {"status": "idle"}
        self.found = []

    def devices(self, scan=False):
        if scan:
            self.found = discover()
        saved = {p["id"]: {**public_phone(p), "paired": True, "online": False} for p in self.store.phones()}
        for phone in self.found:
            saved[phone["id"]] = {**phone, "paired": phone["id"] in saved, "online": True}
        return {"devices": list(saved.values())}

    def start(self, host: str, port: int, device_id: str = "", name: str = ""):
        with self.lock:
            if self.job and self.job.is_alive():
                raise ValueError("已有配对请求正在等待手机确认。")
            self.cancelled = threading.Event()
            self.state = {"status": "connecting", "host": host, "port": str(port)}
            self.job = threading.Thread(target=self._run, args=(host, port, device_id, name), daemon=True,
                                        name="ember-pairing")
            self.job.start()
            return dict(self.state)

    def _run(self, host, port, device_id, name):
        async def operation():
            info = await asyncio.to_thread(advertisement, host, port)
            if device_id and (info.get("device") or {}).get("id") != device_id:
                raise ValueError("该地址已属于另一台手机，请重新发现设备。")
            def on_code(code):
                with self.lock:
                    self.state = {**self.state, "status": "waiting", "code": code,
                                  "expiresAt": int(time.time() * 1000) + 120000}
            task = asyncio.create_task(pair(host, info, name, on_code))
            try:
                while not task.done():
                    if self.cancelled.is_set():
                        task.cancel()
                        break
                    await asyncio.sleep(.1)
                phone = await task
                phone = {**phone, "host": host, "port": str(port)}
                try:
                    # Commit and cancellation serialize so a grant is never
                    # silently saved after the caller closed the dialog.
                    with self.lock:
                        if self.cancelled.is_set():
                            raise asyncio.CancelledError()
                        self.store.save(phone, phone["id"])
                        self.state = {"status": "paired", "device": {**public_phone(phone), "paired": True}}
                except BaseException:
                    def revoke():
                        client = QuicClient(host, info, phone["token"])
                        try:
                            client.forget_pairing()
                        finally:
                            client.close()
                    try:
                        await asyncio.to_thread(revoke)
                    except Exception:
                        raise RuntimeError("本机未能保存配对，且手机未确认撤销；请在手机忘记本电脑后重试。")
                    raise
            finally:
                if not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
        try:
            asyncio.run(operation())
        except asyncio.CancelledError:
            with self.lock:
                self.state = {"status": "cancelled"}
        except Exception as error:
            message = str(error) or "配对超时，请重新发起并在手机确认。"
            if isinstance(error, V2Error) and "declined on the phone" in message:
                message = "手机已拒绝配对，请重新发起并在手机确认。"
            with self.lock:
                self.state = {"status": "failed", "message": message}

    def status(self):
        with self.lock:
            return dict(self.state)

    def cancel(self):
        with self.lock:
            self.cancelled.set()
        return self.status()

    def forget(self, device_id: str):
        phone = self.store.find(device_id)
        for found in self.found:
            if found["id"] == device_id:
                phone = {**phone, **found}
        warning = None
        client = None
        try:
            info = advertisement(phone["host"], int(phone["port"]))
            client = QuicClient(phone["host"], info, phone["token"])
            client.forget_pairing()
        except Exception:
            warning = "本机配对已删除；手机未确认撤销，请在手机「已配对电脑」中忘记本电脑。"
        finally:
            if client:
                client.close()
        self.store.save(None, device_id)
        return {**self.devices(), "warning": warning}

    def close(self):
        self.cancel()
        if self.job:
            self.job.join(timeout=5)
