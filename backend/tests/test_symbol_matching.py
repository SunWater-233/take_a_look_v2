from types import SimpleNamespace
from unittest.mock import patch

from elftools.dwarf.structs import DWARFStructs

from take_a_look_backend.services.dwarf_support import inherited_attribute
from take_a_look_backend.services.symbols import SymbolCandidate, load_symbols_from_elf


class Die:
    def __init__(self, tag, offset, values=None, references=None, parent=None):
        self.tag, self.offset, self.parent = tag, offset, parent
        self.attributes = {name: SimpleNamespace(value=value) for name, value in (values or {}).items()}
        self.references = references or {}
        self.attributes.update({name: SimpleNamespace(value=target.offset) for name, target in self.references.items()})

    def get_DIE_from_attribute(self, name):
        return self.references[name]

    def get_parent(self):
        return self.parent

    def iter_children(self):
        return iter(())


def _base_type(name, size, encoding, offset):
    return Die("DW_TAG_base_type", offset, {"DW_AT_name": name.encode(), "DW_AT_byte_size": size,
                                          "DW_AT_encoding": encoding})


def _load(tmp_path, definitions, candidates):
    top = Die("DW_TAG_compile_unit", 0)
    variables = []
    for index, (name, typ, location, local) in enumerate(definitions):
        parent = Die("DW_TAG_subprogram", 200 + index, {"DW_AT_name": b"control"}, parent=top) if local else top
        values = {"DW_AT_name": name.encode()}
        if location is not None:
            values["DW_AT_location"] = location
        variables.append(Die("DW_TAG_variable", 100 + index, values, {"DW_AT_type": typ}, parent))
    unit = SimpleNamespace(cu_offset=0, structs=DWARFStructs(
        little_endian=True, dwarf_format=32, address_size=4, dwarf_version=4),
        get_top_DIE=lambda: top, iter_DIEs=lambda: iter(variables))
    dwarf = SimpleNamespace(iter_CUs=lambda: [unit], line_program_for_CU=lambda _: None)
    elf = SimpleNamespace(has_dwarf_info=lambda: True, little_endian=True)
    context = SimpleNamespace(elf=elf, dwarf_info=dwarf)
    with patch("take_a_look_backend.services.symbols.symbol_candidates_from_elf", return_value=candidates):
        return load_symbols_from_elf(tmp_path / "test.elf", context=context)


ADDRESS = b"\x03\x00\x00\x00\x20"
FLOAT = _base_type("float", 4, 4, 1)
INT = _base_type("int", 4, 5, 2)


def test_same_address_aliases_keep_their_own_types(tmp_path):
    symbols = _load(tmp_path, [("integer", INT, ADDRESS, False), ("real", FLOAT, ADDRESS, False)], [
        SymbolCandidate("integer", "STT_OBJECT", 0x20000000, 4, ".data"),
        SymbolCandidate("real", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert {(symbol.name, symbol.encoding) for symbol in symbols} == {("integer", "signed"), ("real", "float")}


def test_armclang_function_scoped_static_names_keep_their_type(tmp_path):
    symbols = _load(tmp_path, [("gain", FLOAT, ADDRESS, True)], [
        SymbolCandidate("control.gain", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert symbols[0].encoding == "float" and not symbols[0].diagnostic


def test_register_local_does_not_supply_a_global_declarations_type(tmp_path):
    symbols = _load(tmp_path, [("shared", FLOAT, b"\x50", True), ("shared", INT, None, False)], [
        SymbolCandidate("shared", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert symbols[0].encoding == "signed" and not symbols[0].diagnostic


def test_conflicting_definitions_do_not_choose_the_last_type(tmp_path):
    symbols = _load(tmp_path, [("shared", INT, ADDRESS, False), ("shared", FLOAT, ADDRESS, False)], [
        SymbolCandidate("shared", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert symbols[0].diagnostic and not symbols[0].is_writable


def test_unresolved_ambiguous_declarations_do_not_choose_the_first_type(tmp_path):
    symbols = _load(tmp_path, [("shared", INT, None, False), ("shared", FLOAT, None, False)], [
        SymbolCandidate("shared", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert symbols[0].diagnostic and not symbols[0].is_writable


def test_runtime_location_is_not_recovered_through_the_name_fallback(tmp_path):
    symbols = _load(tmp_path, [("shared", FLOAT, ADDRESS + b"\x9f", False)], [
        SymbolCandidate("shared", "STT_OBJECT", 0x20000000, 4, ".data"),
    ])
    assert symbols[0].diagnostic and not symbols[0].is_writable


def test_size_mismatch_disables_typed_access(tmp_path):
    symbols = _load(tmp_path, [("shared", FLOAT, ADDRESS, False)], [
        SymbolCandidate("shared", "STT_OBJECT", 0x20000000, 8, ".data"),
    ])
    assert symbols[0].diagnostic and not symbols[0].is_writable


def test_inherited_attributes_stop_at_cycles():
    first = Die("DW_TAG_variable", 1)
    second = Die("DW_TAG_variable", 2, references={"DW_AT_abstract_origin": first})
    first.references["DW_AT_specification"] = second
    first.attributes["DW_AT_specification"] = SimpleNamespace(value=2)
    assert inherited_attribute(first, "DW_AT_name") is None
