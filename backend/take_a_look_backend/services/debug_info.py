from __future__ import annotations

import bisect
from contextlib import nullcontext
from take_a_look_backend.services.elf_context import ElfLoadContext
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path, PurePath


@dataclass(frozen=True)
class SourceLocation:
    path: str
    line: int
    address: int


@dataclass(frozen=True)
class SourceDefinition:
    name: str
    path: str
    line: int
    kind: str
    scope: str = ""
    is_declaration: bool = False
    is_local: bool = False

    def to_json(self) -> dict[str, object]:
        result = asdict(self)
        result["isDeclaration"] = result.pop("is_declaration")
        result["isLocal"] = result.pop("is_local")
        return result


class DebugInfoIndex:
    """Bidirectional DWARF source-line index used by the debugger UI."""

    def __init__(
        self, locations: list[SourceLocation] | None = None,
        definitions: list[SourceDefinition] | None = None,
    ) -> None:
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
        self.definitions = sorted(
            set(definitions or []),
            key=lambda item: (item.name, _path_key(item.path), item.line, item.kind, item.scope),
        )
        self.source_definitions = [item.to_json() for item in self.definitions]
        for item in self.definitions:
            self._paths_by_key.setdefault(_path_key(item.path), item.path)

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
    *, context: ElfLoadContext | None = None,
) -> DebugInfoIndex:

    locations: list[SourceLocation] = []
    definitions: list[SourceDefinition] = []
    total = 0
    with (nullcontext(context) if context is not None else ElfLoadContext(path)) as loaded:
        elf = loaded.elf
        if not elf.has_dwarf_info():
            return DebugInfoIndex()
        dwarf_info = loaded.dwarf_info
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
            entries = line_program.get_entries()
            for die_index, die in enumerate(compile_unit.iter_DIEs()):
                if progress is not None and die_index % 2048 == 0:
                    progress("source", unit_index, total)
                try:
                    definition = _definition_from_die(die, line_program, compile_dir, dwarf_info)
                except (AttributeError, KeyError, TypeError, ValueError):
                    # A malformed declaration must not discard usable line info.
                    continue
                if definition is not None:
                    definitions.append(definition)
            for entry in entries:
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
    result = DebugInfoIndex(locations, definitions)
    if progress is not None:
        progress("source", total, total)
    return result


_DEFINITION_KINDS = {
    "DW_TAG_subprogram": "function",
    "DW_TAG_variable": "variable",
    "DW_TAG_formal_parameter": "parameter",
    "DW_TAG_member": "member",
}


def _inherited_attribute(die, name: str, seen: set[int] | None = None):
    """Concrete C++/inlined DIEs can store their names and sites on another DIE."""
    seen = set() if seen is None else seen
    if id(die) in seen:
        return None
    seen.add(id(die))
    if name in die.attributes:
        return die.attributes[name], die
    for reference in ("DW_AT_specification", "DW_AT_abstract_origin"):
        if reference in die.attributes:
            try:
                origin = die.get_DIE_from_attribute(reference)
                if origin is not None:
                    result = _inherited_attribute(origin, name, seen)
                    if result is not None:
                        return result
            except (KeyError, ValueError):
                continue
    return None


def _definition_from_die(die, line_program, compile_dir: str, dwarf_info=None) -> SourceDefinition | None:
    kind = _DEFINITION_KINDS.get(die.tag)
    if kind is None:
        return None
    name_attribute = _inherited_attribute(die, "DW_AT_name")
    line_attribute = _inherited_attribute(die, "DW_AT_decl_line")
    file_attribute = _inherited_attribute(die, "DW_AT_decl_file")
    if name_attribute is None or line_attribute is None or file_attribute is None:
        return None
    name = _decode(name_attribute[0])
    line = int(line_attribute[0].value)
    file_owner = file_attribute[1]
    if dwarf_info is not None and file_owner.cu is not die.cu:
        line_program = dwarf_info.line_program_for_CU(file_owner.cu)
        if line_program is None:
            return None
        compile_dir = _decode(file_owner.cu.get_top_DIE().attributes.get("DW_AT_comp_dir"))
    path = _source_path(line_program, int(file_attribute[0].value), compile_dir)
    if not name or line <= 0 or not path:
        return None
    scope = []
    is_local = False
    parent = name_attribute[1].get_parent()
    visited = set()
    while parent is not None and id(parent) not in visited:
        visited.add(id(parent))
        if parent.tag in {"DW_TAG_subprogram", "DW_TAG_lexical_block", "DW_TAG_inlined_subroutine"}:
            is_local = True
        if parent.tag in {
            "DW_TAG_subprogram", "DW_TAG_namespace", "DW_TAG_structure_type",
            "DW_TAG_class_type", "DW_TAG_union_type",
        }:
            parent_name = _inherited_attribute(parent, "DW_AT_name")
            if parent_name is not None:
                scope.append(_decode(parent_name[0]))
        parent = parent.get_parent()
    return SourceDefinition(
        name=name, path=path, line=line, kind=kind, scope="::".join(reversed(scope)),
        is_declaration=bool(getattr(die.attributes.get("DW_AT_declaration"), "value", False)),
        is_local=is_local,
    )


def _source_path(line_program, file_index: int, compile_dir: str) -> str:
    file_entries = line_program.header.get("file_entry", [])
    version = line_program.header.get("version", 4)
    index = file_index if version >= 5 else file_index - 1
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
    directory_index = int(getattr(entry, "dir_index", 0) or 0)
    if version < 5:
        directory_index -= 1
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
