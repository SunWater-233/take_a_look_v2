from __future__ import annotations

from collections.abc import Callable
from contextlib import nullcontext
from dataclasses import dataclass
from math import prod
from pathlib import Path

from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.services.dwarf_support import inherited_attribute, static_expression
from take_a_look_backend.services.elf_context import ElfLoadContext


VARIABLE_SECTIONS = {".data", ".bss", ".rodata", ".sdata", ".sbss", ".noinit"}
SymbolLoadProgress = Callable[[str, int, int], None]


@dataclass(frozen=True)
class SymbolCandidate:
    name: str
    kind: str
    address: int
    size: int
    section: str


@dataclass(frozen=True)
class DwarfVariableInfo:
    source_file: str = "未知来源"
    data_type: str = ""
    byte_size: int = 0
    is_pointer: bool = False
    members: tuple[DwarfMemberInfo, ...] = ()
    name: str = ""
    encoding: str = ""
    diagnostic: str = ""


@dataclass(frozen=True)
class DwarfMemberInfo:
    name: str
    address_offset: int
    data_type: str
    byte_size: int
    is_pointer: bool = False
    encoding: str = ""


def load_symbols_from_elf(path: Path, progress: SymbolLoadProgress | None = None,
                          *, context: ElfLoadContext | None = None) -> list[SymbolInfo]:

    symbols: dict[tuple[str, int], SymbolInfo] = {}
    with (nullcontext(context) if context is not None else ElfLoadContext(path)) as loaded:
        elf = loaded.elf
        _emit_progress(progress, "debug", 0, 0)
        debug_by_name, debug_by_addr = variable_debug_info_from_dwarf(elf, progress=progress, context=loaded)
        _emit_progress(progress, "scan", 0, 0)
        candidates = symbol_candidates_from_elf(elf)
        resolved_candidates = [
            (candidate, _match_variable(candidate, debug_by_name, debug_by_addr))
            for candidate in candidates
        ]
        total = sum(1 + len(debug_info.members) for _candidate, debug_info in resolved_candidates)
        _emit_progress(progress, "variables", 0, total)

        current = 0
        last_emitted = 0

        def emit_variable_progress_if_needed() -> None:
            nonlocal last_emitted
            if current == total or current - last_emitted >= 100:
                _emit_progress(progress, "variables", current, total)
                last_emitted = current

        for candidate, debug_info in resolved_candidates:
            source_file = debug_info.source_file or "未知来源"
            data_type = debug_info.data_type or candidate.kind
            symbol_size = candidate.size or debug_info.byte_size
            symbols[(candidate.name, candidate.address)] = SymbolInfo(
                name=candidate.name,
                address=candidate.address,
                size=symbol_size,
                kind=data_type,
                section=candidate.section,
                source_file=source_file,
                pointer=debug_info.is_pointer,
                encoding=debug_info.encoding,
                byte_order="little" if elf.little_endian else "big",
                diagnostic=debug_info.diagnostic or _type_diagnostic(debug_info.encoding, symbol_size),
            )
            current += 1
            emit_variable_progress_if_needed()
            for member in debug_info.members:
                member_name = (candidate.name + member.name[len(debug_info.name):]
                               if debug_info.name else member.name)
                symbols[(member_name, candidate.address + member.address_offset)] = SymbolInfo(
                    name=member_name,
                    address=candidate.address + member.address_offset,
                    size=member.byte_size,
                    kind=member.data_type,
                    section=candidate.section,
                    source_file=source_file,
                    pointer=member.is_pointer,
                    encoding=member.encoding,
                    byte_order="little" if elf.little_endian else "big",
                    diagnostic=_type_diagnostic(member.encoding, member.byte_size),
                )
                current += 1
                emit_variable_progress_if_needed()

    result = sorted(symbols.values(), key=lambda item: (item.source_file, item.name, item.address))
    return result


