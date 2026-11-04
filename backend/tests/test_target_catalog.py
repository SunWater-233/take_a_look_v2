from __future__ import annotations

import io
import hashlib
import json
import os
import threading
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from pyocd.target import TARGET
from pyocd.target.builtin import BUILTIN_TARGETS
from take_a_look_backend.backends.pyocd_memory import PyOcdConnectionConfig, PyOcdMemoryBackend
from take_a_look_backend.protocol import EventName, ProtocolError, RpcMethod
from take_a_look_backend.service import BackendService
from take_a_look_backend.services.target_catalog import TargetCatalog, builtin_targets
from take_a_look_backend.stdio import StdioServer


def make_pack(directory: Path, version="1.0.0", *, name="User_DFP", part="nrf52840", core="Cortex-M4", ram="0x10000", extra="") -> Path:
    path = directory / f"Test.{name}.{version}.pack"
    pdsc = f'''<?xml version="1.0" encoding="UTF-8"?>
<package schemaVersion="1.7.7"><vendor>Test</vendor><name>{name}</name>
<releases><release version="{version}">Test</release></releases>
<devices><family Dvendor="Test:999" Dfamily="Demo">
<processor Dcore="{core}" Dclock="64000000"/>
<memory id="IROM1" start="0x08000000" size="0x100000" access="rx" startup="1"/>
<memory id="IRAM1" start="0x20000000" size="{ram}" access="rwx"/>
<device Dname="{part}"/>{extra}
</family></devices></package>'''
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"Test.{name}.pdsc", pdsc)
    return path


@pytest.fixture
def catalog(tmp_path):
    result = TargetCatalog(tmp_path / "library")
    yield result
    result.close()


def install(catalog, path):
    preview = catalog.inspect(str(path))
    assert preview["targetCount"] >= 1
    result = catalog.import_pack(preview["previewId"])
    return result["packId"]


def bundled_fixture(tmp_path):
    from take_a_look_backend.services.target_catalog import _parse_pack
    source = make_pack(tmp_path)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    directory = tmp_path / "shipped"
    directory.mkdir()
    (directory / f"{digest}.pack").write_bytes(source.read_bytes())
    (directory / "index.json").write_text(json.dumps({"version": 1, "packs": {
        digest: _parse_pack(source, digest)}}), encoding="utf-8")
    return source, directory, digest


def test_bundled_pack_is_available_without_import_and_remains_readonly(tmp_path):
    source, directory, digest = bundled_fixture(tmp_path)
    library = tmp_path / "user"
    catalog = TargetCatalog(library, bundled_directory=directory)
    try:
        pack, = catalog.snapshot()["packs"]
        assert pack["bundled"] and pack["available"]
        assert not library.exists()  # Startup reads the shipped index without copying packs.
        catalog.select("nrf52840", digest)
        assert Path(catalog.connection_pack()).parent == directory
        preview = catalog.inspect(str(source))
        assert preview["alreadyInstalled"]
        assert catalog.import_pack(preview["previewId"])["alreadyInstalled"]
        assert not list(library.glob("*.pack"))
        with pytest.raises(ProtocolError, match="bundled_pack_readonly"):
            catalog.remove(digest)
        restored = TargetCatalog(library, bundled_directory=directory)
        try:
            assert restored.selected["packId"] == digest
            assert not restored.selection_state()["targetPackMissing"]
            assert Path(restored.connection_pack()).is_file()
        finally:
            restored.close()
    finally:
        catalog.close()


def test_missing_bundled_pack_can_be_repaired_in_user_storage(tmp_path):
    source, directory, digest = bundled_fixture(tmp_path)
    catalog = TargetCatalog(tmp_path / "user", bundled_directory=directory)
    try:
        catalog.select("nrf52840", digest)
        (directory / f"{digest}.pack").unlink()
        assert catalog.selection_state()["targetPackMissing"]
        with pytest.raises(ProtocolError, match="target_pack_missing"):
            catalog.connection_pack()
        install(catalog, source)
        assert Path(catalog.connection_pack()).parent == catalog.directory
        assert not (directory / f"{digest}.pack").exists()
        catalog.remove(digest)
        assert catalog.selection_state()["targetPackMissing"]
    finally:
        catalog.close()


