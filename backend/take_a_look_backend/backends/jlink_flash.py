"""Program through SEGGER's DLL using the existing probe's pylink handle."""
from __future__ import annotations

from pathlib import Path
import re
from tempfile import TemporaryDirectory
from time import perf_counter

from intelhex import IntelHex
from pylink.errors import JLinkException
from pyocd.core.target import Target

from .local_firmware import verify_firmware
from take_a_look_backend.protocol import ProtocolError


def resolve_device(link, names: list[str]) -> str:
    """Accept exact DLL names and STM32 DFP names with package suffixes.

    Family aliases such as stm32h723xx deliberately cannot pick an arbitrary
    package or flash size. The user must select a concrete part from a DFP.
    """
    candidates = []
    for name in names:
        if not name:
            continue
        candidates.append(name)
        # CMSIS STM32 DFPs use names such as STM32H723VGTx; the DLL uses VG.
        if re.fullmatch(r"STM32[A-Z0-9]+[A-Z]x", name, re.IGNORECASE):
            candidates.append(name[:-2])
    for name in dict.fromkeys(candidates):
        try:
            return link.supported_device(link.get_device_index(name)).name
        except JLinkException:
            continue
    selected = next(iter(names), "")
    raise ProtocolError(
        "jlink_device_unsupported",
        "J-Link 官方库无法识别所选芯片，请在芯片库中选择具体型号（可导入 DFP），并确认 J-Link 软件支持该型号。",
        f"所选型号：{selected or '未指定'}；通用 Cortex-M 和带 xx 的系列别名不能确定 Flash 算法。",
    )


def program_jlink(session, segments: list[tuple[int, bytes]], progress, *,
                  part_number: str | None, target_name: str | None,
                  frequency_hz: int) -> dict[str, int | float | str]:
    started = perf_counter()
    target = session.target
    link = session.probe._link
    names = [name for name in (part_number, target_name, target.part_number) if isinstance(name, str) and name]
    device = resolve_device(link, names)
    flash_image = IntelHex()
    ram = []
    for address, data in segments:
        offset = 0
        while offset < len(data):
            cursor = address + offset
            region = target.memory_map.get_region_for_address(cursor, target.selected_core.node_name)
            size = min(len(data) - offset, region.end + 1 - cursor)
            if region.is_flash:
                flash_image.puts(cursor, data[offset:offset + size])
            else:
                ram.append((cursor, data[offset:offset + size]))
            offset += size

    # One HEX download keeps discontiguous data in the same flash transaction.
    # Only validated PT_LOAD payloads are staged: no padding, BSS or debug data.
    with TemporaryDirectory(prefix="tal-jlink-") as directory:
        path = Path(directory) / "firmware.hex"
        flash_image.write_hex_file(str(path))
        target.flush()
        core = target.selected_core
        session.notify(Target.Event.PRE_RESET, core)
        try:
            # Reuse the opened probe; a second DLL handle would compete for it.
            link.connect(device, speed=max(1, frequency_hz // 1000))
            link.reset(halt=True)
            link.exec_command("EnableFlashDL")
            # Match pyOCD's configured preservation of bytes outside the image.
            keep_unwritten = session.options.get("keep_unwritten")
            link.exec_command(f"SetFlashDLNoRMWThreshold = {0xFFFFFFFF if keep_unwritten else 0}")
            last_progress = 0.0
            def native_progress(action, message, percentage):
                nonlocal last_progress
                # The DLL restarts percentages for compare/erase/program/verify.
                if isinstance(action, bytes):
                    action = action.decode("ascii", errors="replace")
                base, span = {"Compare": (0, 0.1), "Erase": (0.1, 0.15),
                              "Flash": (0.25, 0.5), "Verify": (0.75, 0.05)}.get(action, (0, 0.8))
                last_progress = max(last_progress, min(0.8, max(0.0, base + percentage / 100 * span)))
                progress(last_progress)

            program_started = perf_counter()
            link.flash_file(str(path), 0, on_progress=native_progress)
            link.halt()
            # Flash algorithms use work RAM. Load RAM payloads afterwards so
            # the algorithm cannot overwrite data already loaded from the ELF.
            for address, data in ram:
                written = link.memory_write8(address, list(data))
                if written != len(data):
                    raise ProtocolError("firmware_write_failed", "J-Link RAM 写入不完整，未确认下载成功。",
                                        f"地址 0x{address:08X}，期望 {len(data)} 字节，实际 {written} 字节")
            program_s = perf_counter() - program_started
            progress(0.8)
            verify_started = perf_counter()
            verify_firmware(segments, link.memory_read8, progress)
            return {
                "engine": "jlink", "device": device,
                "data_bytes": sum(len(data) for _, data in segments),
                "program_s": program_s, "verify_s": perf_counter() - verify_started,
                "total_s": perf_counter() - started,
            }
        finally:
            # Native calls bypass pyOCD's DP SELECT/AP CSW caches. Reset events
            # invalidate them even on failure, before later debugging or RTT.
            session.notify(Target.Event.POST_RESET, core)
