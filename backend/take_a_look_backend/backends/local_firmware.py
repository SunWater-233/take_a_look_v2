"""Validate local firmware and verify payload bytes independently of its flash engine."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from take_a_look_backend.protocol import ProtocolError


VERIFY_CHUNK_BYTES = 16 * 1024


@dataclass
class FirmwareSector:
    chunks: list[tuple[int, bytes]] = field(default_factory=list)


def flash_sector_plan(target: Any, segments: list[tuple[int, bytes]]) -> list[FirmwareSector] | None:
    """Group all image bytes by erase sector, or retain pyOCD's general path.

    Direct comparison is only safe for readable, internal flash. RAM images,
    external memories requiring algorithm Init, and pages spanning erase sectors
    retain the original loader. Never compare padding or uninitialised ELF data.
    """
    sectors: dict[tuple[int, int], FirmwareSector] = {}
    for address, data in sorted(segments):
        offset = 0
        while offset < len(data):
            cursor = address + offset
            region = target.memory_map.get_region_for_address(cursor, target.selected_core.node_name)
            if (not region.is_flash or not region.is_readable or region.is_external
                    or not region.are_erased_sectors_readable):
                return None
            sector = region.flash.get_sector_info(cursor)
            page = region.flash.get_page_info(cursor)
            if (sector is None or page is None
                    or not all(isinstance(value, int) and value > 0
                               for value in (sector.size, page.size))):
                return None
            end = sector.base_addr + sector.size
            if (not region.contains_range(start=sector.base_addr, length=sector.size)
                    or not sector.base_addr <= page.base_addr <= cursor < page.base_addr + page.size <= end):
                return None
            size = min(len(data) - offset, end - cursor)
            planned = sectors.setdefault((region.start, sector.base_addr), FirmwareSector())
            chunk = data[offset:offset + size]
            if planned.chunks and planned.chunks[-1][0] + len(planned.chunks[-1][1]) == cursor:
                previous_address, previous_data = planned.chunks[-1]
                planned.chunks[-1] = (previous_address, previous_data + chunk)
            else:
                planned.chunks.append((cursor, chunk))
            offset += size
    return list(sectors.values())


def read_firmware_chunks(read_memory, chunks: list[tuple[int, bytes]]):
    """Read payload bytes in bounded blocks, leaving length checks to the caller."""
    for address, data in chunks:
        for offset in range(0, len(data), VERIFY_CHUNK_BYTES):
            expected = data[offset:offset + VERIFY_CHUNK_BYTES]
            actual = bytes(read_memory(address + offset, len(expected)))
            yield address + offset, expected, actual


def sector_matches(target: Any, sector: FirmwareSector, compared) -> bool:
    for address, expected, actual in read_firmware_chunks(target.read_memory_block8, sector.chunks):
        if len(actual) != len(expected):
            raise ProtocolError("memory_read_failed", "固件比较读取不完整，未执行擦写。",
                                f"地址 0x{address:08X}，期望 {len(expected)} 字节，实际 {len(actual)} 字节")
        compared(len(expected))
        if actual != expected:
            return False
    return True


def verify_firmware(segments: list[tuple[int, bytes]], read_memory, progress) -> None:
    total = sum(len(data) for _, data in segments)
    verified = 0
    for address, expected, actual in read_firmware_chunks(read_memory, segments):
        if actual != expected:
            mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                            min(len(actual), len(expected)))
            expected_byte = f"0x{expected[mismatch]:02X}" if mismatch < len(expected) else "数据结束"
            actual_byte = f"0x{actual[mismatch]:02X}" if mismatch < len(actual) else "未读到数据"
            raise ProtocolError("firmware_verify_failed", "固件写后校验失败，未确认下载成功。",
                                f"地址 0x{address + mismatch:08X}，"
                                f"期望 {expected_byte}，实际 {actual_byte}")
        verified += len(expected)
        progress(0.8 + 0.2 * verified / total)


def firmware_segments(path: str, target: Any, *, require_flash_algorithm: bool = True) -> list[tuple[int, bytes]]:
    """Validate every load address before allowing any erase or write."""
    from elftools.elf.elffile import ELFFile

    segments = []
    flash_bytes = 0
    memory_map = target.memory_map
    core_name = target.selected_core.node_name
    with open(path, "rb") as stream:
        elf = ELFFile(stream)
        if elf.header.e_machine != "EM_ARM":
            raise ProtocolError("invalid_firmware", "请选择适用于 ARM 目标的 ELF / AXF 固件。")
        for segment in elf.iter_segments():
            if segment.header.p_type != "PT_LOAD" or not segment.header.p_filesz:
                continue
            address = int(segment.header.p_paddr)
            data = segment.data()
            if len(data) != segment.header.p_filesz or address + len(data) > 0x100000000:
                raise ProtocolError("invalid_firmware", "固件段不完整或地址超出范围。")
            cursor = address
            while cursor < address + len(data):
                region = memory_map.get_region_for_address(cursor, core_name)
                if region is None:
                    raise ProtocolError("firmware_address_invalid", "固件地址不在所选芯片的内存范围内，请检查芯片型号。",
                                        f"地址 0x{cursor:08X}")
                size = min(address + len(data), region.end + 1) - cursor
                if region.is_flash:
                    if require_flash_algorithm and region.flash is None:
                        raise ProtocolError("flash_algorithm_missing", "所选芯片缺少可用的 Flash 烧录算法，请选择正确芯片或导入芯片包。",
                                            f"地址 0x{cursor:08X}")
                    flash_bytes += size
                elif not (region.is_ram and region.is_writable):
                    raise ProtocolError("firmware_address_invalid", "固件段必须位于 Flash 或可写 RAM 中。",
                                        f"地址 0x{cursor:08X}")
                cursor += size
            segments.append((address, data))
    if not segments:
        raise ProtocolError("firmware_empty", "固件中没有可下载的数据段。")
    if not flash_bytes:
        raise ProtocolError("flash_algorithm_missing", "固件未匹配到 Flash 区域；通用 Cortex-M 不支持固件烧录，请选择具体芯片型号。")
    previous_end = 0
    for address, data in sorted(segments):
        if address < previous_end:
            raise ValueError("Firmware load segments overlap.")
        previous_end = address + len(data)
    return segments
