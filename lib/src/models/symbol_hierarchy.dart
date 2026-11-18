import 'models.dart';

/// Paths emitted by DWARF expansion use dots for members and brackets for arrays.
List<String> splitSymbolPath(String name) {
  final parts = RegExp(
    r'[^.\[\]]+|\[[^\]]*\]',
  ).allMatches(name).map((match) => match.group(0)!).toList();
  return parts.isEmpty ? [name] : parts;
}

Iterable<SymbolIdentity> symbolAncestors(SymbolItem symbol) sync* {
  var name = symbol.name;
  while (true) {
    final dot = name.lastIndexOf('.');
    final bracket = name.lastIndexOf('[');
    final separator = dot > bracket ? dot : bracket;
    if (separator < 0) return;
    name = name.substring(0, separator);
    yield (symbol.dataSource, symbol.source, name);
  }
}

/// Shared by member enrollment, removal, restoration and watch-tree rendering.
class SymbolHierarchy {
  SymbolHierarchy(Iterable<SymbolItem> symbols) {
    for (final symbol in symbols) {
      final identity = symbol.identity;
      _declarations[identity] = _declarations.containsKey(identity)
          ? null
          : symbol;
    }
  }

  final _declarations = <SymbolIdentity, SymbolItem?>{};
  late final _descendants = _indexDescendants();

  Map<SymbolIdentity, List<SymbolItem>> _indexDescendants() {
    final descendants = <SymbolIdentity, List<SymbolItem>>{};
    for (final symbol in _declarations.values.whereType<SymbolItem>()) {
      for (final ancestor in symbolAncestors(symbol)) {
        (descendants[ancestor] ??= []).add(symbol);
      }
    }
    return descendants;
  }

  SymbolItem? resolve(SymbolItem symbol) => _declarations[symbol.identity];

  Iterable<SymbolItem> descendantsOf(
    SymbolItem root, {
    Set<SymbolIdentity> excludeSubtrees = const {},
  }) {
    if (resolve(root)?.key != root.key) return const [];
    final members = _descendants[root.identity] ?? const [];
    if (excludeSubtrees.isEmpty) return members;
    return members.where(
      (member) =>
          !excludeSubtrees.contains(member.identity) &&
          !symbolAncestors(member)
              .takeWhile((identity) => identity != root.identity)
              .any(excludeSubtrees.contains),
    );
  }

  SymbolItem? parentOf(SymbolItem symbol) {
    for (final ancestor in symbolAncestors(symbol)) {
      final parent = _declarations[ancestor];
      if (parent != null) return parent;
    }
    return null;
  }
}
