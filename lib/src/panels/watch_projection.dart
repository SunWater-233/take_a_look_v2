part of 'watch_panel.dart';

enum _WatchBrowserSection {
  members,
  pinned,
  capture;

  String get rowPrefix => switch (this) {
    members => 'compact',
    pinned => 'pinned',
    capture => 'capture',
  };

  String get actionPrefix => this == members ? '' : '$name-';
}

String _standaloneRowKey(String root, String key) =>
    'standalone:${root.length}:$root:$key';

class _WatchBrowserEntry {
  const _WatchBrowserEntry({
    required this.key,
    required this.label,
    required this.depth,
    this.node,
    this.members = const [],
    this.section = _WatchBrowserSection.members,
    this.standaloneRoot,
  });
  final String key, label;
  final int depth;
  final WatchTreeNode? node;
  final List<WatchTreeNode> members;
  final _WatchBrowserSection section;
  final String? standaloneRoot;
  String get rowKey =>
      standaloneRoot == null ? key : _standaloneRowKey(standaloneRoot!, key);
  bool get expandable => members.isNotEmpty;
}

typedef _WatchRowId = (String, _WatchBrowserSection, String);

class _WatchSelection {
  final keys = <String>{};
  _WatchRowId? anchor;

  String? select(
    _WatchRowId row, {
    required List<_WatchRowId> order,
    required bool preserve,
    required bool additive,
    required bool extend,
  }) {
    final key = row.$1;
    if (preserve && keys.contains(key)) return key;
    final start = extend && anchor != null ? order.indexOf(anchor!) : -1;
    final end = extend ? order.indexOf(row) : -1;
    if (!preserve && start >= 0 && end >= 0) {
      if (!additive) keys.clear();
      for (
        var index = math.min(start, end);
        index <= math.max(start, end);
        index++
      ) {
        keys.add(order[index].$1);
      }
    } else {
      anchor = row;
      if (preserve || !additive) keys.clear();
      if (!keys.add(key)) keys.remove(key);
    }
    return keys.contains(key) ? key : keys.lastOrNull;
  }
}

class _WatchProjectionCache {
  int _revision = -1;
  Map<String, List<String>> _orders = const {};
  _WatchProjection? current;

  _WatchProjection update(
    int revision,
    List<WatchItem> Function() watches,
    Map<String, List<String>> orders,
  ) {
    if (current == null ||
        _revision != revision ||
        !mapEquals(_orders, orders)) {
      final projection = _WatchProjection(watches(), orders);
      _revision = revision;
      _orders = Map.of(orders);
      current = projection;
    }
    return current!;
  }
}

class _WatchProjection {
  _WatchProjection(List<WatchItem> watches, Map<String, List<String>> orders)
    : sectionRanks = {
        for (final section in _WatchBrowserSection.values)
          section: {
            for (final (index, key)
                in (orders[section.name] ?? const <String>[]).indexed)
              key: index,
          },
      } {
    roots = _ordered(
      buildWatchTree(watches),
      _WatchBrowserSection.members,
      (node) => node.watch.symbol.key,
    );
    _indexMembers(roots);
    sectionKeys[_WatchBrowserSection.members] = [
      for (final root in roots)
        for (final watch in root.watchesInDisplayOrder) watch.symbol.key,
    ];
    final leaves = watches.where(
      (watch) => nodes[watch.symbol.key]!.children.isEmpty,
    );
    pinned = _orderSection(
      leaves.where((watch) => watch.pinned),
      _WatchBrowserSection.pinned,
    );
    captured = _orderSection(
      leaves.where((watch) => watch.samplingEnabled),
      _WatchBrowserSection.capture,
    );
  }

  late final List<WatchTreeNode> roots;
  late final List<WatchItem> pinned, captured;
  final nodes = <String, WatchTreeNode>{};
  final standalone = <WatchTreeNode>[];
  final reorderGroups = <(_WatchBrowserSection, String), List<String>>{};
  final sectionKeys = <_WatchBrowserSection, List<String>>{};
  final Map<_WatchBrowserSection, Map<String, int>> sectionRanks;
  String? _query;
  Set<String> _expanded = const {};
  List<_WatchBrowserEntry> _rows = const [];

  bool canReorder(_WatchBrowserSection section, String source, String target) =>
      source != target &&
      (reorderGroups[(section, target)]?.contains(source) ?? false);

  List<String> move(
    _WatchBrowserSection section,
    String source,
    String target, {
    required bool after,
  }) {
    final keys = List<String>.of(sectionKeys[section]!)..remove(source);
    keys.insert(keys.indexOf(target) + (after ? 1 : 0), source);
    return keys;
  }

