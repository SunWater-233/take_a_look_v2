import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../theme/theme.dart';
import 'table_layout.dart';

import 'shared_controls.dart';
import 'source_file_drag_data.dart';

enum _SymbolTreeNodeKind { folder, sourceFile, symbol }

class _SymbolTreeNode {
  _SymbolTreeNode({required this.key, required this.label, required this.kind});

  final String key;
  final String label;
  final _SymbolTreeNodeKind kind;
  SymbolItem? symbol;
  String? sourcePath;
  final List<_SymbolTreeNode> children = <_SymbolTreeNode>[];
  final Set<String> symbolKeys = <String>{};

  bool get expandable => children.isNotEmpty;
}

class _VisibleSymbolNode {
  const _VisibleSymbolNode(this.node, this.depth);

  final _SymbolTreeNode node;
  final int depth;
}

class _SymbolTreeCache {
  int revision = -1;
  List<_SymbolTreeNode> tree = const <_SymbolTreeNode>[];
  Set<String> selectedSymbols = const <String>{};
  Map<String, bool> selectedNodes = const <String, bool>{};
}

final Expando<_SymbolTreeCache> _symbolTreeCaches = Expando<_SymbolTreeCache>(
  'symbol-tree-cache',
);

class SymbolPanel extends StatefulWidget {
  const SymbolPanel({
    super.key,
    required this.controller,
    this.defaultMonitor = false,
    this.onShowSource,
  });

  final TakeALookController controller;
  final bool defaultMonitor;
  final VoidCallback? onShowSource;

  @override
  State<SymbolPanel> createState() => _SymbolPanelState();
}

class _SymbolPanelState extends State<SymbolPanel> {
  final ResizableTableLayout _tableLayout = ResizableTableLayout(
    widths: const [320, 145, 68, 100, 160],
    minimumWidths: const [120, 80, 48, 60, 80],
    rowHeight: 30,
  );

  double get _nameWidth => _tableLayout.widths[0];
  double get _addressWidth => _tableLayout.widths[1];
  double get _sizeWidth => _tableLayout.widths[2];
  double get _sectionWidth => _tableLayout.widths[3];
  double get _typeWidth => _tableLayout.widths[4];
  double get _rowHeight => _tableLayout.rowHeight;

  double get _tableWidth =>
      _nameWidth + _addressWidth + _sizeWidth + _sectionWidth + _typeWidth;

