import 'models.dart';

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
  final bySourceAndName = <String, WatchTreeNode>{
    for (final watch in watches)
      '${watch.symbol.source}\u0000${watch.symbol.name}':
          nodes[watch.symbol.key]!,
  };
  final roots = <WatchTreeNode>[];
  for (final watch in watches) {
    final node = nodes[watch.symbol.key]!;
    var parentName = _watchParentName(watch.symbol.name);
    WatchTreeNode? parent;
    while (parentName != null) {
      parent = bySourceAndName['${watch.symbol.source}\u0000$parentName'];
      if (parent != null) break;
      parentName = _watchParentName(parentName);
    }
    if (parent == null) {
      roots.add(node);
    } else {
      final parts = _watchNameParts(watch.symbol.name);
      node.label = parts.isEmpty ? watch.symbol.name : parts.last;
      parent.children.add(node);
    }
  }
  return roots;
}

String? _watchParentName(String name) {
  final parts = _watchNameParts(name);
  if (parts.length <= 1) return null;
  final buffer = StringBuffer();
  for (final part in parts.take(parts.length - 1)) {
    if (buffer.isNotEmpty && !part.startsWith('[')) buffer.write('.');
    buffer.write(part);
  }
  return buffer.toString();
}

List<String> _watchNameParts(String name) {
  final parts = <String>[];
  final tokenPattern = RegExp(r'[^\[\]]+|\[[^\]]*\]');
  for (final chunk in name.split('.')) {
    parts.addAll(
      tokenPattern
          .allMatches(chunk)
          .map((match) => match.group(0)!)
          .where((part) => part.isNotEmpty),
    );
  }
  return parts;
}