  _WatchBrowserEntry summaryRow(
    WatchItem watch,
    _WatchBrowserSection section,
  ) => _WatchBrowserEntry(
    key: watch.symbol.key,
    label: watch.symbol.name,
    depth: 0,
    node: nodes[watch.symbol.key],
    section: section,
  );

  List<_WatchBrowserEntry> rows(String search, Set<String> expanded) {
    final query = search.trim().toLowerCase();
    if (_query != query || !setEquals(_expanded, expanded)) {
      _query = query;
      _expanded = Set.of(expanded);
      _rows = _buildRows(query, expanded);
    }
    return _rows;
  }

  void _indexMembers(List<WatchTreeNode> members) {
    const section = _WatchBrowserSection.members;
    _registerReorderGroup(
      section,
      members.map((node) => node.watch.symbol.key),
    );
    for (final node in members) {
      nodes[node.watch.symbol.key] = node;
      if (node.watch.standalone) standalone.add(node);
      final ordered = _ordered(
        node.children,
        section,
        (child) => child.watch.symbol.key,
      );
      node.children
        ..clear()
        ..addAll(ordered);
      _indexMembers(node.children);
    }
  }

  List<WatchItem> _orderSection(
    Iterable<WatchItem> watches,
    _WatchBrowserSection section,
  ) {
    final ordered = _ordered(watches, section, (watch) => watch.symbol.key);
    final keys = ordered.map((watch) => watch.symbol.key).toList();
    sectionKeys[section] = keys;
    _registerReorderGroup(section, keys);
    return ordered;
  }

  List<T> _ordered<T>(
    Iterable<T> items,
    _WatchBrowserSection section,
    String Function(T) key,
  ) {
    final list = items.toList();
    final ranks = sectionRanks[section] ?? const <String, int>{};
    if (list.length < 2 || ranks.isEmpty) return list;
    final original = {for (final (i, item) in list.indexed) key(item): i};
    list.sort((a, b) {
      final aKey = key(a), bKey = key(b);
      return (ranks[aKey] ?? ranks.length + original[aKey]!).compareTo(
        ranks[bKey] ?? ranks.length + original[bKey]!,
      );
    });
    return list;
  }

  void _registerReorderGroup(
    _WatchBrowserSection section,
    Iterable<String> keys,
  ) {
    final group = keys.toList();
    for (final key in group) {
      reorderGroups[(section, key)] = group;
    }
  }

  List<_WatchBrowserEntry> _buildRows(String query, Set<String> expanded) {
    final matches = <String, bool>{};
    bool match(WatchTreeNode n) => matches.putIfAbsent(
      n.watch.symbol.key,
      () =>
          n.watch.symbol.name.toLowerCase().contains(query) ||
          n.children.any(match),
    );
    final rows = <_WatchBrowserEntry>[];
    void visit(WatchTreeNode n, int depth, String? standaloneRoot) {
      if (query.isNotEmpty && !match(n)) return;
      final entry = _WatchBrowserEntry(
        key: n.watch.symbol.key,
        label: depth == 0 && standaloneRoot != null
            ? n.watch.symbol.name
            : n.label,
        depth: depth,
        node: n,
        members: n.children,
        standaloneRoot: standaloneRoot,
      );
      rows.add(entry);
      if (n.children.isEmpty ||
          (query.isEmpty && !expanded.contains(entry.rowKey))) {
        return;
      }
      final grouped =
          query.isEmpty &&
          n.children.length > 64 &&
          n.children.every((child) => child.label.startsWith('['));
      if (!grouped) {
        for (final child in n.children) {
          visit(child, depth + 1, standaloneRoot);
        }
        return;
      }
      for (var start = 0; start < n.children.length; start += 32) {
        final members = n.children.sublist(
          start,
          math.min(start + 32, n.children.length),
        );
        final key = '${n.watch.symbol.key}:range:${start ~/ 32}';
        final range = _WatchBrowserEntry(
          key: key,
          label: '${members.first.label}…${members.last.label}',
          depth: depth + 1,
          members: members,
          standaloneRoot: standaloneRoot,
        );
        rows.add(range);
        if (expanded.contains(range.rowKey)) {
          for (final child in members) {
            visit(child, depth + 2, standaloneRoot);
          }
        }
      }
    }

    for (final root in standalone) {
      visit(root, 0, root.watch.symbol.key);
    }
    for (final root in roots) {
      // The standalone row already represents a branch without a watched parent.
      if (!root.watch.standalone) visit(root, 0, null);
    }
    return rows;
  }
}
