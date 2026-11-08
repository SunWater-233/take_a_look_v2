from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest
from elftools.dwarf.dwarf_expr import DWARFExprParser
from elftools.dwarf.structs import DWARFStructs

from take_a_look_backend.backends.typed_memory import TypedMemoryBackend
from take_a_look_backend.services.symbols import (
    DwarfMemberInfo,
    SymbolCandidate,
    _address_from_location,
    _member_offset_for_die,
    load_symbols_from_elf,
)


BASE_ADDRESS = 0x20000000
ADDRESS_EXPR = b"\x03\x00\x00\x00\x20"  # DW_OP_addr 0x20000000


def _structs():
    return DWARFStructs(little_endian=True, dwarf_format=32, address_size=4, dwarf_version=4)


def _attribute(value):
    return SimpleNamespace(value=value)


@pytest.mark.parametrize("suffix, offset", [
    (b"", 0),
    (b"\x23\x04", 4),  # DW_OP_plus_uconst 4 (Arm Compiler global merge)
    (b"\x23\x04\x23\x80\x01", 132),
    (b"\x10\x04\x22", 4),  # constu 4; plus
    (b"\x34\x22", 4),  # lit4; plus
    (b"\x34\x1c", -4),  # lit4; minus
])
def test_static_location_includes_all_constant_offsets(suffix, offset):
    parser = DWARFExprParser(_structs())
    assert _address_from_location(_attribute(ADDRESS_EXPR + suffix), parser) == BASE_ADDRESS + offset


@pytest.mark.parametrize("expression", [
    ADDRESS_EXPR + b"\x06",  # dereference requires target memory
    ADDRESS_EXPR + b"\x9f",  # stack value is a value, not a memory location
    ADDRESS_EXPR + b"\x93\x01",  # piece is only part of the variable
    ADDRESS_EXPR + b"\x50",  # register location
    ADDRESS_EXPR + ADDRESS_EXPR,  # ambiguous stack result
    ADDRESS_EXPR + b"\x23",  # truncated operand
    b"\x23\x04",  # missing base address
    b"",
])
def test_unsupported_location_does_not_return_a_partial_address(expression):
    parser = DWARFExprParser(_structs())
    assert _address_from_location(_attribute(expression), parser) is None


@pytest.mark.parametrize("expression, expected", [
    (b"\x23\x04", 4), (b"\x10\x04\x22", 4), (b"\x34\x22", 4),
    (b"\x34\x35\x22\x22", 9), (b"\x31\x32", None), (b"\x06", None),
])
def test_member_locations_use_stack_arithmetic(expression, expected):
    die = SimpleNamespace(attributes={"DW_AT_data_member_location": _attribute(expression)})
    assert _member_offset_for_die(die, DWARFExprParser(_structs())) == expected


def test_merged_global_preserves_adjacent_bool_type_and_read_write(tmp_path):
    """Reproduce armclang's zero_force / motor base-plus-offset DWARF."""
    bool_type, motor_type = Mock(offset=1), Mock(offset=2)
    variables = []
    for name, expression, type_die in (
        (b"zero_force", ADDRESS_EXPR, bool_type),
        (b"motor", ADDRESS_EXPR + b"\x23\x04", motor_type),
    ):
        die = Mock(tag="DW_TAG_variable", attributes={
            "DW_AT_name": _attribute(name),
            "DW_AT_location": _attribute(list(expression)),
        })
        die.get_DIE_from_attribute.return_value = type_die
        die.get_parent.return_value = Mock(tag="DW_TAG_compile_unit")
        variables.append(die)
    unit = Mock(cu_offset=0, structs=_structs())
    unit.get_top_DIE.return_value = Mock(attributes={})
    unit.iter_DIEs.return_value = variables
    dwarf = Mock()
    dwarf.iter_CUs.return_value = [unit]
    dwarf.line_program_for_CU.return_value = None
    elf = Mock()
    elf.has_dwarf_info.return_value = True
    context = SimpleNamespace(elf=elf, dwarf_info=dwarf)

    with patch("take_a_look_backend.services.symbols._type_info_for_die",
               side_effect=[("_Bool", 1), ("DJIMotor_t", 8)]), patch(
        "take_a_look_backend.services.symbols._is_pointer_type_die", return_value=False
    ), patch("take_a_look_backend.services.symbols._type_encoding", side_effect=["bool", "bytes"]), patch(
        "take_a_look_backend.services.symbols._expand_type_members",
             side_effect=[[], [DwarfMemberInfo("@.id", 0, "uint32_t", 4)]]), patch(
        "take_a_look_backend.services.symbols.symbol_candidates_from_elf", return_value=[
            SymbolCandidate("zero_force", "STT_OBJECT", BASE_ADDRESS, 1, "RW_IRAM1"),
            SymbolCandidate("motor", "STT_OBJECT", BASE_ADDRESS + 4, 8, "RW_IRAM1"),
        ]
    ):
        symbols = load_symbols_from_elf(tmp_path / "merged.axf", context=context)

    by_name = {symbol.name: symbol for symbol in symbols}
    flag = by_name["zero_force"]
    assert (flag.address, flag.size, flag.kind) == (BASE_ADDRESS, 1, "_Bool")
    assert by_name["motor"].kind == "DJIMotor_t"
    assert by_name["motor.id"].address == BASE_ADDRESS + 4
    assert len(symbols) == 3  # no phantom motor members under zero_force's address

    memory = bytearray(b"\x01\xaa\xbb\xcc\x02\x00\x00\x00")
    target = Mock()
    target.read_memory_block8.side_effect = lambda address, size: list(
        memory[address - BASE_ADDRESS:address - BASE_ADDRESS + size])

    def write(address, data):
        memory[address - BASE_ADDRESS:address - BASE_ADDRESS + len(data)] = bytes(data)

    target.write_memory_block8.side_effect = write
    backend = TypedMemoryBackend()
    backend.target = target
    assert backend.read_symbol(flag) is True
    assert backend.write_symbol(flag, "0") is False
    assert backend.write_symbol(flag, "1") is True
    assert backend.read_symbols([flag, by_name["motor.id"]]) == {flag.key: True, by_name["motor.id"].key: 2}
    assert memory[1:] == b"\xaa\xbb\xcc\x02\x00\x00\x00"
