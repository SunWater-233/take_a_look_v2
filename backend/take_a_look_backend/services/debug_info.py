from __future__ import annotations

import bisect
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePath


@dataclass(frozen=True)
class SourceLocation:
    path: str
    line: int
    address: int


class DebugInfoIndex:
    """Bidirectional DWARF source-line index used by the debugger UI."""

    def __init__(self, locations: list[SourceLocation] | None = None) -> None:
        unique = {
            (_path_key(item.path), item.line, item.address): item
            for item in locations or []
            if item.line > 0 and item.address >= 0
        }
        self._locations = sorted(
            unique.values(), key=lambda item: (item.address, _path_key(item.path), item.line)
        )
        self._addresses = [item.address for item in self._locations]
        self._paths_by_key: dict[str, str] = {}
        self._lines_by_path: dict[str, dict[int, list[int]]] = {}
        for item in self._locations:
            key = _path_key(item.path)
            self._paths_by_key.setdefault(key, item.path)
            self._lines_by_path.setdefault(key, {}).setdefault(item.line, []).append(item.address)

    @property
    def source_files(self) -> list[str]:
        return sorted(self._paths_by_key.values(), key=str.casefold)

    @property
    def executable_lines(self) -> dict[str, list[int]]:
        """Return the exact source lines that have emitted instructions."""
        return {
            self._paths_by_key[key]: sorted(lines)
            for key, lines in self._lines_by_path.items()
        }

    def canonical_source_path(self, path: str) -> str | None:
        key = self._resolve_path_key(path)
        return self._paths_by_key[key] if key is not None else None

    def resolve_breakpoint(self, path: str, requested_line: int) -> SourceLocation | None:
        key = self._resolve_path_key(path)
        if key is None:
            return None
        lines = self._lines_by_path[key]
        addresses = lines.get(requested_line)
        if not addresses:
            return None
        return SourceLocation(
            path=self._paths_by_key[key],
            line=requested_line,
            address=min(addresses),
        )

    def resolve_address(self, address: int) -> SourceLocation | None:
        if not self._locations:
            return None
        index = bisect.bisect_right(self._addresses, address) - 1
        if index < 0:
            return None
        resolved_address = self._addresses[index]
        first_at_address = bisect.bisect_left(self._addresses, resolved_address)
        return self._locations[first_at_address]

    def _resolve_path_key(self, path: str) -> str | None:
        key = _path_key(path)
        if key in self._lines_by_path:
            return key
        basename = PurePath(path.replace("\\", "/")).name.casefold()
        matches = [candidate for candidate in self._lines_by_path if PurePath(candidate).name.casefold() == basename]
        return matches[0] if len(matches) == 1 else None


def load_debug_info_from_elf(
    path: Path, progress: Callable[[str, int, int], None] | None = None,
) -> DebugInfoIndex:
    from elftools.elf.elffile import ELFFile

    locations: list[SourceLocation] = []
    total = 0
    with path.open("rb") as handle:
        elf = ELFFile(handle)
        if not elf.has_dwarf_info():
            return DebugInfoIndex()
        dwarf_info = elf.get_dwarf_info()
        compile_units = list(dwarf_info.iter_CUs())
        # The final work item builds the bidirectional line/address index.
        total = len(compile_units) + 1
        if progress is not None:
            progress("source", 0, total)
        for unit_index, compile_unit in enumerate(compile_units):
            if progress is not None:
                progress("source", unit_index, total)
            try:
                line_program = dwarf_info.line_program_for_CU(compile_unit)
            except Exception:
                continue
            if line_program is None:
                continue
            top_die = compile_unit.get_top_DIE()
            compile_dir = _decode(top_die.attributes.get("DW_AT_comp_dir"))
            for entry in line_program.get_entries():
                state = entry.state
                if state is None or state.end_sequence or state.line is None:
                    continue
                source_path = _source_path(line_program, int(state.file), compile_dir)
                if source_path:
                    locations.append(
                        SourceLocation(
                            path=source_path,
                            line=int(state.line),
                            address=int(state.address),
                        )
                    )
    if progress is not None:
        progress("source", max(0, total - 1), total)
    result = DebugInfoIndex(locations)
    if progress is not None:
        progress("source", total, total)
    return result


def _source_path(line_program, file_index: int, compile_dir: str) -> str:
    file_entries = line_program.header.get("file_entry", [])
    index = file_index - 1
    if index < 0 or index >= len(file_entries):
        return ""
    entry = file_entries[index]
    name = _decode(getattr(entry, "name", ""))
    if not name:
        return ""
    name = name.replace("\\", "/")
    if name.startswith("/") or (len(name) > 2 and name[1] == ":"):
        return name

    directory = compile_dir.replace("\\", "/")
    directory_index = int(getattr(entry, "dir_index", 0) or 0) - 1
    include_dirs = line_program.header.get("include_directory", [])
    if 0 <= directory_index < len(include_dirs):
        include_dir = _decode(include_dirs[directory_index]).replace("\\", "/")
        if include_dir.startswith("/") or (len(include_dir) > 2 and include_dir[1] == ":"):
            directory = include_dir
        elif include_dir:
            directory = f"{directory.rstrip('/')}/{include_dir}" if directory else include_dir
    return f"{directory.rstrip('/')}/{name}" if directory else name


def _decode(attribute_or_value) -> str:
    if attribute_or_value is None:
        return ""
    value = getattr(attribute_or_value, "value", attribute_or_value)
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _path_key(path: str) -> str:
    return path.replace("\\", "/").rstrip("/").casefold()
