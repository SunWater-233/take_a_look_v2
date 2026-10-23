import pytest

from take_a_look_backend.backends.remote_backend import RemoteMemoryBackend
from take_a_look_backend.backends.target_backend import (
    backend_capabilities,
    backend_rtt_binding,
    capabilities_for_connection,
)
from take_a_look_backend.backends.typed_memory import TypedMemoryBackend
from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.protocol import ProtocolError


@pytest.mark.parametrize("kind,polling,writes,rtt,flash", [
    ("local", True, True, True, True),
    ("ember", True, False, True, True),
    ("emberGdb", False, True, True, True),
    ("gdb", False, True, False, False),
])
def test_connection_capabilities_preserve_the_wire_contract(kind, polling, writes, rtt, flash):
    assert capabilities_for_connection(kind).to_json() == {
        "memorySampling": polling, "memoryWrite": writes,
        "rtt": rtt, "firmwareDownload": flash, "targetControl": True,
    }
    if kind != "local":
        assert backend_capabilities(RemoteMemoryBackend(kind, {})).to_json() == capabilities_for_connection(kind).to_json()


def test_shared_memory_layer_coalesces_reads_and_verifies_a_write_without_pyocd():
    class Target:
        def __init__(self):
            self.memory = bytearray(range(64))
            self.reads = []

        def read_memory_block8(self, address, size):
            self.reads.append((address, size))
            return self.memory[address:address + size]

        def write_memory_block8(self, address, data):
            self.memory[address:address + len(data)] = bytes(data)

    backend = TypedMemoryBackend()
    backend.target = Target()
    symbols = [
        SymbolInfo(name="a", address=4, size=4, kind="uint32_t", section=".data"),
        SymbolInfo(name="b", address=12, size=4, kind="uint32_t", section=".data"),
    ]
    values = backend.read_symbols(symbols)
    assert backend.target.reads == [(4, 12)]
    assert values[symbols[0].key] == int.from_bytes(bytes(range(4, 8)), "little")
    assert backend.write_symbol(symbols[0], "0x12345678") == 0x12345678
    assert backend.target.reads[-1] == (4, 4)
    assert backend_rtt_binding(backend).target is backend.target


def test_remote_backend_cannot_enter_the_local_flash_programmer():
    backend = RemoteMemoryBackend("gdb", {})
    with pytest.raises(ProtocolError) as failure:
        backend.program_firmware("unused.axf", lambda _: None)
    assert failure.value.code == "download_unsupported"
