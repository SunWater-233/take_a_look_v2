"""pyOCD flash algorithms, sector comparison and full readback verification."""
from __future__ import annotations

from time import perf_counter

from .local_firmware import flash_sector_plan, sector_matches, verify_firmware


def program_pyocd(session, segments: list[tuple[int, bytes]], progress) -> dict[str, int | float | str]:
    from pyocd.flash.loader import MemoryLoader

    started = perf_counter()
    target = session.target
    total = sum(len(data) for _, data in segments)
    # FileProgrammer catches invalid ELF segment addresses and only logs a
    # warning. Queue validated segments directly so no data can be skipped.
    last_progress = 0.0
    programming_start = 0.0
    def write_progress(value: float) -> None:
        nonlocal last_progress
        # pyOCD starts its progress range again between erase and program.
        last_progress = max(last_progress, min(0.8, max(0.0,
                            programming_start + value * (0.8 - programming_start))))
        progress(last_progress)
    loader = MemoryLoader(session, progress=write_progress,
                          chip_erase="sector", trust_crc=False)
    for address, data in segments:
        loader.add_data(address, data)
    sectors = flash_sector_plan(target, segments)
    # Pack algorithms may change Flash latency without resetting the
    # application's clocks (GD32E50x sets zero wait states). Start from
    # reset clocks before any smart-flash reads, erase, or programming.
    target.reset_and_halt()
    compare_started = perf_counter()
    compared_bytes = skipped_bytes = skipped_sectors = 0
    changed = []
    def compared(size: int) -> None:
        nonlocal compared_bytes
        compared_bytes += size
        progress(0.15 * compared_bytes / total)
    if sectors is not None:
        for sector in sectors:
            if sector_matches(target, sector, compared):
                skipped_bytes += sum(len(data) for _, data in sector.chunks)
                skipped_sectors += 1
            else:
                # Keep ALL image chunks in a changed sector, including
                # matching pages that its erase will destroy.
                changed.extend(sector.chunks)
        programming_start = last_progress = 0.15
        progress(last_progress)
        loader = MemoryLoader(session, progress=write_progress,
                              chip_erase="sector", trust_crc=False, smart_flash=False)
        for address, data in changed:
            loader.add_data(address, data)
    compare_s = perf_counter() - compare_started
    program_started = perf_counter()
    wrote = sectors is None or bool(changed)
    if wrote:
        loader.commit()
    program_s = perf_counter() - program_started
    target.halt()
    target.flush()
    progress(0.8)
    verify_started = perf_counter()
    if wrote:
        verify_firmware(segments, target.read_memory_block8, progress)
    stats = {
        "engine": "pyocd",
        "data_bytes": total, "compared_bytes": compared_bytes,
        "skipped_bytes": skipped_bytes, "skipped_sectors": skipped_sectors,
        "compare_s": compare_s, "program_s": program_s,
        "verify_s": perf_counter() - verify_started, "total_s": perf_counter() - started,
    }
    if not wrote:
        progress(1.0)
    return stats
