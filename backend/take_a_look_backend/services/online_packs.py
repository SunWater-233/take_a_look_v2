"""Cancellable online CMSIS-Pack search and download, independent of probe I/O."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from urllib.error import URLError
import uuid
from pathlib import Path
from urllib.parse import urljoin, urlparse
from xml.etree import ElementTree

from take_a_look_backend.protocol import ProtocolError
from take_a_look_backend.services.target_catalog import MAX_PACK_BYTES, TargetCatalog


class _Cancelled(Exception):
    pass


def _network_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"https", "http"} or not parsed.hostname or parsed.username or parsed.password:
        raise ProtocolError("invalid_pack_url", "芯片包的下载地址无效。")
    return value


def _xml(data: bytes):
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Unsupported XML entity")
    return ElementTree.fromstring(data)


def _fetch(url: str, limit: int) -> bytes:
    request = urllib.request.Request(_network_url(url), headers={"User-Agent": "TakeALook/0.1 CMSIS-Pack"})
    deadline = time.monotonic() + 30
    with urllib.request.urlopen(request, timeout=10) as response:
        _network_url(response.url)
        data = bytearray()
        read = getattr(response, "read1", response.read)
        while block := read(64 * 1024):
            data.extend(block)
            if len(data) > limit or time.monotonic() > deadline:
                raise ValueError("Descriptor too large or slow")
        return bytes(data)


def _descriptor(entry: dict) -> dict:
    vendor, name = entry["vendor"], entry["name"]
    base = _network_url(entry["url"])
    # Prefer HTTPS for old index entries, retaining the published HTTP fallback.
    descriptor_url = urljoin(base.rstrip("/") + "/", f"{vendor}.{name}.pdsc")
    try:
        raw = _fetch(descriptor_url.replace("http://", "https://", 1), 16 * 1024 * 1024)
    except Exception:
        if not descriptor_url.startswith("http://"):
            raise
        raw = _fetch(descriptor_url, 16 * 1024 * 1024)
    root = _xml(raw)
    if (root.findtext("vendor"), root.findtext("name")) != (vendor, name):
        raise ValueError("Descriptor identity mismatch")
    release = root.find("releases/release")
    version = release.get("version", "") if release is not None else ""
    url = _network_url(urljoin((root.findtext("url") or base).strip().rstrip("/") + "/",
                               (release.get("url") if release is not None else None)
                               or f"{vendor}.{name}.{version}.pack"))
    parts, vendors = set(), set()

    def visit(node, cores=(), device_vendor=""):
        cores = (*cores, *(p.get("Dcore", "") for p in node.findall("processor")))
        device_vendor = node.get("Dvendor", device_vendor)
        part = node.get("Dvariant") or node.get("Dname")
        if part and any(core.startswith("Cortex-M") or core in {"SC000", "SC300"} for core in cores):
            parts.add(part)
            vendors.add(device_vendor.split(":")[0])
        for child in node:
            if child.tag in {"devices", "family", "subFamily", "device", "variant"}:
                visit(child, cores, device_vendor)
    visit(root)
    return {"id": hashlib.sha256(f"{vendor}.{name}.{version}:{url}".encode()).hexdigest(),
            "vendor": vendor, "name": name, "version": version, "url": url,
            "parts": sorted(parts), "deviceVendors": sorted(vendors), "indexEntry": entry}


def update_pack_index(directory: str) -> None:
    """Child-process entry, isolated so cancel/timeout stops all network workers."""
    from concurrent.futures import ThreadPoolExecutor, as_completed

    path = Path(directory)
    root = _xml(_fetch("https://www.keil.com/pack/index.pidx", 16 * 1024 * 1024))
    entries = [dict(node.attrib) for node in root.iter("pdsc")]
    try:
        previous = json.loads((path / "previous.json").read_text(encoding="utf-8"))["packs"]
    except (OSError, ValueError, KeyError):
        previous = []
    cached = {json.dumps(record.get("indexEntry"), sort_keys=True): record for record in previous}
    records, failures = [], 0
    with ThreadPoolExecutor(max_workers=32) as pool:
        futures = []
        for entry in entries:
            old = cached.get(json.dumps(entry, sort_keys=True))
            if old is not None:
                records.append(old)
            else:
                futures.append(pool.submit(_descriptor, entry))
        current = len(records)
        print(json.dumps({"current": current, "total": len(entries)}), flush=True)
        for future in as_completed(futures):
            try:
                records.append(future.result())
            except Exception:
                failures += 1
            current += 1
            print(json.dumps({"current": current, "total": len(entries)}), flush=True)
    if not any(record["parts"] for record in records):
        raise RuntimeError("在线芯片索引为空，请检查网络后重试。")
    (path / "compact.json").write_text(json.dumps({"version": 1, "packs": records, "failures": failures},
                                                 ensure_ascii=False), encoding="utf-8")


class OnlinePacks:
    def __init__(self, catalog: TargetCatalog, publish_state, *, index_timeout=300, download_timeout=600):
        self._catalog = catalog
        self._publish_state = publish_state
        self._index_timeout = index_timeout
        self._download_timeout = download_timeout
        self._lock = threading.RLock()
        self._cancel = threading.Event()
        self._thread: threading.Thread | None = None
        self._process: subprocess.Popen | None = None
        self._records: list[dict] | None = None
        self._warning = ""
        self._job: dict = {"status": "idle"}
        self._closed = False

    def request(self, params) -> dict:
        operation = params.get("operation")
        with self._lock:
            if operation in {"status", "cancel"}:
                if params.get("jobId") != self._job.get("jobId"):
                    raise ProtocolError("unknown_pack_job", "在线芯片包任务已失效，请重新搜索。")
                if operation == "cancel" and self._job["status"] == "running":
                    self._cancel.set()
                    if self._process is not None and self._process.poll() is None:
                        self._process.terminate()
                return self._snapshot()
            if operation not in {"search", "download"}:
                raise ProtocolError("invalid_request", "未知的在线芯片包操作。")
            if self._closed or self._job["status"] == "running":
                raise ProtocolError("busy", "在线芯片包任务正在进行，请先等待或取消。")
            query = params.get("query", "")
            if not isinstance(query, str) or len(query) > 128:
                raise ProtocolError("invalid_request", "搜索关键词过长或无效。")
            query = query.strip()
            if operation == "search" and len(query) < 2 and params.get("refresh") is not True:
                raise ProtocolError("invalid_request", "请至少输入两个字符搜索芯片。")
            record = None
            if operation == "download":
                record = next((item for item in self._load() if item["id"] == params.get("packId")), None)
                if record is None:
                    raise ProtocolError("unknown_pack", "在线芯片包索引已改变，请重新搜索。")
            self._cancel = threading.Event()
            self._job = {"jobId": uuid.uuid4().hex, "status": "running", "phase": operation,
                         "message": "正在搜索芯片包…" if operation == "search" else "正在连接下载服务器…"}
            self._thread = threading.Thread(target=self._run, args=(operation, query, record, params.get("refresh") is True),
                                            name="tal-online-packs", daemon=True)
            self._thread.start()
            return self._snapshot()

    def _snapshot(self):
        result = copy.deepcopy(self._job)
        if "state" in result.get("result", {}):
            result["state"] = result["result"]["state"]
        return result

    def _workspace(self) -> Path:
        path = self._catalog._workspace() / "online"
        path.mkdir(exist_ok=True)
        return path

    def _load(self) -> list[dict]:
        if self._records is None:
            try:
                data = json.loads((self._workspace() / "index.json").read_text(encoding="utf-8"))
                self._records = data["packs"] if data.get("version") == 1 else []
                self._set_warning(data.get("failures", 0))
                if not isinstance(self._records, list):
                    self._records = []
            except (OSError, ValueError, KeyError, TypeError):
                self._records = []
        return self._records

    def _set_warning(self, failures):
        self._warning = (f"有 {failures} 个芯片包描述暂时无法访问，搜索结果可能不完整；可稍后更新在线索引重试。"
                         if failures else "")

    def _check(self):
        if self._cancel.is_set():
            raise _Cancelled()

    def _progress(self, **values):
        with self._lock:
            self._job.update(values)

    def _run(self, operation, query, record, refresh):
        try:
            if operation == "search":
                if refresh or not self._load():
                    self._refresh()
                self._check()
                result = self._search(query)
                self._check()
            else:
                result = self._download(record, query)
            with self._lock:
                self._job.update(status="succeeded", result=result)
        except _Cancelled:
            self._progress(status="cancelled", message="已取消。")
        except Exception as error:
            if self._cancel.is_set():
                self._progress(status="cancelled", message="已取消。")
            else:
                self._progress(status="failed", message=error.message if isinstance(error, ProtocolError) else
                               "在线芯片包操作失败，请检查网络、代理或磁盘空间后重试。",
                               errorCode=error.code if isinstance(error, ProtocolError) else "online_pack_failed",
                               details=str(error))

    def _refresh(self):
        self._progress(phase="index", message="正在更新在线芯片索引，首次使用可能需要几分钟…")
        directory = self._workspace() / f"index-{uuid.uuid4().hex}"
        directory.mkdir()
        previous = self._workspace() / "index.json"
        if previous.is_file():
            shutil.copyfile(previous, directory / "previous.json")
        timer = None
        process = None
        timed_out = threading.Event()
        try:
            command = [sys.executable]
            if not getattr(sys, "frozen", False):
                command += ["-u", "-m", "take_a_look_backend.stdio"]
            command += ["--update-pack-index", str(directory)]
            environment = {**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[2]), "PYTHONUTF8": "1"}
            with (directory / "stderr.log").open("w", encoding="utf-8") as errors:
                with self._lock:
                    self._check()
                    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors, text=True,
                                               encoding="utf-8", errors="replace", env=environment,
                                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                    self._process = process

                def timeout():
                    timed_out.set()
                    if process.poll() is None:
                        process.kill()

                timer = threading.Timer(self._index_timeout, timeout)
                timer.start()
                for line in process.stdout:
                    self._check()
                    try:
                        progress = json.loads(line)
                        current, total = int(progress["current"]), progress.get("total")
                        self._progress(message=f"正在更新在线芯片索引：{current} / {total or '?'}")
                    except (ValueError, KeyError, TypeError):
                        pass
                process.wait()
            self._check()
            if timed_out.is_set():
                raise ProtocolError("pack_index_timeout", "在线芯片索引更新超时，请检查网络后重试。")
            if process.returncode != 0:
                raise ProtocolError("pack_index_failed", "无法更新在线芯片索引，请检查网络或代理后重试。",
                                    (directory / "stderr.log").read_text(encoding="utf-8", errors="replace")[-2000:])
            data = json.loads((directory / "compact.json").read_text(encoding="utf-8"))
            records = data["packs"]
            if not records:
                raise ProtocolError("pack_index_empty", "没有获取到可用的在线芯片包，请稍后重试。")
            self._check()
            temporary = directory / "compact.json"
            os.replace(temporary, self._workspace() / "index.json")
            self._records = records
            self._set_warning(data.get("failures", 0))
        finally:
            if timer is not None:
                timer.cancel()
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait()
                process.stdout.close()
            with self._lock:
                self._process = None
            shutil.rmtree(directory, ignore_errors=True)

    def _search(self, query):
        terms = query.lower().split()
        packs = []
        installed = self._catalog.snapshot()["packs"]
        for record in self._load():
            label = f"{record['vendor']} {record['name']} {' '.join(record['deviceVendors'])}".lower()
            matches = [part for part in record["parts"] if all(term in f"{label} {part.lower()}" for term in terms)]
            if not terms or not matches:
                continue
            existing = next((p for p in installed if p["available"] and
                             (p["vendor"], p["name"], p["version"]) ==
                             (record["vendor"], record["name"], record["version"])), None)
            packs.append({key: record[key] for key in ("id", "vendor", "name", "version")} |
                         {"matchingParts": matches[:8], "matchCount": len(matches),
                          "installedPackId": existing["id"] if existing else ""})
        packs.sort(key=lambda item: (query.lower() not in [part.lower() for part in item["matchingParts"]],
                                     item["vendor"], item["name"]))
        return {"packs": packs[:100], "total": len(packs), "query": query, "warning": self._warning}

    def _download(self, record, query):
        path = self._workspace() / f"download-{uuid.uuid4().hex}.pack"
        preview = None
        deadline = time.monotonic() + self._download_timeout
        try:
            self._check()
            url = _network_url(record["url"])
            headers = {"User-Agent": "TakeALook/0.1 CMSIS-Pack", "Accept-Encoding": "identity"}
            try:
                response = urllib.request.urlopen(urllib.request.Request(url.replace("http://", "https://", 1),
                                                                         headers=headers), timeout=30)
            except URLError:
                if not url.startswith("http://"):
                    raise
                self._check()
                response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30)
            with response, path.open("xb") as writer:
                _network_url(response.url)
                total = int(response.headers.get("Content-Length", "0"))
                if total > MAX_PACK_BYTES:
                    raise ProtocolError("pack_too_large", "芯片包超过 512 MiB，无法下载。")
                received = 0
                self._progress(phase="download", message="正在下载芯片包…", bytesReceived=0, totalBytes=total)
                read = getattr(response, "read1", response.read)
                while True:
                    self._check()
                    if time.monotonic() > deadline:
                        raise ProtocolError("pack_download_timeout", "芯片包下载超时，请重试。")
                    block = read(64 * 1024)
                    if not block:
                        break
                    received += len(block)
                    if received > MAX_PACK_BYTES:
                        raise ProtocolError("pack_too_large", "芯片包超过 512 MiB，无法下载。")
                    writer.write(block)
                    self._progress(bytesReceived=received)
            if total and received != total:
                raise ProtocolError("pack_download_incomplete", "芯片包下载不完整，请重新下载。")
            self._check()
            self._progress(phase="import", message="下载完成，正在校验并导入芯片库…")
            preview = self._catalog.inspect(str(path))
            if (preview["vendor"], preview["name"], preview["version"]) != (record["vendor"], record["name"], record["version"]):
                raise ProtocolError("pack_identity_mismatch", "下载的芯片包与在线索引不符，请更新索引后重试。")
            with self._lock:
                self._check()
                imported = self._catalog.import_pack(preview["previewId"])
                state = self._publish_state()
            terms = query.lower().split()
            part = next((p for p in record["parts"] if all(t in p.lower() for t in terms)), "")
            return {**imported, "partNumber": part, "state": state}
        finally:
            if preview is not None:
                self._catalog.discard_preview(preview["previewId"])
            path.unlink(missing_ok=True)

    def close(self):
        with self._lock:
            self._closed = True
            self._cancel.set()
            if self._process is not None and self._process.poll() is None:
                self._process.terminate()
        if self._thread is not None:
            self._thread.join(timeout=20)
