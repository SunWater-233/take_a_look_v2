"""Compile real ARM DWARF and exercise symbol matching plus memory codecs."""
import shutil
import subprocess
import os
from pathlib import Path

import pytest

from take_a_look_backend.backends.typed_memory import decode_symbol_value, encode_symbol_value
from take_a_look_backend.services.elf_context import ElfLoadContext
from take_a_look_backend.services.symbols import load_symbols_from_elf


SOURCE = """
typedef float Speed_t;
typedef _Bool Flag_t;
typedef signed char Delta_t;
typedef enum { MODE_NEGATIVE = -2, MODE_POSITIVE = 10 } Mode_t;
typedef struct { Speed_t speed; Flag_t flag; Delta_t delta; Mode_t mode; } Motor_t;
volatile Speed_t requested_speed = 1.25f;
Flag_t zero_force = 1;
Delta_t delta = -7;
Mode_t mode = MODE_NEGATIVE;
Motor_t motor = {2.5f, 1, -3, MODE_POSITIVE};
unsigned int shared_word = 0x3f800000;
extern Speed_t shared_float __attribute__((alias("shared_word")));
const unsigned char table[3] = {1, 2, 3};
static volatile Speed_t repeated = 3.5f;
Speed_t read_a(void) { return repeated; }
void _start(void) { for (;;) { requested_speed = read_a(); } }
"""


@pytest.mark.parametrize("optimization", ["-O0", "-O2", "-Os"])
@pytest.mark.parametrize("toolchain,dwarf_version", [("gcc", 4), ("gcc", 5), ("armclang", 4)])
def test_arm_elf_typedefs_enums_members_aliases_and_static_names(tmp_path, optimization, toolchain, dwarf_version):
    compiler = (shutil.which("arm-none-eabi-gcc") if toolchain == "gcc" else
                os.environ.get("TAL_ARMCLANG") or shutil.which("armclang"))
    if compiler is None:
        pytest.skip(f"{toolchain} not installed (TAL_ARMCLANG can select Arm Compiler)")
    source = tmp_path / "a.c"
    source.write_text(SOURCE)
    other = tmp_path / "b.c"
    other.write_text("static volatile int repeated = -42; int read_b(void) { return repeated; }")
    output = tmp_path / "types.elf"
    common = [compiler, "-g", f"-gdwarf-{dwarf_version}", optimization, "-fshort-enums", "-mcpu=cortex-m3", "-mthumb"]
    if toolchain == "gcc":
        subprocess.run([*common, "-nostdlib", "-Wl,--entry=_start", "-Wl,-Ttext=0x08000000",
                        "-Wl,-Tdata=0x20000000", str(source), str(other), "-o", str(output)],
                       check=True, capture_output=True, timeout=30)
    else:
        objects = []
        for path in (source, other):
            obj = path.with_suffix(".o")
            subprocess.run([*common, "--target=arm-arm-none-eabi", "-c", str(path), "-o", str(obj)],
                           check=True, capture_output=True, timeout=30)
            objects.append(str(obj))
        linker = Path(compiler).with_name("armlink.exe" if os.name == "nt" else "armlink")
        subprocess.run([str(linker), "--entry=_start", "--rw_base=0x20000000", "--ro_base=0x08000000",
                        "--no_scanlib", "--no_remove", *objects, "--output", str(output)],
                       check=True, capture_output=True, timeout=30)
    with ElfLoadContext(output) as context:
        symbols = load_symbols_from_elf(output, context=context)
        segments = [(int(section["sh_addr"]), section.data()) for section in context.elf.iter_sections()
                    if section["sh_flags"] & 2 and section["sh_type"] != "SHT_NOBITS"]

    def initial_value(symbol):
        assert not symbol.diagnostic, (symbol.name, symbol.diagnostic)
        for address, data in segments:
            if address <= symbol.address and symbol.address + symbol.size <= address + len(data):
                return decode_symbol_value(symbol, data[symbol.address - address:symbol.address - address + symbol.size])
        raise AssertionError(f"unmapped {symbol}")

    named = {symbol.name: symbol for symbol in symbols if symbol.name != "repeated"}
    expected = {"requested_speed": 1.25, "zero_force": True, "delta": -7, "mode": -2,
                "motor.speed": 2.5, "motor.flag": True, "motor.delta": -3, "motor.mode": 10,
                "shared_word": 0x3f800000, "shared_float": 1.0}
    for name, value in expected.items():
        symbol = named[name]
        if toolchain == "armclang" and name == "shared_float":
            # Arm Compiler emits the ELF alias but no DWARF DIE for it. It must
            # not inherit shared_word's integer type just because addresses match.
            assert symbol.diagnostic and not symbol.is_writable
            with pytest.raises(ValueError, match="类型信息"):
                encode_symbol_value(symbol, "1.0")
            continue
        assert initial_value(symbol) == value, symbol
        encoded = encode_symbol_value(symbol, str(value))
        assert decode_symbol_value(symbol, encoded) == value
    assert named["requested_speed"].kind == "volatile Speed_t"
    assert named["requested_speed"].encoding == "float"
    assert named["zero_force"].encoding == "bool"
    assert named["table"].size == 3 and not named["table"].diagnostic
    repeated = [symbol for symbol in symbols if symbol.name == "repeated"]
    assert len(repeated) == 2
    assert {initial_value(symbol) for symbol in repeated} == {3.5, -42}
    assert all(symbol.source_file.endswith(("a.c", "b.c")) for symbol in repeated)
    assert repeated[0].source_file != repeated[1].source_file


def test_cpp_static_member_inherits_its_declaration_and_linkage_name(tmp_path):
    compiler = shutil.which("arm-none-eabi-g++")
    if compiler is None:
        pytest.skip("ARM G++ not installed")
    source = tmp_path / "member.cpp"
    source.write_text("""
        typedef float Speed_t;
        namespace App { struct Device { static volatile Speed_t target; }; }
        volatile Speed_t App::Device::target = 2.5f;
        extern "C" void _start(void) { for (;;) { App::Device::target += 1; } }
    """)
    output = tmp_path / "member.elf"
    subprocess.run([compiler, "-g", "-gdwarf-5", "-O2", "-mcpu=cortex-m3", "-mthumb", "-nostdlib",
                    "-Wl,--entry=_start", str(source), "-lgcc", "-o", str(output)],
                   check=True, capture_output=True, timeout=30)
    symbols = load_symbols_from_elf(output)
    target = next(symbol for symbol in symbols if symbol.name == "_ZN3App6Device6targetE")
    assert (target.kind, target.encoding, target.size, target.diagnostic) == ("volatile Speed_t", "float", 4, "")
    assert target.source_file.endswith("member.cpp")
