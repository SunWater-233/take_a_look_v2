from __future__ import annotations

import io
import json
import subprocess
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from take_a_look_backend.protocol import ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services import online_packs
from take_a_look_backend.services.online_packs import OnlinePacks, _descriptor
from take_a_look_backend.services.target_catalog import TargetCatalog


PDSC = '''<package><vendor>Test</vendor><name>Demo_DFP</name><url>https://example.org/</url>
<releases><release version="1.0.0" url="https://example.org/releases/demo.pack"/></releases>
<devices><family Dvendor="Test:999" Dfamily="Demo"><processor Dcore="Cortex-M4"/>
<memory id="IRAM1" start="0x20000000" size="0x10000" access="rwx"/>
<device Dname="DEMO100"><variant Dvariant="DEMO100A"/></device></family></devices></package>'''


def pack_bytes(pdsc=PDSC):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as pack:
        pack.writestr("Test.Demo_DFP.pdsc", pdsc)
    return data.getvalue()


@pytest.fixture
def web():
    state = {"body": pack_bytes(), "slow": False, "length": None, "started": threading.Event()}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(state["length"] or len(state["body"])))
            self.end_headers()
            state["started"].set()
            try:
                for block in [state["body"][:10], state["body"][10:]]:
                    self.wfile.write(block)
                    self.wfile.flush()
                    if state["slow"]:
                        time.sleep(0.2)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield state, f"http://127.0.0.1:{server.server_port}/demo.pack"
    server.shutdown()
    server.server_close()
    thread.join()


def seed(catalog, url):
    directory = catalog._workspace() / "online"
    directory.mkdir(exist_ok=True)
    record = {"id": "online-demo", "vendor": "Test", "name": "Demo_DFP", "version": "1.0.0",
              "url": url, "parts": ["DEMO100", "DEMO100A"], "deviceVendors": ["Test"]}
    (directory / "index.json").write_text(json.dumps({"version": 1, "packs": [record]}), encoding="utf-8")
    return record