def test_bundled_pack_hash_is_checked_before_connection(tmp_path):
    _, directory, digest = bundled_fixture(tmp_path)
    catalog = TargetCatalog(tmp_path / "user", bundled_directory=directory)
    try:
        catalog.select("nrf52840", digest)
        (directory / f"{digest}.pack").write_bytes(b"changed")
        with pytest.raises(ProtocolError, match="target_pack_changed"):
            catalog.connection_pack()
    finally:
        catalog.close()


def test_import_copies_metadata_without_registering_targets_and_restores_selection(tmp_path, catalog):
    original = dict(TARGET)
    path = make_pack(tmp_path, extra='<device Dname="Demo100"><variant Dvariant="Demo100A"/><variant Dvariant="Demo100B"/></device>')
    preview = catalog.inspect(str(path))
    assert preview["targetCount"] == 4
    assert preview["sampleTargets"] == ["nrf52840", "Demo100", "Demo100A", "Demo100B"]
    assert catalog.snapshot()["packs"] == []
    pack_id = catalog.import_pack(preview["previewId"])["packId"]
    assert TARGET == original
    path.unlink()
    chip = next(item for item in catalog.snapshot()["targets"] if item["packId"] == pack_id)
    assert chip["cores"] == ["Cortex-M4"]
    assert chip["families"] == ["Demo"]
    assert chip["memories"][1]["size"] == 65536
    catalog.select("NRF52840", pack_id)
    restored = TargetCatalog(catalog.directory)
    try:
        assert restored.selection_state()["targetPackId"] == pack_id
        assert restored.snapshot()["recent"] == [f"{pack_id}:nrf52840"]
        assert Path(restored.connection_pack()).is_file()
    finally:
        restored.close()


def test_duplicate_import_and_missing_file_repair(tmp_path, catalog):
    path = make_pack(tmp_path)
    pack_id = install(catalog, path)
    duplicate = catalog.inspect(str(path))
    assert duplicate["alreadyInstalled"] is True
    assert catalog.import_pack(duplicate["previewId"])["alreadyInstalled"] is True
    assert len(catalog.snapshot()["packs"]) == 1
    catalog.select("nrf52840", pack_id)
    Path(catalog.connection_pack()).unlink()
    assert catalog.selection_state()["targetPackMissing"] is True
    with pytest.raises(ProtocolError, match="target_pack_missing"):
        catalog.connection_pack()
    repair = catalog.inspect(str(path))
    assert repair["alreadyInstalled"] is False
    catalog.import_pack(repair["previewId"])
    assert catalog.selection_state()["targetPackMissing"] is False


def test_versions_load_the_exact_selected_definition_and_restore_builtin(tmp_path, catalog):
    first = make_pack(tmp_path, "1.0.0", ram="0x10000")
    second = make_pack(tmp_path, "2.0.0", ram="0x20000")
    ids = [install(catalog, path) for path in (first, second)]
    assert len(catalog.snapshot()["packs"]) == 2
    backend = PyOcdMemoryBackend()
    builtin = BUILTIN_TARGETS["nrf52840"]
    try:
        for pack_id, size in zip(ids, (65536, 131072)):
            catalog.select("nrf52840", pack_id)
            backend._prepare_target(PyOcdConnectionConfig("nrf52840", 1000000, pack_path=catalog.connection_pack()))
            device = TARGET["nrf52840"]._pack_device
            assert device.memory_map.get_region_for_address(0x20000000).length == size
            assert TARGET["nrf52840"] is not builtin
            backend.disconnect()
            assert TARGET["nrf52840"] is builtin
        backend._prepare_target(PyOcdConnectionConfig("nrf52840", 1000000))
        assert TARGET["nrf52840"] is builtin
    finally:
        backend.disconnect()


