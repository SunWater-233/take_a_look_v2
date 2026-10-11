from unittest.mock import Mock, patch

from take_a_look_backend.service import BackendService
from take_a_look_backend.protocol import RpcMethod
from take_a_look_backend.services.symbols import SymbolCandidate, DwarfMemberInfo, variable_debug_info_from_dwarf


def test_symbol_transaction_shares_the_open_elf_and_dwarf_graph(tmp_path):
    path = tmp_path / "fixture.elf"
    path.write_bytes(b"fixture parsed by injected ELF adapter")
    dwarf = Mock()
    dwarf.iter_CUs.return_value = []
    elf = Mock()
    elf.has_dwarf_info.return_value = True
    elf.get_dwarf_info.return_value = dwarf
    with patch("elftools.elf.elffile.ELFFile", return_value=elf) as factory, patch(
        "take_a_look_backend.services.symbols.symbol_candidates_from_elf",
        return_value=[SymbolCandidate("counter", "object", 0x20000000, 4, ".data")]
    ):
        service = BackendService(lambda *_: None, recording_directory=tmp_path / "records")
        try:
            result = service.handle(RpcMethod.LOAD_SYMBOLS, {"path": str(path)})
            assert len(result["state"]["symbols"]) == 1
            assert factory.call_count == 1
            assert elf.get_dwarf_info.call_count == 1
        finally:
            service.close()


def test_cached_type_members_keep_each_variable_name():
    type_die = Mock(offset=42)
    variables = []
    for name in (b"first", b"second"):
        die = Mock(tag="DW_TAG_variable")
        die.attributes = {"DW_AT_name": Mock(value=name)}
        variables.append(die)
    unit = Mock(cu_offset=0)
    unit.get_top_DIE.return_value = Mock(attributes={})
    unit.iter_DIEs.return_value = variables
    dwarf = Mock()
    dwarf.iter_CUs.return_value = [unit]
    dwarf.line_program_for_CU.return_value = None
    elf = Mock()
    elf.has_dwarf_info.return_value = True
    elf.get_dwarf_info.return_value = dwarf
    with patch("elftools.dwarf.dwarf_expr.DWARFExprParser"), patch(
        "take_a_look_backend.services.symbols._type_die_for_die", return_value=type_die
    ), patch("take_a_look_backend.services.symbols._type_info_for_die", return_value=("record", 8)), patch(
        "take_a_look_backend.services.symbols._is_pointer_type_die", return_value=False
    ), patch("take_a_look_backend.services.symbols._expand_type_members",
             return_value=[DwarfMemberInfo("@.child", 4, "float", 4)]) as expand:
        by_name, _ = variable_debug_info_from_dwarf(elf)
    assert expand.call_count == 1
    assert by_name["first"].members[0].name == "first.child"
    assert by_name["second"].members[0].name == "second.child"
    assert by_name["second"].members[0].address_offset == 4
