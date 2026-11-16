"""Compile the firmware's DWARF into small, file-independent kernel layouts."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .dwarf_support import static_expression


@dataclass
class CType:
    name: str = ""
    kind: str = "scalar"
    size: int = 0
    fields: dict[str, tuple[int, "CType"]] = field(default_factory=dict)
    target: "CType | None" = None
    count: int = 0

    def member(self, path: str) -> tuple[int, "CType"] | None:
        offset, node = 0, self
        for part in path.split('.'):
            found = node.fields.get(part)
            if found is None:
                return None
            delta, node = found
            offset += delta
        return offset, node


@dataclass
class CVariable:
    name: str
    address: int
    type: CType
    source: str = ""


@dataclass
class FreeRtosLayout:
    machine: str = "EM_ARM"
    types: dict[str, CType] = field(default_factory=dict)
    variables: dict[str, CVariable] = field(default_factory=dict)
    ranges: list[tuple[int, int]] = field(default_factory=list)
    pointer_size: int = 4
    byteorder: str = "little"
    problem: str = ""

    def type(self, *names: str) -> CType | None:
        return next((self.types[n] for n in names if n in self.types and self.types[n].fields), None)

    @classmethod
    def from_context(cls, context: Any, check=None) -> "FreeRtosLayout":
        result = cls(machine=context.elf['e_machine'], pointer_size=context.elf.elfclass // 8,
                     byteorder="little" if context.elf.little_endian else "big")
        for section in context.elf.iter_sections():
            start, size = int(section['sh_addr']), int(section['sh_size'])
            if start and size and section['sh_flags'] & 2:
                result.ranges.append((start, start + size))
        if not context.elf.has_dwarf_info():
            result.problem = "固件没有 DWARF 类型信息，请使用包含调试信息的 ELF / AXF。"
            return result
        cache: dict[int, CType] = {}
        named: dict[str, Any] = {}
        variables = []
        dwarf = context.dwarf_info
        from elftools.dwarf.dwarf_expr import DWARFExprParser
        for cu in dwarf.iter_CUs():
            parser = DWARFExprParser(cu.structs)
            if check:
                check()
            source = _name(cu.get_top_DIE())
            for die in cu.iter_DIEs():
                name = _name(die)
                if die.tag in {"DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_typedef"} and name:
                    if (name not in named or "DW_AT_byte_size" in die.attributes
                            or "DW_AT_type" in die.attributes):
                        named[name] = die
                if die.tag == "DW_TAG_variable" and name:
                    location = die.attributes.get("DW_AT_location")
                    address = static_expression(location, parser)
                    if address is not None:
                        variables.append((die, address, source))

        def build(die, depth=0) -> CType:
            if die is None or depth > 64:
                return CType()
            if die.offset in cache:
                return cache[die.offset]
            name, tag = _name(die), die.tag
            if tag in {"DW_TAG_typedef", "DW_TAG_const_type", "DW_TAG_volatile_type",
                       "DW_TAG_restrict_type", "DW_TAG_atomic_type"}:
                target = build(_target(die), depth + 1)
                cache[die.offset] = target
                return target
            if (tag in {"DW_TAG_structure_type", "DW_TAG_union_type"} and name in named
                    and named[name].offset != die.offset
                    and "DW_AT_byte_size" in named[name].attributes):
                target = build(named[name], depth + 1)
                cache[die.offset] = target
                return target
            node = CType(name=name, size=_attr(die, "DW_AT_byte_size", 0))
            cache[die.offset] = node
            if tag == "DW_TAG_pointer_type":
                node.kind, node.size = "pointer", node.size or result.pointer_size
                node.target = build(_target(die), depth + 1)
            elif tag == "DW_TAG_array_type":
                node.kind, node.count = "array", 1
                node.target = build(_target(die), depth + 1)
                for child in die.iter_children():
                    if child.tag == "DW_TAG_subrange_type":
                        count = _attr(child, "DW_AT_count", None)
                        if count is None:
                            upper = _attr(child, "DW_AT_upper_bound", None)
                            count = 0 if upper is None else upper - _attr(child, "DW_AT_lower_bound", 0) + 1
                        node.count *= max(0, min(int(count), 1_000_000))
                node.size = node.size or node.count * node.target.size
            elif tag in {"DW_TAG_structure_type", "DW_TAG_union_type"}:
                node.kind = "record"
                for child in die.iter_children():
                    if child.tag != "DW_TAG_member" or "DW_AT_bit_size" in child.attributes:
                        continue
                    offset = _attr(child, "DW_AT_data_member_location", 0)
                    if not isinstance(offset, int):
                        offset = static_expression(child.attributes.get("DW_AT_data_member_location"),
                                                   DWARFExprParser(child.cu.structs), member=True)
                    if offset is None:
                        continue
                    node.fields[_name(child)] = (offset, build(_target(child), depth + 1))
            return node

        wanted = {"TCB_t", "tskTaskControlBlock", "List_t", "xLIST", "ListItem_t", "xLIST_ITEM",
                  "Queue_t", "QueueDefinition", "EventGroup_t", "EventGroupDef_t", "StreamBuffer_t",
                  "StreamBufferDef_t", "Timer_t", "tmrTimerControl", "BlockLink_t", "A_BLOCK_LINK"}
        for name in wanted:
            if name in named:
                result.types[name] = build(named[name])
        for die, address, source in variables:
            name = _name(die)
            if not address:
                continue
            typ = build(_target(die))
            # A matching source wins when common static names exist in user code.
            old = result.variables.get(name)
            kernel_source = any(s in source.replace('\\', '/') for s in ('tasks.c', 'queue.c', 'timers.c', 'heap_'))
            if old is None or kernel_source:
                result.variables[name] = CVariable(name, address, typ, source)
        if not result.type("TCB_t", "tskTaskControlBlock"):
            result.problem = "未识别 FreeRTOS TCB 类型；请加载匹配固件并保留内核调试信息。"
        return result


def _name(die) -> str:
    value = _attr(die, "DW_AT_name", b"")
    return value.decode('utf-8', 'replace') if isinstance(value, bytes) else str(value)


def _attr(die, name, default, depth=0):
    if depth > 8:
        return default
    attr = die.attributes.get(name)
    if attr is not None:
        return attr.value
    for reference in ('DW_AT_specification', 'DW_AT_abstract_origin'):
        if reference in die.attributes:
            try:
                return _attr(die.get_DIE_from_attribute(reference), name, default, depth + 1)
            except (KeyError, ValueError):
                continue
    return default


def _target(die, depth=0):
    if depth > 8:
        return None
    if "DW_AT_type" not in die.attributes:
        for reference in ('DW_AT_specification', 'DW_AT_abstract_origin'):
            if reference in die.attributes:
                try:
                    return _target(die.get_DIE_from_attribute(reference), depth + 1)
                except (KeyError, ValueError):
                    continue
        return None
    try:
        return die.get_DIE_from_attribute("DW_AT_type")
    except (KeyError, ValueError):
        return None
