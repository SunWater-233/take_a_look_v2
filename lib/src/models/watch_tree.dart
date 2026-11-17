import 'models.dart';
import 'symbol_hierarchy.dart';

class WatchTreeNode {
  WatchTreeNode(this.watch) : label = watch.symbol.name;

  final WatchItem watch;
  String label;
  final List<WatchTreeNode> children = <WatchTreeNode>[];

  Iterable<WatchItem> get watchesInDisplayOrder sync* {
    yield watch;
    for (final child in children) {
      yield* child.watchesInDisplayOrder;
    }
  }
}

/// Shared by the watch table, curve drawing, and hover selection.
List<WatchTreeNode> buildWatchTree(List<WatchItem> watches) {
  final nodes = <String, WatchTreeNode>{
    for (final watch in watches) watch.symbol.key: WatchTreeNode(watch),
  };
  final hierarchy = SymbolHierarchy(watches.map((watch) => watch.symbol));
  final roots = <WatchTreeNode>[];
  for (final watch in watches) {
    final node = nodes[watch.symbol.key]!;
    final parentSymbol = hierarchy.parentOf(watch.symbol);
    final parent = nodes[parentSymbol?.key];
    if (parent == null) {
      roots.add(node);
    } else {
      final parts = splitSymbolPath(watch.symbol.name);
      node.label = parts.isEmpty ? watch.symbol.name : parts.last;
      parent.children.add(node);
    }
  }
  return roots;
}
