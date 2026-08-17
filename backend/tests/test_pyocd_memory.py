from __future__ import annotations

import unittest

from take_a_look_backend.backends.pyocd_memory import (
    PyOcdMemoryBackend,
    _build_coalesced_read_plan,
    decode_symbol_value,
    encode_symbol_value,
)
from take_a_look_backend.models import SymbolInfo


class _DummyTarget:
    def __init__(self, memory: dict[int, int]) -> None:
        self.memory = memory
        self.calls: list[tuple[int, int]] = []

    def read_memory_block8(self, address: int, size: int) -> list[int]:
        self.calls.append((address, size))
        return [self.memory.get(address + offset, 0) for offset in range(size)]


def _symbol(name: str, address: int, size: int = 4) -> SymbolInfo:
    return SymbolInfo(
        name=name,
        address=address,
        size=size,
        kind="uint32_t",
        section=".data",
    )


class CoalescedReadPlanTests(unittest.TestCase):
    def test_nearby_symbols_are_merged_into_one_block(self) -> None:
        first = _symbol("first", 0x20000000)
        second = _symbol("second", 0x20000008)

        plan = _build_coalesced_read_plan(
            [first, second],
            max_gap_bytes=16,
            max_block_bytes=512,
        )

        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0].address, 0x20000000)
        self.assertEqual(plan[0].size, 12)
        self.assertEqual([slice_.offset for slice_ in plan[0].slices], [0, 8])

    def test_distant_symbols_are_split_into_multiple_blocks(self) -> None:
        first = _symbol("first", 0x20000000)
        second = _symbol("second", 0x20000040)

        plan = _build_coalesced_read_plan(
            [first, second],
            max_gap_bytes=16,
            max_block_bytes=512,
        )

        self.assertEqual(len(plan), 2)
        self.assertEqual([(block.address, block.size) for block in plan], [(0x20000000, 4), (0x20000040, 4)])


class ReadSymbolsTests(unittest.TestCase):
    def test_read_symbols_uses_coalesced_reads_and_preserves_input_order(self) -> None:
        first = _symbol("first", 0x20000000)
        second = _symbol("second", 0x20000008)
        target = _DummyTarget(
            {
                0x20000000: 0x01,
                0x20000001: 0x02,
                0x20000002: 0x03,
                0x20000003: 0x04,
                0x20000008: 0xAA,
                0x20000009: 0xBB,
                0x2000000A: 0xCC,
                0x2000000B: 0xDD,
            }
        )
        backend = PyOcdMemoryBackend()
        backend.target = target

        values = backend.read_symbols([second, first])

        self.assertEqual(target.calls, [(0x20000000, 12)])
        self.assertEqual(list(values.keys()), [second.key, first.key])
        self.assertEqual(values[first.key], 0x04030201)
        self.assertEqual(values[second.key], 0xDDCCBBAA)
        self.assertEqual(
            backend.last_read_metrics,
            {
                "symbol_count": 2,
                "block_count": 1,
                "byte_count": 12,
            },
        )

    def test_typedef_pointer_uses_pointer_metadata_for_integer_codec(self) -> None:
        symbol = SymbolInfo(
            name="handle",
            address=0x20000000,
            size=4,
            kind="Handle",
            section=".data",
            pointer=True,
        )

        self.assertEqual(decode_symbol_value(symbol, bytes.fromhex("78563412")), 0x12345678)
        self.assertEqual(encode_symbol_value(symbol, "0x20001000"), bytes.fromhex("00100020"))


if __name__ == "__main__":
    unittest.main()