def symbol_candidates_from_elf(elf_file) -> list[SymbolCandidate]:
    candidates: list[SymbolCandidate] = []
    for table in elf_file.iter_sections():
        if table.header["sh_type"] not in {"SHT_SYMTAB", "SHT_DYNSYM"}:
            continue

        for raw_symbol in table.iter_symbols():
            name = raw_symbol.name.strip()
            if not name or name.startswith("$") or name.startswith("."):
                continue

            entry = raw_symbol.entry
            kind = entry["st_info"]["type"]
            if kind in {"STT_FUNC", "STT_FILE", "STT_SECTION"}:
                continue

            address = int(entry["st_value"])
            size = int(entry["st_size"])
            section = section_name_for_symbol(elf_file, entry["st_shndx"])
            if kind != "STT_OBJECT" and section not in VARIABLE_SECTIONS:
                continue

            candidates.append(
                SymbolCandidate(
                    name=name,
                    kind=kind,
                    address=address,
                    size=size,
                    section=section,
                )
            )
    return candidates


def _emit_progress(progress: SymbolLoadProgress | None, phase: str, current: int, total: int) -> None:
    if progress is not None:
        progress(phase, current, total)


def section_name_for_symbol(elf_file, section_index) -> str:
    if isinstance(section_index, int):
        section = elf_file.get_section(section_index)
        return section.name if section is not None else "<unknown>"
    return str(section_index)


def variable_debug_info_from_dwarf(
    elf_file,
    progress: SymbolLoadProgress | None = None,
    *, context: ElfLoadContext | None = None,
) -> tuple[dict[str, DwarfVariableInfo], dict[tuple[str, int], DwarfVariableInfo]]:
    if not elf_file.has_dwarf_info():
        return {}, {}

    from elftools.dwarf.dwarf_expr import DWARFExprParser

    by_name: dict[str, DwarfVariableInfo] = {}
    by_addr: dict[tuple[str, int], DwarfVariableInfo] = {}
    named_records: dict[str, list[tuple[DwarfVariableInfo, bool]]] = {}
    try:
        dwarf_info = context.dwarf_info if context is not None else elf_file.get_dwarf_info()
    except Exception:
        return by_name, by_addr

    compile_units = list(dwarf_info.iter_CUs())
    total_units = len(compile_units)
    _emit_progress(progress, "debug", 0, total_units)

    type_cache = {}
    for unit_index, compile_unit in enumerate(compile_units, start=1):
        try:
            line_program = dwarf_info.line_program_for_CU(compile_unit)
        except Exception:
            line_program = None

        top_die = compile_unit.get_top_DIE()
        compile_dir = _decode_dwarf_value(top_die.attributes.get("DW_AT_comp_dir", None))
        expr_parser = DWARFExprParser(compile_unit.structs)

        for die in compile_unit.iter_DIEs():
            if die.tag != "DW_TAG_variable":
                continue
            name_attribute = inherited_attribute(die, "DW_AT_name")
            name = _decode_dwarf_value(name_attribute[0]) if name_attribute else ""
            if not name:
                continue

            source_file = _source_file_for_die(die, line_program, compile_dir)
            type_die = _type_die_for_die(die)
            type_key = (getattr(compile_unit, "cu_offset", id(compile_unit)),
                        getattr(type_die, "offset", id(type_die)))
            metadata = type_cache.get(type_key)
            if metadata is None:
                data_type, byte_size = _type_info_for_die(die)
                metadata = (data_type, byte_size, _is_pointer_type_die(type_die), _type_encoding(type_die),
                            tuple(_expand_type_members(type_die, "@", 0, expr_parser, set())))
                type_cache[type_key] = metadata
            data_type, byte_size, pointer, encoding, members = metadata
            info = DwarfVariableInfo(
                source_file=source_file or "未知来源", data_type=data_type,
                byte_size=byte_size, is_pointer=pointer,
                name=name, encoding=encoding,
                members=tuple(DwarfMemberInfo(
                    name=name + member.name[1:], address_offset=member.address_offset,
                    data_type=member.data_type, byte_size=member.byte_size,
                    is_pointer=member.is_pointer, encoding=member.encoding) for member in members),
            )
            location = inherited_attribute(die, "DW_AT_location")
            attribute = location[0] if location else None
            address = _address_from_location(attribute, expr_parser)
            aliases = {name}
            scope = _variable_scope(die)
            if scope:
                aliases.update({".".join([*scope, name]), "::".join([*scope, name])})
            for key in ("DW_AT_linkage_name", "DW_AT_MIPS_linkage_name"):
                linkage = inherited_attribute(die, key)
                if linkage:
                    aliases.add(_decode_dwarf_value(linkage[0]))
            for alias in aliases:
                if address is not None:
                    key = (alias, address)
                    by_addr[key] = _merge_debug_info(by_addr.get(key), info)
                if _is_global_variable(die):
                    fallback_allowed = attribute is None and inherited_attribute(die, "DW_AT_const_value") is None
                    named_records.setdefault(alias, []).append((info, fallback_allowed))
        _emit_progress(progress, "debug", unit_index, total_units)

    for name, records in named_records.items():
        if all(allowed for _, allowed in records):
            for info, _ in records:
                by_name[name] = _merge_debug_info(by_name.get(name), info)
        else:
            by_name[name] = DwarfVariableInfo(diagnostic="无法将符号与固定内存位置的调试信息唯一匹配。", encoding="unsupported")
    return by_name, by_addr


