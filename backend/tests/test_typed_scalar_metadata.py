from unittest.mock import Mock

import pytest

from take_a_look_backend.backends.typed_memory import TypedMemoryBackend, decode_symbol_value, encode_symbol_value
from take_a_look_backend.models import SymbolInfo


@pytest.mark.parametrize("encoding,size,text,expected", [
    ("float", 4, "1.25", 1.25), ("float", 8, "-2.5", -2.5),
    ("bool", 1, "true", True), ("bool", 4, "0", False),
    ("signed", 1, "-128", -128), ("signed", 8, "-9223372036854775808", -(1 << 63)),
    ("unsigned", 4, "0xffffffff", (1 << 32) - 1),
])
@pytest.mark.parametrize("byte_order", ["little", "big"])
def test_scalar_metadata_controls_single_and_coalesced_codecs(encoding, size, text, expected, byte_order):
    symbol = SymbolInfo("value", 0, size, "CustomType_t", ".data", encoding=encoding, byte_order=byte_order)
    encoded = encode_symbol_value(symbol, text)
    assert len(encoded) == size
    assert decode_symbol_value(symbol, encoded) == expected
    backend = TypedMemoryBackend()
    backend.target = Mock()
    backend.target.read_memory_block8.return_value = list(encoded)
    assert backend.read_symbols([symbol]) == {symbol.key: expected}


@pytest.mark.parametrize("encoding,text", [("unsigned", "256"), ("unsigned", "-1"), ("signed", "128"), ("signed", "-129")])
def test_scalar_metadata_enforces_range_before_writing(encoding, text):
    backend = TypedMemoryBackend()
    backend.target = Mock()
    symbol = SymbolInfo("value", 0, 1, "CustomType_t", ".data", encoding=encoding)
    with pytest.raises(ValueError, match="范围"):
        backend.write_symbol(symbol, text)
    backend.target.write_memory_block8.assert_not_called()


def test_diagnostic_symbols_never_access_target_memory():
    symbol = SymbolInfo("ambiguous", 0, 4, "STT_OBJECT", ".data", diagnostic="类型匹配有歧义")
    backend = TypedMemoryBackend()
    backend.target = Mock()
    assert backend.read_symbol(symbol) == symbol.diagnostic
    assert backend.read_symbols([symbol]) == {symbol.key: symbol.diagnostic}
    with pytest.raises(ValueError, match="歧义"):
        backend.write_symbol(symbol, "0")
    backend.target.read_memory_block8.assert_not_called()
    backend.target.write_memory_block8.assert_not_called()
