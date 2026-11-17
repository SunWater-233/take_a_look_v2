"""Reconcile watched trees against a new ELF declaration hierarchy."""
from collections.abc import Iterable

from ..models import SymbolInfo, WatchedVariable
from .symbol_hierarchy import SymbolHierarchy, SymbolIdentity, symbol_ancestors, symbol_identity


def rebind_watches(previous: dict[str, WatchedVariable], symbols: Iterable[SymbolInfo],
                   previous_symbols: Iterable[SymbolInfo] = ()) -> dict[str, WatchedVariable]:
    if not previous:
        return {}
    hierarchy = SymbolHierarchy(symbol for symbol in symbols if not symbol.is_rtt)
    rebound: dict[SymbolIdentity, WatchedVariable] = {}
    for watch in previous.values():
        symbol = hierarchy.resolve(watch.symbol)
        if symbol is not None:
            rebound[symbol_identity(symbol)] = WatchedVariable(
                symbol, watch.color, watch.plot_enabled, watch.sampling_enabled,
                read_mode=watch.mode, monitor_rate_hz=watch.monitor_rate_hz,
                monitor_enabled=watch.monitor_enabled,
            )

    # Missing old declarations represent omitted members/branches. New members
    # join their nearest watched ancestor without restoring an omitted branch.
    old_names = {symbol_identity(symbol) for symbol in previous_symbols}
    old_names.update(symbol_identity(watch.symbol) for watch in previous.values())
    additions: dict[SymbolIdentity, list[SymbolInfo]] = {}
    for identity, symbol in hierarchy.declarations.items():
        if symbol is None or identity in old_names:
            continue
        for parent in symbol_ancestors(symbol):
            if parent in rebound:
                additions.setdefault(parent, []).append(symbol)
                break
            if parent in old_names:
                break

    # Preserve existing watch order and append new members within their branch.
    last_members = {identity: identity for identity in additions}
    for identity, watch in rebound.items():
        for parent in symbol_ancestors(watch.symbol):
            if parent in last_members:
                last_members[parent] = identity
    insertions: dict[SymbolIdentity, list[WatchedVariable]] = {}
    for identity, members in additions.items():
        parent = rebound[identity]
        insertions.setdefault(last_members[identity], []).extend(
            WatchedVariable(symbol, parent.color, sampling_enabled=False, read_mode="monitor",
                            monitor_enabled=parent.monitor_enabled)
            for symbol in members
        )
    result = {}
    for identity, watch in rebound.items():
        result[watch.symbol.key] = watch
        for added in insertions.get(identity, ()):
            result[added.symbol.key] = added
    return result