def _merge_debug_info(previous, info):
    if previous is None or not previous.data_type and not previous.diagnostic:
        return info
    if not info.data_type:
        return previous
    fields = ("data_type", "byte_size", "is_pointer", "encoding", "members")
    if any(getattr(previous, field) != getattr(info, field) for field in fields):
        return DwarfVariableInfo(diagnostic="变量存在相互冲突的调试类型信息。", encoding="unsupported")
    return previous


def _match_variable(candidate, by_name, by_addr):
    info = by_addr.get((candidate.name, candidate.address))
    if info is None:
        # GCC names function-local statics as name.N in the ELF symbol table.
        base, separator, suffix = candidate.name.rpartition(".")
        if separator and suffix.isdigit():
            info = by_addr.get((base, candidate.address))
    info = info or by_name.get(candidate.name) or DwarfVariableInfo(
        diagnostic="未找到可匹配的变量类型信息。", encoding="unsupported")
    if candidate.size and info.byte_size and candidate.size != info.byte_size:
        return DwarfVariableInfo(diagnostic="ELF 符号大小与 DWARF 类型大小不一致。", encoding="unsupported")
    return info


def _is_global_variable(die):
    seen = set()
    current = die
    while current is not None and id(current) not in seen and len(seen) < 64:
        seen.add(id(current))
        if current.tag == "DW_TAG_compile_unit":
            return True
        if current.tag in {"DW_TAG_subprogram", "DW_TAG_lexical_block", "DW_TAG_inlined_subroutine"}:
            return False
        current = current.get_parent()
    return False


def _variable_scope(die):
    names = []
    seen = set()
    current = die.get_parent()
    while current is not None and id(current) not in seen and len(seen) < 64:
        seen.add(id(current))
        if current.tag == "DW_TAG_compile_unit":
            break
        if current.tag in {"DW_TAG_subprogram", "DW_TAG_namespace", "DW_TAG_class_type", "DW_TAG_structure_type"}:
            attribute = inherited_attribute(current, "DW_AT_name")
            if attribute:
                names.append(_decode_dwarf_value(attribute[0]))
        current = current.get_parent()
    return list(reversed(names))


def _type_diagnostic(encoding: str, size: int) -> str:
    widths = {"float": {2, 4, 8}, "signed": {1, 2, 4, 8},
              "unsigned": {1, 2, 4, 8}, "bool": {1, 2, 4, 8}}
    if encoding == "unsupported" or encoding in widths and size not in widths[encoding]:
        return "暂不支持该类型或字节宽度的数值解码。"
    return ""



def symbol_hierarchy(symbol: SymbolInfo) -> list[str]:
    source = symbol.source_file or "未知来源"
    if source == "未知来源":
        return [source, symbol.section or "global", *_split_symbol_name(symbol.name)]

    file_parts = [part for part in source.replace("\\", "/").split("/") if part]
    return file_parts + _split_symbol_name(symbol.name)


def _source_file_for_die(die, line_program, compile_dir: str) -> str:
    declaration = inherited_attribute(die, "DW_AT_decl_file")
    if declaration is None:
        return compile_dir or "未知来源"
    attribute, owner = declaration
    if owner is not die and owner.cu is not die.cu:
        line_program = owner.cu.dwarfinfo.line_program_for_CU(owner.cu)
        compile_dir = _decode_dwarf_value(owner.cu.get_top_DIE().attributes.get("DW_AT_comp_dir"))
    if line_program is None:
        return compile_dir or "未知来源"
    # Keep the established source-path spelling for project/watch rebinding.
    # DWARF 5 indexes both file and directory tables from zero.
    version = line_program.header.get("version", 4)
    index = int(attribute.value) - (0 if version >= 5 else 1)
    files = line_program.header.get("file_entry", [])
    if not 0 <= index < len(files):
        return compile_dir or "未知来源"
    entry = files[index]
    directory_index = int(getattr(entry, "dir_index", 0)) - (0 if version >= 5 else 1)
    directories = line_program.header.get("include_directory", [])
    directory = (_decode_dwarf_value(directories[directory_index])
                 if 0 <= directory_index < len(directories) else compile_dir)
    return _join_source_path(directory, _decode_dwarf_value(entry.name))