def test_failed_session_releases_registry_and_archive(tmp_path):
    path = make_pack(tmp_path)
    backend = PyOcdMemoryBackend()
    class Session:
        def __init__(self, *args, **kwargs):
            self.target = None
        def open(self):
            raise RuntimeError("failed open")
        def close(self):
            pass
    with patch("pyocd.core.helpers.ConnectHelper.get_all_connected_probes", return_value=[object()]), patch("pyocd.core.session.Session", Session):
        with pytest.raises(RuntimeError, match="failed open"):
            backend.connect(PyOcdConnectionConfig("nrf52840", 1000000, pack_path=str(path)))
    assert backend._pack_archive is None
    assert TARGET["nrf52840"] is BUILTIN_TARGETS["nrf52840"]
    backend._prepare_target(PyOcdConnectionConfig("nrf52840", 1000000))
    backend.disconnect()
    path.unlink()  # Windows rejects this if an archive handle leaked.


@pytest.mark.parametrize('prefix', [b'   ', b'\r\n\t ', b'\xef\xbb\xbf   ', b'', b'\xef\xbb\xbf'])
def test_pack_svd_declaration_is_normalised_before_session_open(tmp_path, prefix):
    from pyocd.debug.svd.loader import SVDFile

    path = make_pack(tmp_path)
    xml = (b'<?xml version="1.0" encoding="utf-8"?><device><name>TestChip</name>'
           b'<addressUnitBits>8</addressUnitBits><width>32</width><peripherals/></device>')
    original = io.BytesIO(prefix + xml)
    target = SimpleNamespace(_svd_location=SVDFile(original))
    class Session:
        def __init__(self, *args, **kwargs):
            self.target = target
        def open(self):
            self.target._svd_location.load()
        def close(self):
            pass
    backend = PyOcdMemoryBackend()
    before = path.read_bytes()
    try:
        with patch('pyocd.core.helpers.ConnectHelper.get_all_connected_probes', return_value=[object()]), patch('pyocd.core.session.Session', Session):
            backend.connect(PyOcdConnectionConfig('nrf52840', 1000000, pack_path=str(path)))
        assert target._svd_location.device.name == 'TestChip'
        assert original.getvalue() == prefix + xml
        assert path.read_bytes() == before
    finally:
        backend.disconnect()


def test_svd_without_declaration_is_preserved():
    from pyocd.debug.svd.loader import SVDFile
    from take_a_look_backend.backends.pyocd_memory import _normalise_pack_svd

    data = io.BytesIO(b' \n<!-- comment --><device><name>TestChip</name>'
                      b'<addressUnitBits>8</addressUnitBits><width>32</width><peripherals/></device>')
    target = SimpleNamespace(_svd_location=SVDFile(data))
    _normalise_pack_svd(target)
    assert target._svd_location.filename is data
    target._svd_location.load()
    assert target._svd_location.device.name == 'TestChip'