def finish(manager, job, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        snapshot = manager.request({"operation": "status", "jobId": job["jobId"]})
        if snapshot["status"] != "running":
            return snapshot
        time.sleep(0.01)
    pytest.fail("online job did not finish")


def test_real_http_download_validates_imports_persists_and_selects_exact_pack(tmp_path, web):
    catalog = TargetCatalog(tmp_path / "library")
    _, url = web
    seed(catalog, url)
    manager = OnlinePacks(catalog, catalog.selection_state)
    try:
        search = finish(manager, manager.request({"operation": "search", "query": "demo100a"}))
        result = search["result"]["packs"][0]
        assert result["matchingParts"] == ["DEMO100A"]
        assert result["installedPackId"] == ""
        downloaded = finish(manager, manager.request({"operation": "download", "packId": result["id"], "query": "DEMO100A"}))
        assert downloaded["status"] == "succeeded", downloaded
        assert downloaded["bytesReceived"] == len(web[0]["body"])
        pack_id = downloaded["result"]["packId"]
        assert downloaded["result"]["partNumber"] == "DEMO100A"
        assert downloaded["state"]["targetName"] == "auto"  # Installation does not reconnect a probe.
        catalog.select("demo100a", pack_id)
        restored = TargetCatalog(catalog.directory)
        assert restored.selected["packId"] == pack_id
        assert Path(restored.connection_pack()).read_bytes() == web[0]["body"]
        restored.close()
        search = finish(manager, manager.request({"operation": "search", "query": "Test Demo"}))
        assert search["result"]["packs"][0]["installedPackId"] == pack_id
        duplicate = finish(manager, manager.request({"operation": "download", "packId": result["id"]}))
        assert duplicate["result"]["alreadyInstalled"] is True
        assert len(catalog.snapshot()["packs"]) == 1
        assert not list((catalog.directory / "online").glob("download-*.pack"))
        assert not list(catalog.directory.glob("pending-*.pack"))
    finally:
        manager.close()
        catalog.close()


@pytest.mark.parametrize("problem", ["invalid_zip", "identity", "truncated", "too_large", "file_url"])
def test_failed_download_never_changes_library(tmp_path, web, problem):
    state, url = web
    catalog = TargetCatalog(tmp_path / "library")
    if problem == "invalid_zip":
        state["body"] = b"<html>server error</html>"
    elif problem == "identity":
        state["body"] = pack_bytes(PDSC.replace("1.0.0", "2.0.0"))
    elif problem == "truncated":
        state["length"] = len(state["body"]) + 100
    elif problem == "too_large":
        state["length"] = online_packs.MAX_PACK_BYTES + 1
    else:
        url = "file:///tmp/invalid.pack"
    seed(catalog, url)
    manager = OnlinePacks(catalog, catalog.selection_state)
    try:
        job = finish(manager, manager.request({"operation": "download", "packId": "online-demo"}))
        assert job["status"] == "failed"
        assert catalog.snapshot()["packs"] == []
        assert catalog.selected["name"] == "auto"
        assert not list(catalog.directory.rglob("*.pack"))
    finally:
        manager.close()
        catalog.close()


def test_download_cancellation_keeps_control_path_and_retry_usable(tmp_path, web):
    state, url = web
    state["slow"] = True
    service = BackendService(lambda *_: None, target_directory=tmp_path / "library")
    seed(service._targets, url)
    try:
        job = service.handle(RpcMethod.ONLINE_TARGET_PACKS, {"operation": "download", "packId": "online-demo"})
        assert state["started"].wait(2)
        with pytest.raises(ProtocolError, match="busy"):
            service.handle(RpcMethod.ONLINE_TARGET_PACKS, {"operation": "search", "query": "Demo"})
        assert service.handle(RpcMethod.GET_STATE, {})["state"]["connectionStatus"] == "disconnected"
        service.handle(RpcMethod.ONLINE_TARGET_PACKS, {"operation": "cancel", "jobId": job["jobId"]})
        assert finish(service._online_packs, job)["status"] == "cancelled"
        assert not service._targets.snapshot()["packs"]
        state["slow"] = False
        retry = finish(service._online_packs, service.handle(RpcMethod.ONLINE_TARGET_PACKS,
                       {"operation": "download", "packId": "online-demo"}))
        assert retry["status"] == "succeeded", retry
        with pytest.raises(ProtocolError, match="unknown_pack_job"):
            service.handle(RpcMethod.ONLINE_TARGET_PACKS, {"operation": "cancel", "jobId": job["jobId"]})
    finally:
        service.close()


def test_index_timeout_preserves_previous_cache_and_stops_child(tmp_path, monkeypatch):
    catalog = TargetCatalog(tmp_path / "library")
    seed(catalog, "https://example.org/demo.pack")
    before = (catalog.directory / "online/index.json").read_bytes()
    popen = subprocess.Popen
    processes = []

    def slow_child(command, **kwargs):
        process = popen([command[0], "-u", "-c", "import time; time.sleep(60)"], **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(online_packs.subprocess, "Popen", slow_child)
    manager = OnlinePacks(catalog, catalog.selection_state, index_timeout=0.1)
    try:
        job = finish(manager, manager.request({"operation": "search", "query": "DEMO", "refresh": True}))
        assert job["errorCode"] == "pack_index_timeout"
        assert processes[0].poll() is not None
        assert (catalog.directory / "online/index.json").read_bytes() == before
        assert not list((catalog.directory / "online").glob("index-*"))
        assert finish(manager, manager.request({"operation": "search", "query": "demo"}))["result"]["total"] == 1
    finally:
        manager.close()
        catalog.close()


def test_descriptor_inheritance_variants_and_release_url(monkeypatch):
    monkeypatch.setattr(online_packs, "_fetch", lambda *_: PDSC.encode())
    entry = {"vendor": "Test", "name": "Demo_DFP", "version": "1.0.0", "url": "https://example.org/"}
    record = _descriptor(entry)
    assert record["parts"] == ["DEMO100", "DEMO100A"]
    assert record["deviceVendors"] == ["Test"]
    assert record["url"] == "https://example.org/releases/demo.pack"
    monkeypatch.setattr(online_packs, "_fetch", lambda *_: PDSC.replace("Cortex-M4", "Cortex-A7").encode())
    assert _descriptor(entry)["parts"] == []


def test_invalid_requests_are_immediate(tmp_path):
    catalog = TargetCatalog(tmp_path)
    manager = OnlinePacks(catalog, catalog.selection_state)
    try:
        for arguments in ({"operation": "search", "query": "x"}, {"operation": "arbitrary"},
                          {"operation": "download", "packId": "not-indexed"},
                          {"operation": "status", "jobId": "other"}):
            with pytest.raises(ProtocolError):
                manager.request(arguments)
    finally:
        manager.close()
        catalog.close()
