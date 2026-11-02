import struct
from unittest.mock import patch

import pytest

from take_a_look_backend.backends import typed_memory
from take_a_look_backend.backends.pyocd_memory import PyOcdMemoryBackend
from take_a_look_backend.backends.typed_memory import TypedMemoryBackend
from take_a_look_backend.models import SymbolInfo


def symbol(name, address, size=4, kind="uint32_t", **kwargs):
    return SymbolInfo(name, address, size, kind, kwargs.pop("section", ".data"), **kwargs)


class Target:
    def __init__(self):
        self.data = bytearray(256)
        self.reads, self.writes = [], []

    def read_memory_block8(self, address, size):
        self.reads.append((address, size))
        return self.data[address:address + size]

    def write_memory_block8(self, address, values):
        self.writes.append((address, bytes(values)))
        self.data[address:address + len(values)] = bytes(values)


def backend():
    result = TypedMemoryBackend()
    result.target = Target()
    return result


def test_compiled_mixed_layout_preserves_types_gaps_and_caller_order():
    memory = backend()
    fields = [(symbol("signed", 0, 2, "int16_t"), -123, "<h"),
              (symbol("float", 3, 4, "volatile float"), 1.25, "<f"),
              (symbol("double", 8, 8, "double"), -2.5, "<d"),
              (symbol("bool", 16, 1, "bool"), True, "<?"),
              (symbol("pointer", 20, 8, "Handle", pointer=True), 0x123456789ABC, "<Q")]
    for item, value, fmt in fields:
        memory.target.data[item.address:item.address + item.size] = struct.pack(fmt, value)
    raw = symbol("raw", 30, 3, "struct RGB")
    memory.target.data[30:33] = bytes.fromhex("00aaff")
    inputs = [raw, *[item for item, _, _ in reversed(fields)]]
    result = memory.read_symbols(inputs)
    assert list(result) == [item.key for item in inputs]
    assert result[raw.key] == "00 AA FF"
    for item, value, _ in fields:
        assert result[item.key] == value
        assert type(result[item.key]) is type(value)
    assert memory.target.reads == [(0, 33)]


def test_overlapping_aliases_decode_without_extra_reads():
    memory = backend()
    memory.target.data[:4] = bytes.fromhex("ff123456")
    wide, alias = symbol("wide", 0), symbol("alias", 0, 1, "int8_t")
    assert memory.read_symbols([wide, alias]) == {wide.key: 0x563412FF, alias.key: -1}
    assert memory.target.reads == [(0, 4)]


def test_capture_and_monitor_plans_are_reused_and_type_changes_invalidate():
    memory = backend()
    integer = symbol("value", 0)
    monitor = symbol("monitor", 64)
    memory.target.data[:4] = struct.pack("<f", 1.5)
    with patch.object(typed_memory, "_build_coalesced_read_plan",
                      wraps=typed_memory._build_coalesced_read_plan) as planner:
        for _ in range(5):
            memory.read_symbols([integer])
            memory.read_symbols([monitor])
        assert planner.call_count == 2
        floating = symbol("value", 0, kind="float")
        assert floating.key == integer.key
        assert memory.read_symbols([floating])[floating.key] == 1.5
        assert planner.call_count == 3
        memory._clear_read_plans()
        memory.read_symbols([floating])
        assert planner.call_count == 4


def test_incomplete_memory_data_is_never_accepted_as_a_smaller_integer():
    memory = backend()
    with pytest.raises(ValueError, match="不完整"):
        memory.read_symbols([symbol("short", 255)])
    with pytest.raises(ValueError, match="不完整"):
        memory.read_symbol(symbol("short", 255))


def test_batch_write_merges_adjacent_bytes_and_keeps_gaps_untouched():
    memory = backend()
    memory.target.data[:] = b"\xcc" * 256
    a, b, c = symbol("a", 0), symbol("b", 4), symbol("c", 16)
    assert memory.write_symbols([(a, "1"), (b, "2"), (c, "3")]) == {
        a.key: 1, b.key: 2, c.key: 3}
    assert memory.target.writes == [(0, struct.pack("<II", 1, 2)), (16, struct.pack("<I", 3))]
    assert memory.target.data[8:16] == b"\xcc" * 8
    assert memory.target.reads == [(0, 20)]


@pytest.mark.parametrize("invalid", ["overflow", "readonly", "duplicate"])
def test_batch_validates_every_entry_before_touching_the_target(invalid):
    memory = backend()
    a, b = symbol("a", 0), symbol("b", 4)
    tail = (b, "999999999999999999999") if invalid == "overflow" else (
        (symbol("constant", 4, section=".rodata"), "2") if invalid == "readonly" else (a, "2"))
    with pytest.raises(ValueError):
        memory.write_symbols([(a, "1"), tail])
    assert memory.target.writes == []


def test_batch_preserves_reversed_and_overlapping_write_order():
    memory = backend()
    a, b = symbol("a", 0), symbol("b", 4)
    memory.write_symbols([(b, "2"), (a, "1")])
    assert [address for address, _ in memory.target.writes] == [4, 0]
    alias = symbol("alias", 1, 1, "uint8_t")
    result = memory.write_symbols([(a, "0"), (alias, "255")])
    assert result[a.key] == 0xFF00 and result[alias.key] == 255


def test_pyocd_scatter_queues_reads_before_resolving_callbacks():
    events = []

    class DeferredTarget:
        def read_memory(self, address, transfer_size, now):
            assert transfer_size == 32 and now is False
            events.append(("queue", address))

            def resolve():
                events.append(("resolve", address))
                return address
            return resolve

    memory = PyOcdMemoryBackend()
    memory.target = DeferredTarget()
    items = [symbol(f"item{i}", i * 64) for i in range(3)]
    assert memory.read_symbols(items) == {item.key: item.address for item in items}
    assert events == [("queue", 0), ("queue", 64), ("queue", 128),
                      ("resolve", 0), ("resolve", 64), ("resolve", 128)]


@pytest.mark.parametrize("native,words", [(True, 1), (False, 2)])
def test_pyocd_preserves_native_and_multiword_accelerated_block_reads(native, words):
    from types import SimpleNamespace
    memory = PyOcdMemoryBackend()
    target = memory.target = Target()
    target.selected_core = SimpleNamespace(ap=SimpleNamespace(
        _accelerated_memory_interface=object() if native else None))
    def scalar(*args, **kwargs):
        raise AssertionError("A block read must not be split into scalar transfers")
    target.read_memory = scalar
    items = [symbol(f"v{i}", start + i * 4) for start in (0, 64) for i in range(words)]
    memory.read_symbols(items)
    assert target.reads == [(0, words * 4), (64, words * 4)]