def _address_from_location(attribute, expr_parser) -> int | None:
    return static_expression(attribute, expr_parser)


def _expand_type_members(type_die, base_name: str, base_offset: int, expr_parser, seen: set[int]) -> list[DwarfMemberInfo]:
    if type_die is None:
        return []

    resolved = _resolve_type_die(type_die, set())
    if resolved is None:
        return []

    offset = int(getattr(resolved, "offset", 0))
    if offset in seen:
        return []
    next_seen = seen | {offset}

    if resolved.tag in {"DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_class_type"}:
        return _expand_record_members(resolved, base_name, base_offset, expr_parser, next_seen)
    if resolved.tag == "DW_TAG_array_type":
        return _expand_array_members(resolved, base_name, base_offset, expr_parser, next_seen)
    return []


def _expand_record_members(type_die, base_name: str, base_offset: int, expr_parser, seen: set[int]) -> list[DwarfMemberInfo]:
    members: list[DwarfMemberInfo] = []
    for child in type_die.iter_children():
        if child.tag != "DW_TAG_member":
            continue
        if _is_unsupported_bitfield(child):
            continue

        member_offset = _member_offset_for_die(child, expr_parser)
        if member_offset is None:
            continue

        member_type = _type_die_for_die(child)
        member_name = _decode_dwarf_value(child.attributes.get("DW_AT_name", None))
        member_path = f"{base_name}.{member_name}" if member_name else base_name
        if not member_path:
            continue

        data_type, byte_size = _type_info_for_die(child)
        if member_name:
            members.append(
                DwarfMemberInfo(
                    name=member_path,
                    address_offset=base_offset + member_offset,
                    data_type=data_type,
                    byte_size=byte_size,
                    is_pointer=_is_pointer_type_die(member_type),
                    encoding=_type_encoding(member_type),
                )
            )

        members.extend(
            _expand_type_members(
                member_type,
                member_path,
                base_offset + member_offset,
                expr_parser,
                seen,
            )
        )
    return members


def _expand_array_members(type_die, base_name: str, base_offset: int, expr_parser, seen: set[int]) -> list[DwarfMemberInfo]:
    leaf_type, dimensions = _array_leaf_and_dimensions(type_die, set())
    if leaf_type is None or not dimensions or any(count <= 0 for count in dimensions):
        return []

    leaf_name, leaf_size = _describe_type_die(leaf_type, set())
    strides = _array_dimension_strides(type_die, dimensions, leaf_size)
    if not strides:
        return []

    members: list[DwarfMemberInfo] = []
    _append_array_members(
        members,
        base_name,
        base_offset,
        leaf_type,
        leaf_name,
        dimensions,
        strides,
        expr_parser,
        seen,
    )
    return members


def _append_array_members(
    members: list[DwarfMemberInfo],
    base_name: str,
    base_offset: int,
    leaf_type,
    leaf_name: str,
    dimensions: list[int],
    strides: list[int],
    expr_parser,
    seen: set[int],
) -> None:
    count = dimensions[0]
    stride = strides[0]
    remaining_dimensions = dimensions[1:]
    remaining_strides = strides[1:]

    for index in range(count):
        item_name = f"{base_name}[{index}]"
        item_offset = base_offset + index * stride
        item_type = f"{leaf_name or 'unknown'}[]" if remaining_dimensions else (leaf_name or "unknown")
        members.append(
            DwarfMemberInfo(
                name=item_name,
                address_offset=item_offset,
                data_type=item_type,
                byte_size=stride,
                is_pointer=_is_pointer_type_die(leaf_type),
                encoding="bytes" if remaining_dimensions else _type_encoding(leaf_type),
            )
        )

        if remaining_dimensions:
            _append_array_members(
                members,
                item_name,
                item_offset,
                leaf_type,
                leaf_name,
                remaining_dimensions,
                remaining_strides,
                expr_parser,
                seen,
            )
            continue

        members.extend(_expand_type_members(leaf_type, item_name, item_offset, expr_parser, seen))


