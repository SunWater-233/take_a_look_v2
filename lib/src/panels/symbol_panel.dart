part of '../panels.dart';

enum _SymbolTreeNodeKind { folder, sourceFile, symbol }

class _SymbolTreeNode {
  _SymbolTreeNode({required this.key, required this.label, required this.kind});

  final String key;
  final String label;
  final _SymbolTreeNodeKind kind;
  SymbolItem? symbol;
  final List<_SymbolTreeNode> children = <_SymbolTreeNode>[];
  final Set<String> symbolKeys = <String>{};

  bool get expandable => children.isNotEmpty;
}

class _VisibleSymbolNode {
  const _VisibleSymbolNode(this.node, this.depth);

  final _SymbolTreeNode node;
  final int depth;
}

class _SymbolPanel extends StatefulWidget {
  const _SymbolPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_SymbolPanel> createState() => _SymbolPanelState();
}

class _SymbolPanelState extends State<_SymbolPanel> {
  double _nameWidth = 320;
  double _addressWidth = 145;
  double _sizeWidth = 68;
  double _sectionWidth = 100;
  double _typeWidth = 160;
  double _rowHeight = 30;
  List<double> _resizeColumnWidths = const <double>[];
  double _resizeRowHeight = 30;

  double get _tableWidth =>
      _nameWidth + _addressWidth + _sizeWidth + _sectionWidth + _typeWidth;

  final search = TextEditingController();
  final Set<String> _expanded = <String>{};
  List<_SymbolTreeNode> _tree = const <_SymbolTreeNode>[];
  List<_VisibleSymbolNode> _visibleRows = const <_VisibleSymbolNode>[];
  Map<String, bool> _selectedNodes = const <String, bool>{};
  Set<String> _selectedSymbols = const <String>{};
  int _treeRevision = -1;
  String _treeQuery = '';
  String? _lastTappedNodeKey;
  DateTime? _lastTapAt;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<_SymbolTreeNode> _buildTree(Iterable<SymbolItem> symbols) {
    final roots = <_SymbolTreeNode>[];
    final nodes = <String, _SymbolTreeNode>{};

    _SymbolTreeNode getOrCreate({
      required String key,
      required String label,
      required _SymbolTreeNodeKind kind,
      _SymbolTreeNode? parent,
    }) {
      final existing = nodes[key];
      if (existing != null) return existing;
      final node = _SymbolTreeNode(key: key, label: label, kind: kind);
      nodes[key] = node;
      if (parent == null) {
        roots.add(node);
      } else {
        parent.children.add(node);
      }
      return node;
    }

    for (final symbol in symbols) {
      final source = symbol.source.replaceAll('\\', '/');
      final sourceParts = source
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      if (sourceParts.isEmpty) sourceParts.add('未知来源');

      _SymbolTreeNode? parent;
      var sourceKey = 'source';
      for (var index = 0; index < sourceParts.length; index += 1) {
        final part = sourceParts[index];
        sourceKey = '$sourceKey/$part';
        parent = getOrCreate(
          key: sourceKey,
          label: part,
          kind: index == sourceParts.length - 1
              ? _SymbolTreeNodeKind.sourceFile
              : _SymbolTreeNodeKind.folder,
          parent: parent,
        );
      }

      final nameParts = _splitSymbolPath(symbol.name);
      var symbolKey = '${parent!.key}/symbol';
      for (var index = 0; index < nameParts.length; index += 1) {
        final part = nameParts[index];
        symbolKey = '$symbolKey/$part';
        final node = getOrCreate(
          key: symbolKey,
          label: part,
          kind: _SymbolTreeNodeKind.symbol,
          parent: parent,
        );
        if (index == nameParts.length - 1) node.symbol = symbol;
        parent = node;
      }
    }

    void prepareNode(_SymbolTreeNode node) {
      node.children.sort((a, b) {
        final kindOrder = a.kind.index.compareTo(b.kind.index);
        return kindOrder == 0
            ? a.label.toLowerCase().compareTo(b.label.toLowerCase())
            : kindOrder;
      });
      for (final child in node.children) {
        prepareNode(child);
        node.symbolKeys.addAll(child.symbolKeys);
      }
      final symbol = node.symbol;
      if (symbol != null) node.symbolKeys.add(symbol.key);
    }

    roots.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    for (final root in roots) {
      prepareNode(root);
    }
    return roots;
  }

