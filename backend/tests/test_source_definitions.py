from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace

import pytest

from take_a_look_backend.services.debug_info import (
    DebugInfoIndex, SourceDefinition, _definition_from_die, _source_path,
    load_debug_info_from_elf,
)
from take_a_look_backend.services.debug_session import DebugSession
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import RpcMethod
from take_a_look_backend.service import BackendService


def attribute(value):
    return SimpleNamespace(value=value)


class Die:
    def __init__(self, tag, parent=None, **attributes):
        self.tag = tag
        self.parent = parent
        self.attributes = {name: attribute(value) for name, value in attributes.items()}
        self.references = {}
        self.cu = None

    def get_parent(self):
        return self.parent

    def get_DIE_from_attribute(self, name):
        return self.references[name]


def line_program(version=4):
    return SimpleNamespace(header={
        "version": version,
        "file_entry": [SimpleNamespace(name=b"motor.h", dir_index=1 if version < 5 else 0)],
        "include_directory": [b"include"],
    })


def test_definitions_keep_headers_separate_from_executable_lines():
    definition = SourceDefinition("gain", "C:/firmware/include/motor.h", 7, "variable")
    index = DebugInfoIndex(definitions=[definition, definition])
    assert index.source_files == ["C:/firmware/include/motor.h"]
    assert index.executable_lines == {}
    assert index.resolve_breakpoint(definition.path, 7) is None
    assert len(index.source_definitions) == 1
    debug = DebugSession()
    debug.info = index
    assert "sourceDefinitions" not in debug.snapshot()
    assert debug.snapshot(include_definitions=True)["sourceDefinitions"] == [definition.to_json()]


@pytest.mark.parametrize("version,file_index", [(4, 1), (5, 0)])
def test_declaration_file_and_directory_indexes(version, file_index):
    assert _source_path(line_program(version), file_index, "C:/firmware") == "C:/firmware/include/motor.h"


def test_cpp_definition_inherits_name_and_site_without_declaration_flag():
    scope = Die("DW_TAG_class_type", DW_AT_name=b"Motor")
    declaration = Die(
        "DW_TAG_subprogram", parent=scope, DW_AT_name=b"step",
        DW_AT_decl_file=1, DW_AT_decl_line=12, DW_AT_declaration=True,
    )
    definition = Die("DW_TAG_subprogram", DW_AT_specification=1, DW_AT_decl_line=50)
    definition.references["DW_AT_specification"] = declaration
    result = _definition_from_die(definition, line_program(), "C:/firmware")
    assert result == SourceDefinition("step", "C:/firmware/include/motor.h", 50, "function", scope="Motor")
    local = Die(
        "DW_TAG_variable", parent=definition, DW_AT_name=b"speed",
        DW_AT_decl_file=1, DW_AT_decl_line=51,
    )
    result = _definition_from_die(local, line_program(), "C:/firmware")
    assert result.is_local
    assert result.scope == "step"


def test_inlined_parameter_and_cyclic_reference():
    function = Die("DW_TAG_subprogram", DW_AT_name=b"step")
    parameter = Die(
        "DW_TAG_formal_parameter", parent=function, DW_AT_name=b"speed",
        DW_AT_decl_file=1, DW_AT_decl_line=8,
    )
    concrete = Die("DW_TAG_formal_parameter", DW_AT_abstract_origin=1)
    concrete.references["DW_AT_abstract_origin"] = parameter
    result = _definition_from_die(concrete, line_program(), "C:/firmware")
    assert result.kind == "parameter"
    assert result.is_local
    assert result.scope == "step"
    cycle = Die("DW_TAG_variable", DW_AT_specification=1)
    cycle.references["DW_AT_specification"] = cycle
    assert _definition_from_die(cycle, line_program(), "C:/firmware") is None