def _array_leaf_and_dimensions(type_die, seen: set[int]) -> tuple[object | None, list[int]]:
    resolved = _resolve_type_die(type_die, seen)
    if resolved is None or resolved.tag != "DW_TAG_array_type":
        return type_die, []

    dimensions = [
        count
        for child in resolved.iter_children()
        if child.tag == "DW_TAG_subrange_type"
        for count in [_subrange_count(child)]
        if count is not None
    ]
    nested = _type_die_for_die(resolved)
    if nested is None:
        return None, dimensions

    nested_resolved = _resolve_type_die(nested, set())
    if nested_resolved is not None and nested_resolved.tag == "DW_TAG_array_type":
        leaf_type, nested_dimensions = _array_leaf_and_dimensions(nested_resolved, seen)
        return leaf_type, dimensions + nested_dimensions
    return nested, dimensions


def _array_dimension_strides(type_die, dimensions: list[int], leaf_size: int) -> list[int]:
    if not dimensions:
        return []
    if leaf_size > 0:
        return [leaf_size * prod(dimensions[index + 1 :]) for index in range(len(dimensions))]

    total_size = _byte_size(type_die)
    if total_size <= 0:
        return []

    strides: list[int] = []
    current = total_size
    for count in dimensions:
        if count <= 0 or current % count != 0:
            return []
        current //= count
        strides.append(current)
    return strides


def _subrange_count(die) -> int | None:
    count_attribute = die.attributes.get("DW_AT_count", None)
    if count_attribute is not None:
        return _int_attribute_value(count_attribute)

    upper_bound = _int_attribute_value(die.attributes.get("DW_AT_upper_bound", None))
    if upper_bound is None:
        return None
    lower_bound = _int_attribute_value(die.attributes.get("DW_AT_lower_bound", None)) or 0
    return max(upper_bound - lower_bound + 1, 0)


def _member_offset_for_die(die, expr_parser) -> int | None:
    attribute = die.attributes.get("DW_AT_data_member_location", None)
    if attribute is None:
        return 0

    value = attribute.value
    if isinstance(value, int):
        return int(value)
    return static_expression(attribute, expr_parser, member=True)


def _type_die_for_die(die):
    try:
        return die.get_DIE_from_attribute("DW_AT_type")
    except Exception:
        inherited = inherited_attribute(die, "DW_AT_type")
        if inherited is not None:
            try:
                return inherited[1].get_DIE_from_attribute("DW_AT_type")
            except (KeyError, ValueError):
                pass
        return None


def _resolve_type_die(type_die, seen: set[int]):
    current = type_die
    while current is not None and current.tag in {
        "DW_TAG_typedef",
        "DW_TAG_const_type",
        "DW_TAG_volatile_type",
        "DW_TAG_restrict_type",
        "DW_TAG_atomic_type",
    }:
        offset = int(getattr(current, "offset", 0))
        if offset in seen:
            break
        seen.add(offset)
        current = _type_die_for_die(current)
    return current


def _is_pointer_type_die(type_die) -> bool:
    resolved = _resolve_type_die(type_die, set())
    return resolved is not None and resolved.tag == "DW_TAG_pointer_type"


def _type_encoding(type_die, seen=None) -> str:
    resolved = _resolve_type_die(type_die, set())
    if resolved is None:
        return "unsupported"
    seen = set() if seen is None else seen
    if id(resolved) in seen:
        return "unsupported"
    seen.add(id(resolved))
    if resolved.tag == "DW_TAG_pointer_type":
        return "unsigned"
    if resolved.tag in {"DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_class_type", "DW_TAG_array_type"}:
        return "bytes"
    if resolved.tag == "DW_TAG_enumeration_type":
        target = _type_die_for_die(resolved)
        if target is not None:
            return _type_encoding(target, seen)
    if resolved.tag in {"DW_TAG_base_type", "DW_TAG_enumeration_type"}:
        encoding = _int_attribute_value(resolved.attributes.get("DW_AT_encoding"))
        return {1: "unsigned", 2: "bool", 4: "float", 5: "signed", 6: "signed",
                7: "unsigned", 8: "unsigned"}.get(encoding, "unsupported")
    return "unsupported"


