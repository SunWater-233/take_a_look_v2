from __future__ import annotations

import unittest

from take_a_look_backend.models import SymbolInfo
from take_a_look_backend.services.symbols import _is_pointer_type_die


class _FakeTypeDie:
    def __init__(self, tag: str, offset: int, nested: _FakeTypeDie | None = None) -> None:
        self.tag = tag
        self.offset = offset
        self._nested = nested

    def get_DIE_from_attribute(self, _name: str) -> _FakeTypeDie | None:
        return self._nested


class SymbolPointerMetadataTests(unittest.TestCase):
    def test_typedef_to_pointer_is_recognized(self) -> None:
        pointer = _FakeTypeDie("DW_TAG_pointer_type", 2)
        typedef = _FakeTypeDie("DW_TAG_typedef", 1, pointer)

        self.assertTrue(_is_pointer_type_die(typedef))

    def test_textual_pointer_remains_backward_compatible(self) -> None:
        symbol = SymbolInfo("context", 0x20000000, 4, "void*", ".data")

        self.assertTrue(symbol.is_pointer)


if __name__ == "__main__":
    unittest.main()