  List<String> _splitSymbolPath(String name) {
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
    return parts.isEmpty ? <String>[name] : parts;
  }

  List<_VisibleSymbolNode> _flatten(
    List<_SymbolTreeNode> roots, {
    required bool expandAll,
  }) {
    final result = <_VisibleSymbolNode>[];
    void visit(_SymbolTreeNode node, int depth) {
      result.add(_VisibleSymbolNode(node, depth));
      if (expandAll || _expanded.contains(node.key)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return result;
  }

  void _toggleNode(_SymbolTreeNode node) {
    setState(() {
      if (!_expanded.add(node.key)) _expanded.remove(node.key);
      _rebuildVisibleRows();
    });
  }

  void _beginTableResize() {
    _resizeColumnWidths = <double>[
      _nameWidth,
      _addressWidth,
      _sizeWidth,
      _sectionWidth,
      _typeWidth,
    ];
    _resizeRowHeight = _rowHeight;
  }

  void _resizeTable(Offset delta) {
    if (_resizeColumnWidths.length != 5) return;
    final columnDelta = delta.dx * 0.75;
    final rowDelta = delta.dy * 0.75;
    setState(() {
      _nameWidth = math.max(120, _resizeColumnWidths[0] + columnDelta);
      _addressWidth = math.max(80, _resizeColumnWidths[1] + columnDelta);
      _sizeWidth = math.max(48, _resizeColumnWidths[2] + columnDelta);
      _sectionWidth = math.max(60, _resizeColumnWidths[3] + columnDelta);
      _typeWidth = math.max(80, _resizeColumnWidths[4] + columnDelta);
      _rowHeight = math.max(18, _resizeRowHeight + rowDelta);
    });
  }

  void _resizeColumn(int index, double delta) {
    setState(() {
      switch (index) {
        case 0:
          _nameWidth = math.max(120, _nameWidth + delta);
        case 1:
          _addressWidth = math.max(80, _addressWidth + delta);
        case 2:
          _sizeWidth = math.max(48, _sizeWidth + delta);
        case 3:
          _sectionWidth = math.max(60, _sectionWidth + delta);
        case 4:
          _typeWidth = math.max(80, _typeWidth + delta);
      }
    });
  }

  Set<String> _symbolKeysForNode(_SymbolTreeNode node) {
    return node.symbolKeys;
  }

  void _ensureTreeCache() {
    final query = search.text;
    if (_treeRevision == widget.controller.symbolRevision &&
        _treeQuery == query) {
      return;
    }
    final symbolsChanged = _treeRevision != widget.controller.symbolRevision;
    final symbols = widget.controller.symbols
        .where((item) => item.matches(query))
        .toList(growable: false);
    _tree = _buildTree(symbols);
    if (symbolsChanged) _expanded.clear();
    _treeRevision = widget.controller.symbolRevision;
    _treeQuery = query;
    _rebuildVisibleRows();
    _selectedSymbols = const <String>{};
    _selectedNodes = const <String, bool>{};
  }

  void _rebuildVisibleRows() {
    _visibleRows = _flatten(_tree, expandAll: _treeQuery.trim().isNotEmpty);
  }

  void _ensureSelectionCache(Set<String> selected) {
    if (setEquals(_selectedSymbols, selected)) return;
    final selectedNodes = <String, bool>{};

    bool visit(_SymbolTreeNode node) {
      var allSelected =
          node.symbol == null || selected.contains(node.symbol!.key);
      for (final child in node.children) {
        allSelected = visit(child) && allSelected;
      }
      selectedNodes[node.key] = node.symbolKeys.isNotEmpty && allSelected;
      return allSelected;
    }

    for (final root in _tree) {
      visit(root);
    }
    _selectedSymbols = Set<String>.of(selected);
    _selectedNodes = selectedNodes;
  }

  void _selectNode(_SymbolTreeNode node) {
    final now = DateTime.now();
    final isDoubleTap =
        _lastTappedNodeKey == node.key &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 400);
    _lastTappedNodeKey = isDoubleTap ? null : node.key;
    _lastTapAt = isDoubleTap ? null : now;

    final keys = _symbolKeysForNode(node);
    if (HardwareKeyboard.instance.isControlPressed) {
      final next = widget.controller.selectedSymbols.toSet();
      if (keys.every(next.contains)) {
        next.removeAll(keys);
      } else {
        next.addAll(keys);
      }
      widget.controller.selectSymbols(next);
    } else {
      widget.controller.selectSymbols(keys);
    }
    final symbol = node.symbol;
    if (isDoubleTap && symbol != null) {
      widget.controller.activateSymbol(symbol.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller.symbolChanges,
      builder: (context, _) {
        _ensureTreeCache();
        final selectedSymbols = widget.controller.selectedSymbols;
        _ensureSelectionCache(selectedSymbols);
        final rows = _visibleRows;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        color: TalColors.input,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: TalColors.border),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.controller.symbolFile.isEmpty
                            ? '尚未读取 .elf / .axf'
                            : widget.controller.symbolFile,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.controller.symbolFile.isEmpty
                            ? talMuted
                            : talBody,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: OutlinedButton(
                      onPressed: widget.controller.chooseSymbolFile,
                      child: const Text('选择文件'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    child: OutlinedButton(
                      onPressed: widget.controller.symbols.isEmpty
                          ? null
                          : widget.controller.refreshSymbols,
                      child: const Text('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  style: talBody,
                  decoration: const InputDecoration(
                    hintText: '按变量名或地址过滤',
                    prefixIcon: Icon(Icons.search, size: 17),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: TalColors.input,
                    border: Border.fromBorderSide(
                      BorderSide(color: TalColors.border),
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: _tableWidth,
                          key: const ValueKey('symbol-table-content'),
                          height: constraints.maxHeight,
                          child: Column(
                            children: [
                              _SymbolTableHeader(
                                nameWidth: _nameWidth,
                                addressWidth: _addressWidth,
                                sizeWidth: _sizeWidth,
                                sectionWidth: _sectionWidth,
                                typeWidth: _typeWidth,
                                onResizeColumn: _resizeColumn,
                              ),
                              Expanded(
                                child: _RightDragResizeRegion(
                                  key: const ValueKey(
                                    'symbol-table-resize-region',
                                  ),
                                  onResizeStart: _beginTableResize,
                                  onResize: _resizeTable,
                                  child: _tree.isEmpty
                                      ? const SizedBox.expand()
                                      : ListView.builder(
                                          itemCount: rows.length,
                                          itemBuilder: (context, index) =>
                                              _SymbolTreeRow(
                                                entry: rows[index],
                                                nameWidth: _nameWidth,
                                                addressWidth: _addressWidth,
                                                sizeWidth: _sizeWidth,
                                                sectionWidth: _sectionWidth,
                                                typeWidth: _typeWidth,
                                                rowHeight: _rowHeight,
                                                selected:
                                                    _selectedNodes[rows[index]
                                                        .node
                                                        .key] ??
                                                    false,
                                                expanded:
                                                    _treeQuery
                                                        .trim()
                                                        .isNotEmpty ||
                                                    _expanded.contains(
                                                      rows[index].node.key,
                                                    ),
                                                onToggleNode: _toggleNode,
                                                onSelectNode: _selectNode,
                                              ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: TalColors.surface,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.controller.symbols.isEmpty
                          ? '读取完成后，变量会按来源文件分层展示。'
                          : '${widget.controller.symbols.length} 个变量，已选择 ${widget.controller.selectedSymbols.length} 个',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: talMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 160,
                    child: OutlinedButton(
                      onPressed: widget.controller.selectedSymbols.isEmpty
                          ? null
                          : widget.controller.addSelectedToWatch,
                      child: const Text('加入实时调参'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SymbolTableHeader extends StatelessWidget {
  const _SymbolTableHeader({
    required this.nameWidth,
    required this.addressWidth,
    required this.sizeWidth,
    required this.sectionWidth,
    required this.typeWidth,
    required this.onResizeColumn,
  });

  final double nameWidth;
  final double addressWidth;
  final double sizeWidth;
  final double sectionWidth;
  final double typeWidth;
  final _ColumnResizeCallback onResizeColumn;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ResizableTableHeaderCell(
          label: '来源文件 / 变量',
          width: nameWidth,
          columnIndex: 0,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        _ResizableTableHeaderCell(
          label: '地址',
          width: addressWidth,
          columnIndex: 1,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        _ResizableTableHeaderCell(
          label: '大小',
          width: sizeWidth,
          columnIndex: 2,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        _ResizableTableHeaderCell(
          label: '段',
          width: sectionWidth,
          columnIndex: 3,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        _ResizableTableHeaderCell(
          label: '类型',
          width: typeWidth,
          columnIndex: 4,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
      ],
    );
  }
}

class _SymbolTreeRow extends StatelessWidget {
  const _SymbolTreeRow({
    required this.entry,
    required this.nameWidth,
    required this.addressWidth,
    required this.sizeWidth,
    required this.sectionWidth,
    required this.typeWidth,
    required this.rowHeight,
    required this.selected,
    required this.expanded,
    required this.onToggleNode,
    required this.onSelectNode,
  });

  final _VisibleSymbolNode entry;
  final double nameWidth;
  final double addressWidth;
  final double sizeWidth;
  final double sectionWidth;
  final double typeWidth;
  final double rowHeight;
  final bool selected;
  final bool expanded;
  final ValueChanged<_SymbolTreeNode> onToggleNode;
  final ValueChanged<_SymbolTreeNode> onSelectNode;

  @override
  Widget build(BuildContext context) {
    final node = entry.node;
    final symbol = node.symbol;
    final isExpanded = node.expandable && expanded;
    final rowColor = selected ? TalColors.selection : TalColors.input;

    Widget valueCell(String value, double width) => SizedBox(
      width: width,
      height: rowHeight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: TalColors.borderSoft)),
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: talMono,
        ),
      ),
    );

    return Material(
      key: ValueKey('symbol-tree-row-${node.key}'),
      color: rowColor,
      child: InkWell(
        onTap: () => onSelectNode(node),
        child: SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              SizedBox(
                width: nameWidth,
                child: Row(
                  children: [
                    SizedBox(
                      width: math.min(
                        entry.depth * 18.0,
                        math.max(0, nameWidth - 82),
                      ),
                    ),
                    SizedBox(
                      width: 20,
                      child: node.expandable
                          ? InkWell(
                              key: ValueKey('symbol-tree-toggle-${node.key}'),
                              onTap: () => onToggleNode(node),
                              child: Icon(
                                isExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                size: 17,
                                color: TalColors.muted,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Icon(
                      node.kind == _SymbolTreeNodeKind.folder
                          ? (isExpanded ? Icons.folder_open : Icons.folder)
                          : node.kind == _SymbolTreeNodeKind.sourceFile
                          ? Icons.insert_drive_file_outlined
                          : Icons.data_object,
                      size: 16,
                      color: node.kind == _SymbolTreeNodeKind.symbol
                          ? TalColors.accent
                          : TalColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        node.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: node.kind == _SymbolTreeNodeKind.symbol
                            ? talBody
                            : talStrong,
                      ),
                    ),
                  ],
                ),
              ),
              valueCell(symbol?.addressLabel ?? '', addressWidth),
              valueCell(symbol == null ? '' : '${symbol.size}', sizeWidth),
              valueCell(symbol?.section ?? '', sectionWidth),
              valueCell(symbol?.type ?? '', typeWidth),
            ],
          ),
        ),
      ),
    );
  }
}