def test_symbol_load_and_get_debug_info_publish_definitions_and_clear_old_sites(tmp_path):
    definition = SourceDefinition("gain", "motor.c", 2, "variable")
    elf = tmp_path / "firmware.elf"
    elf.touch()
    service = BackendService(
        lambda *_: None, recording_directory=tmp_path / "records",
        symbol_loader=lambda *_args, **_kwargs: [SymbolInfo("gain", 0x20000000, 4, "int", ".data", "motor.c")],
        debug_info_loader=lambda *_args, **_kwargs: DebugInfoIndex(definitions=[definition]),
    )
    try:
        loaded = service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(elf)})
        assert loaded["state"]["debug"]["sourceDefinitions"] == [definition.to_json()]
        assert service.handle(RpcMethod.GET_DEBUG_INFO, {})["debug"]["sourceDefinitions"] == [definition.to_json()]
        service._debug_info_loader = lambda *_args, **_kwargs: DebugInfoIndex()
        reloaded = service.handle(RpcMethod.LOAD_FIRMWARE, {"path": str(elf)})
        assert reloaded["state"]["debug"]["sourceDefinitions"] == []
    finally:
        service.close()


@pytest.mark.parametrize("version", [4, 5])
def test_real_arm_elf_indexes_cross_file_functions_and_variables(tmp_path: Path, version):
    compiler = shutil.which("arm-none-eabi-gcc")
    if compiler is None:
        pytest.skip("ARM GCC is optional; synthetic DWARF cases run on every host")
    header = tmp_path / "motor.h"
    header.write_text("extern volatile int gain;\nint motor_step(int speed);\n", encoding="utf-8")
    main = tmp_path / "main.c"
    main.write_text('#include "motor.h"\nint main(void) { return motor_step(gain); }\n', encoding="utf-8")
    motor = tmp_path / "motor.c"
    motor.write_text(
        '#include "motor.h"\nvolatile int gain = 2;\n'
        'int motor_step(int speed) { int result = speed * gain; return result; }\n',
        encoding="utf-8",
    )
    elf = tmp_path / "firmware.elf"
    subprocess.run(
        [compiler, f"-gdwarf-{version}", "-g", "-O0", "-nostdlib", "-Wl,-e,main",
         str(main), str(motor), "-o", str(elf)],
        check=True, capture_output=True,
    )
    index = load_debug_info_from_elf(elf)
    definitions = index.definitions
    assert any(item.name == "motor_step" and item.line == 3 and item.path.endswith("/motor.c")
               and not item.is_declaration for item in definitions)
    assert any(item.name == "gain" and item.line == 2 and item.path.endswith("/motor.c")
               and not item.is_declaration for item in definitions)
    assert any(item.name == "speed" and item.kind == "parameter" and item.is_local for item in definitions)
    assert any(item.name == "result" and item.scope == "motor_step" for item in definitions)
    assert any(path.endswith("/motor.h") for path in index.source_files)
    assert any(path.endswith("/motor.c") and 3 in lines for path, lines in index.executable_lines.items())


def test_real_cpp_method_and_member_definition(tmp_path):
    compiler = shutil.which("arm-none-eabi-gcc")
    if compiler is None:
        pytest.skip("ARM GCC is optional")
    source = tmp_path / "motor.cpp"
    source.write_text(
        'struct Motor { int gain; int step(int speed); };\n'
        'Motor motor;\n'
        'int Motor::step(int speed) { return speed * gain; }\n'
        'int main() { return motor.step(2); }\n',
        encoding="utf-8",
    )
    elf = tmp_path / "firmware.elf"
    subprocess.run(
        [compiler, "-gdwarf-4", "-g", "-O0", "-nostdlib", "-Wl,-e,main", str(source), "-o", str(elf)],
        check=True, capture_output=True,
    )
    definitions = load_debug_info_from_elf(elf).definitions
    assert any(item.name == "step" and item.scope == "Motor" and item.line == 3
               and not item.is_declaration for item in definitions)
    assert any(item.name == "gain" and item.scope == "Motor" and item.kind == "member" for item in definitions)