def test_remove_retains_selected_identity_and_never_falls_back(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    catalog.select("nrf52840", pack_id)
    catalog.remove(pack_id)
    assert catalog.selection_state()["targetName"] == "nrf52840"
    assert catalog.selection_state()["targetPackMissing"] is True
    assert catalog.snapshot()["recent"] == []
    with pytest.raises(ProtocolError):
        catalog.connection_pack()


def test_modified_pack_is_rejected_before_opening_a_probe(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    catalog.select("nrf52840", pack_id)
    path = Path(catalog.connection_pack())
    path.write_bytes(path.read_bytes() + b"modified")
    with pytest.raises(ProtocolError, match="target_pack_changed"):
        catalog.connection_pack()


@pytest.mark.parametrize("kind", ["not_zip", "no_devices", "missing_algorithm", "ambiguous"])
def test_invalid_packs_do_not_change_library(tmp_path, catalog, kind):
    if kind == "not_zip":
        path = tmp_path / "bad.pack"
        path.write_bytes(b"not a pack")
    elif kind == "no_devices":
        path = make_pack(tmp_path, core="Cortex-A7")
    elif kind == "missing_algorithm":
        path = make_pack(tmp_path, extra='<device Dname="Other"><algorithm name="missing.FLM" start="0x08000000" size="0x100000"/></device>')
    else:
        path = make_pack(tmp_path, part="Same-Name", extra='<device Dname="Same_Name"/>')
    with pytest.raises(ProtocolError):
        catalog.inspect(str(path))
    assert catalog.snapshot()["packs"] == []
    assert not list(catalog.directory.glob("pending-*.pack"))


def test_cancelling_preview_removes_staging_file(tmp_path, catalog):
    preview = catalog.inspect(str(make_pack(tmp_path)))
    assert len(list(catalog.directory.glob("pending-*.pack"))) == 1
    catalog.discard_preview(preview["previewId"])
    assert not list(catalog.directory.glob("pending-*.pack"))
    with pytest.raises(ProtocolError, match="preview_expired"):
        catalog.import_pack(preview["previewId"])


def test_manifest_write_failure_does_not_publish_an_import(tmp_path, catalog):
    preview = catalog.inspect(str(make_pack(tmp_path)))
    with patch.object(catalog, "_commit", side_effect=OSError("disk full")):
        with pytest.raises(OSError, match="disk full"):
            catalog.import_pack(preview["previewId"])
    assert catalog.snapshot()["packs"] == []
    assert not list(catalog.directory.glob("*.pack"))


def test_denied_index_creation_fails_once_and_keeps_saved_selection(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    before = (catalog.directory / "index.json").read_bytes()
    revision = catalog.revision
    original_open = Path.open
    attempts = []

    def deny_index(path, *args, **kwargs):
        if path.name.startswith("index-"):
            attempts.append(path)
            raise PermissionError("directory is not writable")
        return original_open(path, *args, **kwargs)

    # Windows mkstemp mistakes denied directory access for a name collision
    # and retries up to TMP_MAX times. Never enter that retry loop.
    with patch("tempfile.mkstemp", side_effect=AssertionError("unbounded retry")), \
            patch.object(Path, "open", deny_index):
        with pytest.raises(ProtocolError, match="target_catalog_access_denied"):
            catalog.select("nrf52840", pack_id)
    assert len(attempts) == 1
    assert catalog.revision == revision
    assert catalog.selected["name"] == "auto"
    assert (catalog.directory / "index.json").read_bytes() == before
    assert not list(catalog.directory.glob("index-*.tmp"))
    catalog.select("nrf52840", pack_id)
    assert catalog.selected["packId"] == pack_id


def test_denied_index_replace_preserves_index_and_cleans_temporary(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    before = (catalog.directory / "index.json").read_bytes()
    with patch("os.replace", side_effect=PermissionError("index is locked")):
        with pytest.raises(ProtocolError, match="target_catalog_access_denied"):
            catalog.select("nrf52840", pack_id)
    assert (catalog.directory / "index.json").read_bytes() == before
    assert catalog.selected["name"] == "auto"
    assert not list(catalog.directory.glob("index-*.tmp"))


def test_denied_pack_removal_preserves_library_and_reports_storage_error(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    catalog.select("nrf52840", pack_id)
    before = (catalog.directory / "index.json").read_bytes()
    with patch("os.replace", side_effect=PermissionError("pack is locked")):
        with pytest.raises(ProtocolError, match="target_catalog_access_denied"):
            catalog.remove(pack_id)
    assert (catalog.directory / "index.json").read_bytes() == before
    assert catalog.selection_state()["targetPackMissing"] is False
    assert len(catalog.snapshot()["packs"]) == 1
    assert Path(catalog.connection_pack()).is_file()


def test_failed_removal_index_write_restores_the_pack(tmp_path, catalog):
    pack_id = install(catalog, make_pack(tmp_path))
    catalog.select("nrf52840", pack_id)
    before = (catalog.directory / "index.json").read_bytes()
    replace = os.replace

    def deny_index(source, destination):
        if Path(destination).name == "index.json":
            raise PermissionError("index is locked")
        return replace(source, destination)

    with patch("os.replace", side_effect=deny_index):
        with pytest.raises(ProtocolError, match="target_catalog_access_denied"):
            catalog.remove(pack_id)
    assert (catalog.directory / "index.json").read_bytes() == before
    assert Path(catalog.connection_pack()).is_file()
    assert not list(catalog.directory.glob("removed-*.tmp"))


def test_denied_selection_returns_rpc_error_and_keeps_backend_responsive(tmp_path, monkeypatch):
    monkeypatch.setenv("TAL_PACKS_DIR", str(tmp_path / "library"))
    output = io.BytesIO()
    server = StdioServer(io.StringIO(), output)
    try:
        with patch("tempfile.mkstemp", side_effect=AssertionError("unbounded retry")), \
                patch.object(Path, "open", side_effect=PermissionError("directory is not writable")):
            server._handle_line('{"v":3,"id":1,"method":"selectTarget","params":{"name":"auto"}}')
            server._catalog_worker.submit(lambda: None).result(timeout=2)
        server._handle_line('{"v":3,"id":2,"method":"getState"}')
        server._output_worker.drain()
        replies = {message["id"]: message for line in output.getvalue().splitlines()
                   if "id" in (message := json.loads(line))}
        assert replies[1]["error"]["code"] == "target_catalog_access_denied"
        assert replies[2]["result"]["state"]["targetName"] == "auto"
    finally:
        server.close()


def test_builtin_catalog_is_independent_of_previous_dynamic_targets():
    assert len(builtin_targets()) > 100
    assert builtin_targets()[0]["name"] == "auto"
    assert all(item["packId"] == "" for item in builtin_targets())


class Memory:
    target = None
    probe = None
    config = None
    fail_connect = False
    connections = 0
    def connect(self, config):
        self.connections += 1
        if self.fail_connect:
            raise RuntimeError("probe unavailable")
        self.config = config
    def disconnect(self):
        self.config = None
    def debug_state(self):
        return "running"


def test_rpc_selection_reconnects_and_restarting_backend(tmp_path):
    events = []
    memory = Memory()
    directory = tmp_path / "library"
    service = BackendService(lambda *args: events.append(args), memory_backend=memory,
                             target_directory=directory, recording_directory=tmp_path / "recording")
    try:
        preview = service.handle(RpcMethod.INSPECT_TARGET_PACK, {"path": str(make_pack(tmp_path))})
        pack_id = service.handle(RpcMethod.IMPORT_TARGET_PACK, {"previewId": preview["previewId"]})["packId"]
        service.handle(RpcMethod.SELECT_TARGET, {"name": "nrf52840", "packId": pack_id})
        service.handle(RpcMethod.CONNECT, {})
        assert memory.config.target == "nrf52840"
        assert Path(memory.config.pack_path).name == f"{pack_id}.pack"
        with pytest.raises(ProtocolError, match="pack_in_use"):
            service.handle(RpcMethod.REMOVE_TARGET_PACK, {"packId": pack_id})
        service.handle(RpcMethod.SET_SAMPLING_PAUSED, {"paused": True})
        result = service.handle(RpcMethod.SELECT_TARGET, {"name": "auto"})
        assert result["state"]["connectionStatus"] == "connected"
        assert result["state"]["samplingPaused"] is True
        assert memory.config.target is None
        assert memory.config.pack_path is None
        assert memory.connections == 2
        service.handle(RpcMethod.SELECT_TARGET, {"name": "auto"})
        assert memory.connections == 2  # Reselecting does not interrupt acquisition.
        service.handle(RpcMethod.SELECT_TARGET, {"name": "nrf52840", "packId": pack_id})
        assert memory.config.target == "nrf52840"
        service.handle(RpcMethod.SET_CONFIG, {"targetName": "auto"})
        assert memory.config.target is None
        assert service.state_snapshot()["samplingPaused"] is True
        service.handle(RpcMethod.SELECT_TARGET, {"name": "nrf52840", "packId": pack_id})
        assert any(name is EventName.STATE and value.get("targetPackId") == pack_id for name, value in events)
    finally:
        service.close()
    restored = BackendService(lambda *_: None, target_directory=directory,
                             recording_directory=tmp_path / "recording2")
    try:
        assert restored.state_snapshot()["targetPackId"] == pack_id
        assert restored.state_snapshot()["targetName"] == "nrf52840"
    finally:
        restored.close()


def test_invalid_selection_keeps_live_connection_and_failed_reconnect_is_retryable(tmp_path):
    memory = Memory()
    service = BackendService(lambda *_: None, memory_backend=memory,
                             target_directory=tmp_path / "library",
                             recording_directory=tmp_path / "recording")
    try:
        service.handle(RpcMethod.CONNECT, {})
        with pytest.raises(ProtocolError, match="unknown_target"):
            service.handle(RpcMethod.SELECT_TARGET, {"name": "nonexistent-chip"})
        assert memory.connections == 1
        assert memory.config is not None
        assert service.state_snapshot()["connectionStatus"] == "connected"
        memory.fail_connect = True
        with pytest.raises(ProtocolError, match="connect_failed"):
            service.handle(RpcMethod.SELECT_TARGET, {"name": "nrf52840"})
        state = service.state_snapshot()
        assert state["connectionStatus"] == "disconnected"
        assert state["targetName"] == "nrf52840"
        memory.fail_connect = False
        service.handle(RpcMethod.CONNECT, {})
        assert memory.config.target == "nrf52840"
    finally:
        service.close()


def test_switch_waits_for_an_inflight_connection(tmp_path):
    from concurrent.futures import ThreadPoolExecutor

    entered, release = threading.Event(), threading.Event()

    class BlockingMemory(Memory):
        def connect(self, config):
            if not self.connections:
                entered.set()
                assert release.wait(3)
            super().connect(config)

    memory = BlockingMemory()
    service = BackendService(lambda *_: None, memory_backend=memory,
                             target_directory=tmp_path / "library",
                             recording_directory=tmp_path / "recording")
    try:
        with ThreadPoolExecutor(max_workers=2) as workers:
            connecting = workers.submit(service.handle, RpcMethod.CONNECT, {})
            try:
                assert entered.wait(1)
                switching = workers.submit(service.handle, RpcMethod.SELECT_TARGET, {"name": "nrf52840"})
                assert not switching.done()
            finally:
                release.set()
            connecting.result(timeout=3)
            result = switching.result(timeout=3)
        assert memory.connections == 2
        assert memory.config.target == "nrf52840"
        assert result["state"]["connectionStatus"] == "connected"
    finally:
        release.set()
        service.close()


def test_pack_worker_does_not_block_control_requests(tmp_path, monkeypatch):
    monkeypatch.setenv("TAL_PACKS_DIR", str(tmp_path / "library"))
    output = io.BytesIO()
    server = StdioServer(io.StringIO(), output)
    entered, release = threading.Event(), threading.Event()
    def inspect(_):
        entered.set()
        assert release.wait(3)
        return {"targetCount": 1}
    try:
        with patch.object(server._service._targets, "inspect", side_effect=inspect):
            server._handle_line(json.dumps({"v": 3, "id": 1, "method": "inspectTargetPack", "params": {"path": "test.pack"}}))
            assert entered.wait(1)
            server._handle_line('{"v":3,"id":2,"method":"getState"}')
            server._output_worker.drain()
            assert any(json.loads(line).get("id") == 2 for line in output.getvalue().splitlines())
            assert not any(json.loads(line).get("id") == 1 for line in output.getvalue().splitlines())
            release.set()
            server._catalog_worker.drain()
    finally:
        release.set()
        server.close()