def _is_unsupported_bitfield(die) -> bool:
    bit_size = _int_attribute_value(die.attributes.get("DW_AT_bit_size", None))
    return bit_size is not None


def _int_attribute_value(attribute) -> int | None:
    if attribute is None:
        return None
    try:
        return int(attribute.value)
    except Exception:
        return None


def _type_info_for_die(die) -> tuple[str, int]:
    type_die = _type_die_for_die(die)
    if type_die is None:
        return "", 0
    return _describe_type_die(type_die, set())


def _describe_type_die(type_die, seen: set[int]) -> tuple[str, int]:
    offset = int(getattr(type_die, "offset", 0))
    if offset in seen:
        return "", _byte_size(type_die)
    seen.add(offset)

    tag = type_die.tag
    name = _decode_dwarf_value(type_die.attributes.get("DW_AT_name", None))
    size = _byte_size(type_die)

    if tag == "DW_TAG_base_type":
        return name, size
    if tag == "DW_TAG_typedef":
        if name:
            return name, size or _nested_type_size(type_die, seen)
        return _nested_type(type_die, seen)
    if tag in {"DW_TAG_const_type", "DW_TAG_volatile_type", "DW_TAG_restrict_type", "DW_TAG_atomic_type"}:
        nested_name, nested_size = _nested_type(type_die, seen)
        qualifier = {
            "DW_TAG_const_type": "const",
            "DW_TAG_volatile_type": "volatile",
            "DW_TAG_restrict_type": "restrict",
            "DW_TAG_atomic_type": "_Atomic",
        }[tag]
        return f"{qualifier} {nested_name}".strip(), size or nested_size
    if tag == "DW_TAG_pointer_type":
        nested_name, _nested_size = _nested_type(type_die, seen)
        return f"{nested_name or 'void'}*", size or int(type_die.cu["address_size"])
    if tag == "DW_TAG_array_type":
        nested_name, nested_size = _nested_type(type_die, seen)
        counts = [_subrange_count(child) for child in type_die.iter_children()
                  if child.tag == "DW_TAG_subrange_type"]
        count = prod(counts) if counts and all(value is not None for value in counts) else 0
        return f"{nested_name or 'unknown'}[]", size or nested_size * count
    if tag in {"DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_enumeration_type", "DW_TAG_class_type"}:
        prefix = {
            "DW_TAG_structure_type": "struct",
            "DW_TAG_union_type": "union",
            "DW_TAG_enumeration_type": "enum",
            "DW_TAG_class_type": "class",
        }[tag]
        return f"{prefix} {name}".strip(), size

    if name:
        return name, size
    return _nested_type(type_die, seen)


def _nested_type(type_die, seen: set[int]) -> tuple[str, int]:
    try:
        nested = type_die.get_DIE_from_attribute("DW_AT_type")
    except Exception:
        nested = None
    if nested is None:
        return "", 0
    return _describe_type_die(nested, seen)


def _nested_type_size(type_die, seen: set[int]) -> int:
    _name, size = _nested_type(type_die, seen)
    return size


def _byte_size(type_die) -> int:
    attribute = type_die.attributes.get("DW_AT_byte_size", None)
    if attribute is None:
        return 0
    try:
        return int(attribute.value)
    except Exception:
        return 0


def _decode_dwarf_value(attribute_or_value) -> str:
    if attribute_or_value is None:
        return ""
    value = getattr(attribute_or_value, "value", attribute_or_value)
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _join_source_path(directory: str, file_name: str) -> str:
    file_name = file_name.replace("\\", "/")
    directory = directory.replace("\\", "/").rstrip("/")
    if not file_name:
        return directory or "未知来源"
    if file_name.startswith("/") or (len(file_name) > 2 and file_name[1] == ":"):
        return file_name
    if directory:
        return f"{directory}/{file_name}"
    return file_name


def _split_symbol_name(name: str) -> list[str]:
    parts: list[str] = []
    for chunk in name.split("."):
        if not chunk:
            continue

        token = []
        index = 0
        while index < len(chunk):
            if chunk[index] != "[":
                token.append(chunk[index])
                index += 1
                continue

            if token:
                parts.append("".join(token))
                token = []

            end = chunk.find("]", index)
            if end < 0:
                token.append(chunk[index:])
                break
            parts.append(chunk[index : end + 1])
            index = end + 1

        if token:
            parts.append("".join(token))
    return parts or [name]
