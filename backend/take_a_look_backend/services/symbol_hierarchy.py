"""Address-independent identities and ancestry for flattened ELF members."""
from collections.abc import Iterable, Iterator

from ..models import SymbolInfo

SymbolIdentity = tuple[str, str, str]


def symbol_identity(symbol: SymbolInfo) -> SymbolIdentity:
    return symbol.data_source, symbol.source_file, symbol.name


def symbol_ancestors(symbol: SymbolInfo) -> Iterator[SymbolIdentity]:
    name = symbol.name
    while (separator := max(name.rfind('.'), name.rfind('['))) >= 0:
        name = name[:separator]
        yield symbol.data_source, symbol.source_file, name


class SymbolHierarchy:
    """Resolve declarations only when source, name and data source are unique."""

    def __init__(self, symbols: Iterable[SymbolInfo]):
        self.declarations: dict[SymbolIdentity, SymbolInfo | None] = {}
        for symbol in symbols:
            identity = symbol_identity(symbol)
            self.declarations[identity] = None if identity in self.declarations else symbol

    def resolve(self, symbol: SymbolInfo) -> SymbolInfo | None:
        return self.declarations.get(symbol_identity(symbol))