  final search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'symbol-search');
  List<_SymbolTreeNode> _tree = const <_SymbolTreeNode>[];
  List<_VisibleSymbolNode> _visibleRows = const <_VisibleSymbolNode>[];
  Map<String, bool> _selectedNodes = const <String, bool>{};
  Set<String> _selectedSymbols = const <String>{};
  int _treeRevision = -1;
  String _treeQuery = '';
  final Set<String> _collapsedSearchNodes = <String>{};
  String? _lastTappedNodeKey;
  DateTime? _lastTapAt;

  @override
  void dispose() {
    search.dispose();
    _searchFocus.dispose();
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

      if (source.trim().isNotEmpty && source != '未知来源') {
        parent!.sourcePath = source;
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
      if (expandAll
          ? !_collapsedSearchNodes.contains(node.key)
          : widget.controller.isSymbolTreeNodeExpanded(node.key)) {
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
      if (_treeQuery.trim().isNotEmpty) {
        if (!_collapsedSearchNodes.add(node.key)) {
          _collapsedSearchNodes.remove(node.key);
        }
      } else {
        widget.controller.toggleSymbolTreeNodeExpansion(node.key);
      }
      _rebuildVisibleRows();
    });
  }

  bool _isExpanded(_SymbolTreeNode node) => _treeQuery.trim().isNotEmpty
      ? !_collapsedSearchNodes.contains(node.key)
      : widget.controller.isSymbolTreeNodeExpanded(node.key);

  Future<void> _showFileContextMenu(
    _SymbolTreeNode node,
    Offset globalPosition,
  ) async {
    if (node.kind != _SymbolTreeNodeKind.sourceFile) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final path = node.sourcePath;
    final added = path != null && widget.controller.isSourceFileOpen(path);
    final expanded = _isExpanded(node);
    final ui = TalUiTheme.of(context);
    PopupMenuItem<String> item(
      String value,
      String label,
      IconData icon, {
      bool enabled = true,
    }) => PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: ui.menuItemHeight,
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: enabled ? TalColors.text : TalColors.muted,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
    final action = await showTalContextMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        item(
          'expand',
          expanded ? '收起' : '展开',
          expanded ? Icons.unfold_less : Icons.unfold_more,
        ),
        const PopupMenuDivider(),
        item(
          'add',
          added ? '已添加到源码调试' : '添加到源码调试',
          added ? Icons.check : Icons.code,
          enabled: path != null && !added,
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'expand') {
      _toggleNode(node);
    } else if (action == 'add' && path != null) {
      widget.controller.addSourceFileFromSymbols(path);
    }
  }

  void _resizeColumn(int index, double delta) {
    if (_tableLayout.resizeColumn(index, delta)) setState(() {});
  }

  void _keepSearchFocusAfterWorkspaceReorder() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
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
    if (_treeQuery != query) _collapsedSearchNodes.clear();
    if (query.isEmpty) {
      final cache = _symbolTreeCaches[widget.controller] ??= _SymbolTreeCache();
      if (cache.revision != widget.controller.symbolRevision) {
        cache.tree = _buildTree(widget.controller.symbols);
        cache.revision = widget.controller.symbolRevision;
        cache.selectedSymbols = const <String>{};
        cache.selectedNodes = const <String, bool>{};
      }
      _tree = cache.tree;
    } else {
      final symbols = widget.controller.symbols
          .where((item) => item.matches(query))
          .toList(growable: false);
      _tree = _buildTree(symbols);
    }
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
    final sharedCache = _treeQuery.isEmpty
        ? _symbolTreeCaches[widget.controller]
        : null;
    if (sharedCache != null &&
        setEquals(sharedCache.selectedSymbols, selected)) {
      _selectedSymbols = sharedCache.selectedSymbols;
      _selectedNodes = sharedCache.selectedNodes;
      return;
    }
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
    if (sharedCache != null) {
      sharedCache.selectedSymbols = _selectedSymbols;
      sharedCache.selectedNodes = _selectedNodes;
    }
  }

  void _selectNode(_SymbolTreeNode node) {
    final now = DateTime.now();
    final isDoubleTap =
        _lastTappedNodeKey == node.key &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 400);
    _lastTappedNodeKey = isDoubleTap ? null : node.key;
    _lastTapAt = isDoubleTap ? null : now;

    if (isDoubleTap &&
        node.kind == _SymbolTreeNodeKind.sourceFile &&
        node.sourcePath != null) {
      widget.controller.openSourceFile(
        widget.controller.canonicalSourcePath(node.sourcePath!),
      );
      widget.onShowSource?.call();
      return;
    }

    if (node.expandable) {
      final symbol = node.symbol;
      if (isDoubleTap && symbol != null) {
        _addSymbol(symbol.key);
      } else {
        _toggleNode(node);
      }
      return;
    }

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
      _addSymbol(symbol.key);
    }
  }

  void _addSymbol(String key) {
    widget.controller.selectSymbols([key]);
    widget.controller.addSelectedToWatch(
      mode: widget.defaultMonitor
          ? WatchReadMode.monitor
          : WatchReadMode.capture,
    );
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
                      height: TalUiTheme.of(context).controlHeight,
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
                  TalButton(
                    onPressed: widget.controller.isSymbolLoading
                        ? null
                        : widget.controller.chooseSymbolFile,
                    child: const Text('选择文件'),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    child: TalButton(
                      onPressed:
                          widget.controller.symbols.isEmpty ||
                              widget.controller.isSymbolLoading
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
                height: TalUiTheme.of(context).controlHeight,
                child: TextField(
                  key: const ValueKey('symbol-search-field'),
                  controller: search,
                  focusNode: _searchFocus,
                  onTap: _keepSearchFocusAfterWorkspaceReorder,
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
                  child: ResizableTableViewport(
                    layout: _tableLayout,
                    contentWidth: _tableWidth,
                    contentKey: const ValueKey('symbol-table-content'),
                    resizeRegionKey: const ValueKey(
                      'symbol-table-resize-region',
                    ),
                    minimumRowHeight: 18,
                    columnScale: 0.75,
                    rowScale: 0.75,
                    onLayoutChanged: () => setState(() {}),
                    header: _SymbolTableHeader(
                      nameWidth: _nameWidth,
                      addressWidth: _addressWidth,
                      sizeWidth: _sizeWidth,
                      sectionWidth: _sectionWidth,
                      typeWidth: _typeWidth,
                      onResizeColumn: _resizeColumn,
                    ),
                    body: _tree.isEmpty
                        ? const SizedBox.expand()
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, index) => _SymbolTreeRow(
                              entry: rows[index],
                              nameWidth: _nameWidth,
                              addressWidth: _addressWidth,
                              sizeWidth: _sizeWidth,
                              sectionWidth: _sectionWidth,
                              typeWidth: _typeWidth,
                              rowHeight: _rowHeight,
                              selected:
                                  _selectedNodes[rows[index].node.key] ?? false,
                              expanded: _isExpanded(rows[index].node),
                              onToggleNode: _toggleNode,
                              onSelectNode: _selectNode,
                              onFileContextMenu: _showFileContextMenu,
                            ),
                          ),
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
                    width: widget.defaultMonitor ? 116 : 160,
                    child: TalButton(
                      onPressed: widget.controller.selectedSymbols.isEmpty
                          ? null
                          : () => widget.controller.addSelectedToWatch(
                              mode: widget.defaultMonitor
                                  ? WatchReadMode.monitor
                                  : WatchReadMode.capture,
                            ),
                      child: Text(widget.defaultMonitor ? '加入监视' : '加入实时调参'),
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
  final ColumnResizeCallback onResizeColumn;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ResizableTableHeaderCell(
          label: '来源文件 / 变量',
          width: nameWidth,
          columnIndex: 0,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        ResizableTableHeaderCell(
          label: '地址',
          width: addressWidth,
          columnIndex: 1,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        ResizableTableHeaderCell(
          label: '大小',
          width: sizeWidth,
          columnIndex: 2,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        ResizableTableHeaderCell(
          label: '段',
          width: sectionWidth,
          columnIndex: 3,
          keyPrefix: 'symbol',
          onResize: onResizeColumn,
        ),
        ResizableTableHeaderCell(
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
    required this.onFileContextMenu,
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
  final void Function(_SymbolTreeNode, Offset) onFileContextMenu;

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

    final row = Material(
      key: ValueKey('symbol-tree-row-${node.key}'),
      color: rowColor,
      child: InkWell(
        onTap: () => onSelectNode(node),
        onSecondaryTapUp: node.kind == _SymbolTreeNodeKind.sourceFile
            ? (details) {
                if (details.kind != PointerDeviceKind.mouse) {
                  onFileContextMenu(node, details.globalPosition);
                }
              }
            : null,
        onLongPress: node.kind == _SymbolTreeNodeKind.sourceFile
            ? () {
                final box = context.findRenderObject()! as RenderBox;
                onFileContextMenu(
                  node,
                  box.localToGlobal(Offset(24, rowHeight)),
                );
              }
            : null,
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
    if (node.kind != _SymbolTreeNodeKind.sourceFile) return row;
    return Listener(
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse ||
            event.buttons & kSecondaryMouseButton == 0) {
          return;
        }
        RightDragResizeRegion.registerContextMenu(context, event.pointer, (
          position,
        ) {
          if (context.mounted) onFileContextMenu(node, position);
        });
      },
      child: node.sourcePath == null
          ? row
          : Draggable<SourceFileDragData>(
              data: SourceFileDragData(node.sourcePath!),
              allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
              maxSimultaneousDrags: 1,
              feedback: Material(
                color: TalColors.surfaceAlt,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.code, size: 16, color: TalColors.accent),
                      const SizedBox(width: 6),
                      Text(node.label, style: talStrong),
                    ],
                  ),
                ),
              ),
              child: row,
            ),
    );
  }
}
