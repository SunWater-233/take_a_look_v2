"""Plan local flash comparisons without running an algorithm or reading ELF gaps."""
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


def read_firmware_chunks(target: Any, chunks: list[tuple[int, bytes]]):
    """Read payload bytes in bounded blocks, leaving length checks to the caller."""
    for address, data in chunks:
        for offset in range(0, len(data), VERIFY_CHUNK_BYTES):
            expected = data[offset:offset + VERIFY_CHUNK_BYTES]
            actual = bytes(target.read_memory_block8(address + offset, len(expected)))
            yield address + offset, expected, actual


def sector_matches(target: Any, sector: FirmwareSector, compared) -> bool:
    for address, expected, actual in read_firmware_chunks(target, sector.chunks):
        if len(actual) != len(expected):
            raise ProtocolError("memory_read_failed", "固件比较读取不完整，未执行擦写。",
                                f"地址 0x{address:08X}，期望 {len(expected)} 字节，实际 {len(actual)} 字节")
        compared(len(expected))
        if actual != expected:
            return False
    return True
