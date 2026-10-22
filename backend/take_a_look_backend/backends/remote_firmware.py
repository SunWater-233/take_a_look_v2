"""Ember firmware staging and asynchronous, verified phone flash jobs."""
from __future__ import annotations

import hashlib
import io
from pathlib import Path
import time

from elftools.elf.elffile import ELFFile
from take_a_look_backend.protocol import ProtocolError

MAX_FIRMWARE_BYTES = 64 * 1024 * 1024
FLASH_TIMEOUT = 900


def firmware_image(path: str) -> tuple[bytes, list[tuple[int, bytes]]]:
    source = Path(path)
    if not 0 < source.stat().st_size <= MAX_FIRMWARE_BYTES:
        raise ProtocolError("invalid_firmware", "固件大小必须为 1 字节至 64 MiB。")
    data = source.read_bytes()
    if not 0 < len(data) <= MAX_FIRMWARE_BYTES:
        raise ProtocolError("invalid_firmware", "固件大小已变化，请重新编译后下载。")
    try:
        elf = ELFFile(io.BytesIO(data))
        if elf.header.e_machine != "EM_ARM":
            raise ValueError("not an ARM image")
        loads = []
        for segment in elf.iter_segments():
            if segment.header.p_type != "PT_LOAD" or not segment.header.p_filesz:
                continue
            address, content = int(segment.header.p_paddr), segment.data()
            if len(content) != segment.header.p_filesz or address + len(content) > 0x100000000:
                raise ValueError("incomplete or out-of-range load segment")
            loads.append(segment)
        if not loads:
            raise ValueError("no loadable firmware data")
        # GDB loads object-file sections. Map their file offsets back to LMAs
        # so initialized RAM data is verified at its physical flash address.
        sections = []
        for section in elf.iter_sections():
            if not section["sh_flags"] & 2 or section["sh_type"] == "SHT_NOBITS" or not section["sh_size"]:
                continue
            for segment in loads:
                offset = section["sh_offset"] - segment["p_offset"]
                if offset >= 0 and offset + section["sh_size"] <= segment["p_filesz"]:
                    sections.append((int(segment["p_paddr"]) + offset, section.data()))
                    break
        return data, sections
    except Exception as error:
        raise ProtocolError("invalid_firmware", "请选择包含完整 ARM 加载段的 ELF / AXF 固件。", str(error)) from error


def flash_phone(client, session_id: int, path: str, data: bytes, progress) -> None:
    digest = hashlib.sha256(data).hexdigest()
    upload_id = None
    submitted = False
    progress(0)
    try:
        upload_id = client.call("firmware_begin", {"name": Path(path).name, "size": len(data), "sha256": digest})["id"]
        result = client.upload_bytes(upload_id, data, progress=lambda value: progress(.2 * value))
        if result.get("received") != len(data):
            raise ProtocolError("firmware_upload_failed", "手机未收到完整固件，未开始烧录。")
        result = client.call("firmware_finish", {"upload_id": upload_id})
        if result.get("ready") is not True or result.get("sha256", digest) != digest:
            raise ProtocolError("firmware_upload_failed", "手机固件校验失败，未开始烧录。")
        # Once submitted, its result may be unknown on network failure. Never
        # retry the flash request or abort its firmware while it may be in use.
        submitted = True
        job_id = client.call("flash", {"session_id": session_id, "firmware_id": upload_id,
                                      "format": "elf", "run_after": False})["job_id"]
        deadline = time.monotonic() + FLASH_TIMEOUT
        peak = .2
        while True:
            flash = client.call("backend_state").get("flash") or {}
            if flash.get("id") != job_id:
                raise ProtocolError("firmware_job_changed", "手机烧录任务已改变，无法确认本次下载结果。")
            if flash.get("state") == "failed":
                raise ProtocolError("firmware_flash_failed", "手机烧录或回读校验失败。", flash.get("error"))
            if flash.get("state") == "succeeded":
                progress(1)
                return
            stage = str(flash.get("stage") or "preparing").lower()
            base, span = (.2, .1) if "eras" in stage else (.3, .5) if "program" in stage else (.8, .19) if "verif" in stage else (.2, 0)
            total, done = flash.get("total"), flash.get("done", 0)
            fraction = min(1.0, max(0.0, done / total)) if isinstance(total, (int, float)) and total > 0 else 0
            peak = max(peak, min(.99, base + span * fraction))
            progress(peak)
            if time.monotonic() >= deadline:
                raise ProtocolError("firmware_flash_timeout", "手机烧录尚未完成，结果未知；请先在手机检查任务状态，勿重复下载。")
            time.sleep(.25)
    except Exception:
        if upload_id is not None and not submitted:
            try:
                client.call("firmware_abort", {"upload_id": upload_id})
            except Exception:
                pass
        raise
