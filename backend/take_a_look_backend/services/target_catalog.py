"""User-owned CMSIS packs and target metadata, independent of probe sessions."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import posixpath
import sys
import tempfile
import threading
import uuid
import zipfile
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from xml.etree import ElementTree

from take_a_look_backend.protocol import ProtocolError

MAX_PACK_BYTES = 512 * 1024 * 1024
MAX_PDSC_BYTES = 16 * 1024 * 1024


def default_bundled_pack_directory() -> Path:
    if value := os.environ.get("TAL_BUNDLED_PACKS_DIR"):
        return Path(value).expanduser()
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent / "bundled_packs"
    backend = Path(__file__).resolve().parents[2]
    source = backend / "bundled_packs"
    return source if source.is_dir() else backend / "runtime/take_a_look_backend/bundled_packs"


def default_pack_directory() -> Path:
    if value := os.environ.get("TAL_PACKS_DIR"):
        return Path(value).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local")))
        return base / "TakeALook/packs"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/TakeALook/packs"
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "take-a-look/packs"


def normalise(name: str) -> str:
    from pyocd.target import normalise_target_type_name
    return normalise_target_type_name(name)


def _memory_details(elements) -> list[dict[str, object]]:
    regions = {}
    for node in elements:
        try:
            start = int(node.get("start", ""), 0)
            size = int(node.get("size", ""), 0)
            if start < 0 or size <= 0:
                continue
        except ValueError:
            continue
        name = node.get("name") or node.get("id", "memory")
        access = node.get("access", "")
        kind = "ram" if "w" in access or "RAM" in name.upper() else "rom"
        regions[name] = {"name": name, "start": start, "size": size, "kind": kind}
    return list(regions.values())


@lru_cache(maxsize=1)
def builtin_targets() -> tuple[dict[str, object], ...]:
    # TARGET also contains dynamically registered packs. Only the immutable
    # builtin table is suitable for cataloguing and restoring a fresh session.
    from pyocd.target.builtin import BUILTIN_TARGETS
    records = [{"id": "builtin:auto", "name": "auto", "partNumber": "自动选择 / 通用 Cortex-M",
                "vendor": "", "families": [], "cores": [], "memories": [], "packId": "",
                "source": "builtin", "packLabel": "内置", "available": True}]
    for name, target in sorted(BUILTIN_TARGETS.items()):
        memory_map = getattr(target, "MEMORY_MAP", None)
        memories = [{"name": region.name, "start": region.start, "size": region.length,
                     "kind": "ram" if region.is_ram else "rom"}
                    for region in memory_map or [] if region.is_ram or region.is_flash]
        records.append({"id": f"builtin:{name}", "name": name, "partNumber": name,
                        "vendor": getattr(target, "VENDOR", "") or "", "families": [],
                        "cores": [], "memories": memories, "packId": "", "source": "builtin",
                        "packLabel": "内置", "available": True})
    return tuple(records)


def _parse_pack(path: Path, digest: str) -> dict[str, object]:
    from pyocd.target.pack.cmsis_pack import CmsisPack

    with zipfile.ZipFile(path) as archive:
        descriptions = [item for item in archive.infolist() if item.filename.lower().endswith(".pdsc")]
        if len(descriptions) != 1 or descriptions[0].file_size > MAX_PDSC_BYTES:
            raise ProtocolError("invalid_pack", "芯片包必须包含一个有效的 PDSC 描述文件（不超过 16 MiB）。")
        if sum(item.file_size for item in archive.infolist()) > 4 * 1024**3:
            raise ProtocolError("invalid_pack", "芯片包展开后超过 4 GiB，无法导入。")
        pdsc = archive.read(descriptions[0])
        if b"<!DOCTYPE" in pdsc.upper() or b"<!ENTITY" in pdsc.upper():
            raise ProtocolError("invalid_pack", "PDSC 包含不支持的 XML 实体定义。")
        root = ElementTree.fromstring(pdsc)
        name = root.findtext("name", "").strip()
        vendor = root.findtext("vendor", "").strip()
        release = root.find("releases/release")
        version = release.get("version", "") if release is not None else ""
        if not name or not vendor or not version:
            raise ProtocolError("invalid_pack", "PDSC 缺少芯片包名称、厂商或版本。")

        # pyOCD handles device/variant inheritance. Read lightweight display
        # metadata separately so indexing never loads hundreds of flash algos.
        metadata = {}
        base = posixpath.dirname(descriptions[0].filename)
        members = set(archive.namelist())

        def visit(node, memories=(), processors=(), algorithms=()):
            memories = (*memories, *node.findall("memory"))
            processors = (*processors, *node.findall("processor"))
            algorithms = (*algorithms, *node.findall("algorithm"))
            part = node.get("Dvariant") or node.get("Dname")
            if part:
                cores = list(dict.fromkeys(p.get("Dcore", "") for p in processors if p.get("Dcore")))
                metadata[part] = (cores, _memory_details(memories), algorithms)
            for child in node:
                if child.tag in {"devices", "family", "subFamily", "device", "variant"}:
                    visit(child, memories, processors, algorithms)
        visit(root)
        pack = CmsisPack(archive)
        targets = []
        seen = set()
        unsupported = 0
        for device in pack.devices:
            cores, memories, algorithms = metadata.get(device.part_number, ([], [], []))
            if not any(core.startswith("Cortex-M") or core in {"SC000", "SC300"} for core in cores):
                unsupported += 1
                continue
            target_name = normalise(device.part_number)
            if target_name in seen:
                raise ProtocolError("ambiguous_target", f"包内多个芯片映射到同一个目标名称：{target_name}")
            seen.add(target_name)
            for algorithm in algorithms:
                filename = algorithm.get("name", "").replace("\\", "/")
                if filename and posixpath.normpath(posixpath.join(base, filename)) not in members:
                    raise ProtocolError("missing_algorithm", f"芯片包缺少烧录算法：{filename}")
            targets.append({"id": f"{digest}:{target_name}", "name": target_name,
                            "partNumber": device.part_number, "vendor": device.vendor,
                            "families": device.families, "cores": cores, "memories": memories,
                            "packId": digest, "packLabel": f"{vendor}.{name} {version}",
                            "source": "pack", "available": True})
        if not targets:
            raise ProtocolError("unsupported_pack", "这个包没有可供 pyOCD 使用的 Cortex-M 芯片。请选择芯片支持包（DFP）。")
        return {"id": digest, "name": name, "vendor": vendor, "version": version,
                "targetCount": len(targets), "unsupportedCount": unsupported, "targets": targets,
                "size": path.stat().st_size, "importedAt": datetime.now(timezone.utc).isoformat()}


class TargetCatalog:
    def __init__(self, directory: Path | None = None, *, bundled_directory: Path | None = None) -> None:
        self.directory = directory
        self._bundled_directory = bundled_directory
        self._bundled: dict[str, dict] = {}
        self._temporary: tempfile.TemporaryDirectory | None = None
        self._lock = threading.RLock()
        self._previews: dict[str, tuple[Path, dict[str, object]]] = {}
        self.revision = 0
        self.warning = ""
        if bundled_directory is not None and (bundled_directory / "index.json").is_file():
            try:
                bundled = json.loads((bundled_directory / "index.json").read_text(encoding="utf-8"))
                if bundled.get("version") != 1 or not isinstance(bundled.get("packs"), dict):
                    raise ValueError("Invalid bundled pack index")
                for digest, pack in bundled["packs"].items():
                    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                        raise ValueError("Invalid bundled pack identity")
                    if pack.get("id") != digest or not isinstance(pack.get("targets"), list):
                        raise ValueError("Invalid bundled pack metadata")
                self._bundled = {key: dict(pack, bundled=True) for key, pack in bundled["packs"].items()}
            except (OSError, ValueError, AttributeError, TypeError) as error:
                self.warning = f"无法读取软件自带芯片包：{error}。请重新安装软件。"
        self._data = {"version": 1, "packs": {}, "recent": [],
                      "selected": {"name": "auto", "packId": "", "partNumber": "auto", "packLabel": "内置"}}
        file = directory / "index.json" if directory is not None else None
        if file is not None and file.exists():
            try:
                data = json.loads(file.read_text(encoding="utf-8"))
                if data.get("version") != 1 or not isinstance(data.get("packs"), dict):
                    raise ValueError("Unsupported target catalog")
                for key, pack in data["packs"].items():
                    if len(key) != 64 or any(c not in "0123456789abcdef" for c in key):
                        raise ValueError("Invalid pack identity")
                    if not isinstance(pack.get("targets"), list):
                        raise ValueError("Invalid target metadata")
                if not isinstance(data.get("selected", {}).get("name"), str):
                    raise ValueError("Invalid selection")
                self._data = data
            except (OSError, ValueError, AttributeError, TypeError) as error:
                self.warning = f"无法读取原芯片库索引：{error}。请重新导入芯片包。"

    def _workspace(self) -> Path:
        if self.directory is None:
            if self._temporary is None:
                self._temporary = tempfile.TemporaryDirectory(prefix="tal-packs-")
            return Path(self._temporary.name)
        self.directory.mkdir(parents=True, exist_ok=True)
        return self.directory

    def _pack_path(self, pack_id: str) -> Path:
        # Callers must first resolve the id through the managed index.
        if pack_id in self._bundled and pack_id not in self._data["packs"]:
            return self._bundled_directory / f"{pack_id}.pack"
        return self._workspace() / f"{pack_id}.pack"

    def _packs(self) -> dict[str, dict]:
        return self._bundled | self._data["packs"]

    def _commit(self, data: dict) -> None:
        if self.directory is not None:
            directory = self._workspace()
            temporary = directory / f"index-{uuid.uuid4().hex}.tmp"
            created = False
            try:
                # On Windows, mkstemp retries PermissionError while os.access()
                # reports the directory as writable (e.g. a low-integrity
                # process). That can loop for billions of attempts. A unique,
                # exclusively created sibling still supports atomic replacement
                # and reports denied access immediately.
                with temporary.open("x", encoding="utf-8") as stream:
                    created = True
                    json.dump(data, stream, ensure_ascii=False, separators=(",", ":"))
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, directory / "index.json")
            except OSError as error:
                raise self._storage_error(error) from error
            finally:
                if created:
                    try:
                        temporary.unlink(missing_ok=True)
                    except OSError:
                        pass  # Preserve the original write/replace error.
        self._data = data
        self.revision += 1

    def _storage_error(self, error: OSError) -> ProtocolError:
        denied = isinstance(error, PermissionError)
        return ProtocolError(
            "target_catalog_access_denied" if denied else "target_catalog_io_error",
            "无法修改芯片库：文件被占用或当前启动环境没有写入权限。"
            "请关闭其他应用实例并检查目录权限。" if denied else "无法保存芯片库，请检查磁盘空间和目录状态。",
            f"目录：{self.directory}\n{error}",
        )

    @property
    def selected(self) -> dict[str, object]:
        with self._lock:
            return dict(self._data["selected"])

    def selection_state(self) -> dict[str, object]:
        with self._lock:
            selected = self._data["selected"]
            pack_id = selected.get("packId", "")
            missing = bool(pack_id and (pack_id not in self._packs() or not self._pack_path(pack_id).is_file()))
            return {"targetName": selected["name"], "targetPackId": pack_id,
                    "targetPartNumber": selected.get("partNumber", selected["name"]),
                    "targetPackLabel": selected.get("packLabel", "内置"), "targetPackMissing": missing,
                    "targetCatalogRevision": self.revision}

    def snapshot(self) -> dict[str, object]:
        builtins = builtin_targets()
        with self._lock:
            packs, targets = [], [dict(item) for item in builtins]
            for pack in self._packs().values():
                available = self._pack_path(pack["id"]).is_file()
                packs.append({key: value for key, value in pack.items() if key != "targets"} | {"available": available})
                targets.extend(dict(item, available=available) for item in pack["targets"])
            return {"revision": self.revision, "targets": targets, "packs": packs,
                    "recent": list(self._data.get("recent", [])), "warning": self.warning}

    def inspect(self, source: str) -> dict[str, object]:
        path = Path(source).expanduser()
        if path.suffix.lower() != ".pack" or not path.is_file():
            raise ProtocolError("invalid_pack", "请选择一个本地 .pack 芯片支持包。")
        if path.stat().st_size > MAX_PACK_BYTES:
            raise ProtocolError("invalid_pack", "芯片包超过 512 MiB，无法导入。")
        token = uuid.uuid4().hex
        staged = self._workspace() / f"pending-{token}.pack"
        try:
            digest = hashlib.sha256()
            total = 0
            with path.open("rb") as reader, staged.open("xb") as writer:
                while block := reader.read(1024 * 1024):
                    total += len(block)
                    if total > MAX_PACK_BYTES:
                        raise ProtocolError("invalid_pack", "芯片包超过 512 MiB，无法导入。")
                    writer.write(block)
                    digest.update(block)
            metadata = _parse_pack(staged, digest.hexdigest())
            with self._lock:
                while len(self._previews) >= 4:
                    old = self._previews.pop(next(iter(self._previews)))
                    old[0].unlink(missing_ok=True)
                self._previews[token] = (staged, metadata)
                return {key: value for key, value in metadata.items() if key != "targets"} | {
                    "previewId": token, "alreadyInstalled": metadata["id"] in self._packs() and self._pack_path(metadata["id"]).is_file(),
                    "sampleTargets": [item["partNumber"] for item in metadata["targets"][:8]]}
        except Exception as error:
            staged.unlink(missing_ok=True)
            if isinstance(error, ProtocolError):
                raise
            raise ProtocolError("invalid_pack", "无法解析芯片包。", str(error)) from error

    def discard_preview(self, token: str) -> None:
        with self._lock:
            if staged := self._previews.pop(token, None):
                staged[0].unlink(missing_ok=True)

    def import_pack(self, token: str) -> dict[str, object]:
        with self._lock:
            preview = self._previews.get(token)
            if preview is None:
                raise ProtocolError("preview_expired", "导入预览已失效，请重新选择芯片包。")
            staged, metadata = preview
            exists = metadata["id"] in self._packs() and self._pack_path(metadata["id"]).is_file()
            destination = self._workspace() / f"{metadata['id']}.pack"
            if not exists:
                data = copy.deepcopy(self._data)
                data["packs"][metadata["id"]] = metadata
                os.replace(staged, destination)
                try:
                    self._commit(data)
                except Exception:
                    destination.unlink(missing_ok=True)
                    self._previews.pop(token, None)
                    raise
            self.discard_preview(token)
            return {"packId": metadata["id"], "alreadyInstalled": exists}

    def select(self, name: str, pack_id: str = "", *, legacy: bool = False) -> None:
        name = normalise(name)
        with self._lock:
            if pack_id:
                pack = self._packs().get(pack_id)
                if pack is None or not self._pack_path(pack_id).is_file():
                    raise ProtocolError("target_pack_missing", "芯片包缺失，请重新导入后再选择。")
                record = next((item for item in pack["targets"] if item["name"] == name), None)
            else:
                record = next((item for item in builtin_targets() if item["name"] == name), None)
                # Older RPC callers could use externally managed pyOCD targets.
                if record is None and legacy:
                    record = {"name": name, "partNumber": name, "packId": "", "packLabel": "内置 / pyOCD"}
            if record is None:
                raise ProtocolError("unknown_target", "所选芯片不在这个来源中，请重新选择。")
            data = copy.deepcopy(self._data)
            data["selected"] = {key: record[key] for key in ("name", "packId", "partNumber", "packLabel")}
            key = f"{pack_id or 'builtin'}:{name}"
            data["recent"] = [key, *(item for item in data.get("recent", []) if item != key)][:12]
            self._commit(data)

    def connection_pack(self) -> str | None:
        with self._lock:
            pack_id = self._data["selected"].get("packId", "")
            if not pack_id:
                return None
            if pack_id not in self._packs() or not self._pack_path(pack_id).is_file():
                raise ProtocolError("target_pack_missing", "目标芯片的芯片包缺失，请重新导入后连接。")
            path = self._pack_path(pack_id)
            with path.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != pack_id:
                    raise ProtocolError("target_pack_changed", "芯片包文件已改变，请删除并重新导入。")
            return str(path)

    def remove(self, pack_id: str) -> None:
        with self._lock:
            if pack_id in self._bundled and pack_id not in self._data["packs"]:
                raise ProtocolError("bundled_pack_readonly", "这个芯片包由软件自带，不能从芯片库删除。")
            if pack_id not in self._data["packs"]:
                raise ProtocolError("unknown_pack", "这个芯片包已被删除。")
            data = copy.deepcopy(self._data)
            del data["packs"][pack_id]
            data["recent"] = [key for key in data.get("recent", []) if not key.startswith(f"{pack_id}:")]
            path = self._pack_path(pack_id)
            trash = path.with_name(f"removed-{uuid.uuid4().hex}.tmp")
            renamed = path.is_file()
            if renamed:
                try:
                    os.replace(path, trash)
                except OSError as error:
                    raise self._storage_error(error) from error
            try:
                self._commit(data)
            except Exception:
                if renamed:
                    os.replace(trash, path)
                raise
            # Retain the selected identity so restore never silently falls back.
            try:
                trash.unlink(missing_ok=True)
            except OSError:
                self.warning = f"芯片包已移出芯片库，但临时文件仍被占用：{trash.name}"

    def close(self) -> None:
        with self._lock:
            for token in list(self._previews):
                self.discard_preview(token)
            if self._temporary is not None:
                self._temporary.cleanup()
