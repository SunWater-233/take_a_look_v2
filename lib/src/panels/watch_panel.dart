part of 'panels.dart';

const _watchColumnLabels = <String>[
  '变量',
  '地址',
  '类型',
  '当前值',
  '写入值',
  '操作',
  '图标显示',
  '绘制颜色',
  '读取模式',
  '监视频率',
];

typedef _WatchRowContextMenuCallback =
    void Function(String key, _ContextMenuRequest request);

class _WatchPanel extends StatefulWidget {
  const _WatchPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_WatchPanel> createState() => _WatchPanelState();
}

class _WatchPanelState extends State<_WatchPanel> {
  static const _minimumColumnWidths = <double>[
    96,
    88,
    72,
    72,
    72,
    108,
    72,
    72,
    110,
    120,
  ];

  final ResizableTableLayout _tableLayout = ResizableTableLayout(
    widths: const [220, 112, 96, 96, 96, 116, 84, 96, 120, 140],
    minimumWidths: _minimumColumnWidths,
    rowHeight: 44,
  );
  final FocusNode _tableFocus = FocusNode(debugLabel: 'watch-table');
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final Set<String> _selectedWatchKeys = <String>{};
  final Set<String> _expandedWatchKeys = <String>{};
  final Set<int> _selectedColumns = <int>{};
  final Set<int> _hiddenColumns = <int>{};
  String? _selectionAnchorKey;
  int _appliedPlotWatchSelectionRevision = -1;

  TakeALookController get controller => widget.controller;
  List<double> get _columnWidths {
    final ui = TalUiTheme.of(context);
    if (!ui.touchOptimized) return _tableLayout.widths;
    return [
      for (final (index, width) in _tableLayout.widths.indexed)
        index == 5 ? math.max(width, ui.iconButtonSize * 3 + 10) : width,
    ];
  }

  double get _rowHeight =>
      math.max(_tableLayout.rowHeight, TalUiTheme.of(context).controlHeight);
  double get _tableWidth => _columnWidths.indexed
      .where((entry) => !_hiddenColumns.contains(entry.$1))
      .fold(0, (sum, entry) => sum + entry.$2);

  @override
  void didUpdateWidget(covariant _WatchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      _appliedPlotWatchSelectionRevision = -1;
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    _tableFocus.dispose();
    super.dispose();
  }

  void _resizeColumn(int index, double delta) {
    if (_tableLayout.resizeColumn(index, delta)) setState(() {});
  }

  void _normalizeSelection() {
    final available = controller.watches
        .map((watch) => watch.symbol.key)
        .toSet();
    _selectedWatchKeys.removeWhere((key) => !available.contains(key));
    _expandedWatchKeys.removeWhere((key) => !available.contains(key));
    if (!available.contains(_selectionAnchorKey)) _selectionAnchorKey = null;
  }

  void _applyPlotSelection(List<WatchTreeNode> roots) {
    final revision = controller.plotWatchSelectionRevision;
    if (_appliedPlotWatchSelectionRevision == revision) return;
    _appliedPlotWatchSelectionRevision = revision;
    final key = controller.plotHighlightedWatchKey;
    _selectedWatchKeys
      ..clear()
      ..addAll(key == null ? const <String>[] : [key]);
    _selectedColumns.clear();
    _selectionAnchorKey = key;
    if (key == null) return;

    bool expandAncestors(WatchTreeNode node) {
      if (node.watch.symbol.key == key) return true;
      for (final child in node.children) {
        if (expandAncestors(child)) {
          _expandedWatchKeys.add(node.watch.symbol.key);
          return true;
        }
      }
      return false;
    }

    Iterable<WatchItem> visibleWatches(WatchTreeNode node) sync* {
      yield node.watch;
      if (_expandedWatchKeys.contains(node.watch.symbol.key)) {
        for (final child in node.children) {
          yield* visibleWatches(child);
        }
      }
    }

    for (final root in roots) {
      if (expandAncestors(root)) break;
    }
    final index = roots
        .expand(visibleWatches)
        .toList()
        .indexWhere((watch) => watch.symbol.key == key);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          controller.plotWatchSelectionRevision != revision ||
          controller.plotHighlightedWatchKey != key ||
          !_verticalScrollController.hasClients) {
        return;
      }
      final position = _verticalScrollController.position;
      final top = index * _rowHeight;
      final bottom = top + _rowHeight;
      final target = top < position.pixels
          ? top
          : bottom > position.pixels + position.viewportDimension
          ? bottom - position.viewportDimension
          : position.pixels;
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((offset - position.pixels).abs() < 0.5) return;
      _verticalScrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _toggleWatchTreeNode(String key) {
    setState(() {
      if (!_expandedWatchKeys.add(key)) _expandedWatchKeys.remove(key);
    });
  }

  void _reorderWatchRoot(
    List<WatchTreeNode> roots,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 ||
        oldIndex >= roots.length ||
        newIndex < 0 ||
        newIndex >= roots.length) {
      return;
    }
    final watches = controller.watches;
    final oldWatchIndex = watches.indexOf(roots[oldIndex].watch);
    final newWatchIndex = watches.indexOf(roots[newIndex].watch);
    controller.reorderWatch(oldWatchIndex, newWatchIndex);
  }

  Widget _buildWatchTreeBranch(WatchTreeNode node, {required int depth}) {
    final watch = node.watch;
    final expanded = _expandedWatchKeys.contains(watch.symbol.key);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        WatchRowAnchor(
          controller: controller,
          watchKey: watch.symbol.key,
          child: _WatchRow(
            key: ValueKey<String>(watch.symbol.key),
            controller: controller,
            watch: watch,
            label: node.label,
            depth: depth,
            expandable: node.children.isNotEmpty,
            expanded: expanded,
            onToggleExpanded: () => _toggleWatchTreeNode(watch.symbol.key),
            columnWidths: _columnWidths,
            hiddenColumns: _hiddenColumns,
            selectedColumns: _selectedColumns,
            rowHeight: _rowHeight,
            selected: _selectedWatchKeys.contains(watch.symbol.key),
            onSelect: _selectWatch,
            onNameContextMenu: _showNameContextMenu,
            onPlotContextMenu: _showPlotContextMenu,
          ),
        ),
        if (expanded)
          for (final child in node.children)
            _buildWatchTreeBranch(child, depth: depth + 1),
      ],
    );
  }

  void _selectWatch(String key) {
    final keys = controller.watches.map((watch) => watch.symbol.key).toList();
    final index = keys.indexOf(key);
    if (index < 0) return;
    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;
    final ranged = keyboard.isShiftPressed && _selectionAnchorKey != null;
    setState(() {
      if (ranged) {
        final anchor = keys.indexOf(_selectionAnchorKey!);
        final start = math.min(anchor < 0 ? index : anchor, index);
        final end = math.max(anchor < 0 ? index : anchor, index);
        if (!additive) _selectedWatchKeys.clear();
        _selectedWatchKeys.addAll(keys.sublist(start, end + 1));
      } else if (additive) {
        if (!_selectedWatchKeys.add(key)) _selectedWatchKeys.remove(key);
        _selectionAnchorKey = key;
      } else {
        _selectedColumns.clear();
        _selectedWatchKeys
          ..clear()
          ..add(key);
        _selectionAnchorKey = key;
      }
    });
    if (_selectedWatchKeys.contains(key)) {
      controller.setPlotHighlightedWatch(key);
    }
    _tableFocus.requestFocus();
  }

  void _selectAllWatches() {
    final watches = controller.watches;
    setState(() {
      _selectedWatchKeys
        ..clear()
        ..addAll(watches.map((watch) => watch.symbol.key));
      _selectedColumns
        ..clear()
        ..addAll(List<int>.generate(_columnWidths.length, (index) => index));
      _selectionAnchorKey = watches.isEmpty ? null : watches.first.symbol.key;
    });
  }

  KeyEventResult _handleWatchShortcut(KeyEvent event) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (ModalRoute.of(context)?.isCurrent == false ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    if (WorkspaceShortcut.redoWatchDeletion.matches(event) &&
        controller.canRedoWatchDeletion) {
      controller.redoWatchDeletion();
      return KeyEventResult.handled;
    }
    if (WorkspaceShortcut.undoWatchDeletion.matches(event) &&
        controller.canUndoWatchDeletion) {
      controller.undoWatchDeletion();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        !event.synthesized &&
        event.logicalKey == LogicalKeyboardKey.delete &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        _selectedWatchKeys.isNotEmpty) {
      controller.removeWatches(_selectedWatchKeys);
      return KeyEventResult.handled;
    }
    if (!WorkspaceShortcut.selectAllWatches.matches(event)) {
      return KeyEventResult.ignored;
    }
    _selectAllWatches();
    _tableFocus.requestFocus();
    return KeyEventResult.handled;
  }

  List<String> _contextWatchKeys(String clickedKey) {
    if (!_selectedWatchKeys.contains(clickedKey)) {
      setState(() {
        _selectedWatchKeys
          ..clear()
          ..add(clickedKey);
        _selectionAnchorKey = clickedKey;
      });
    }
    controller.setPlotHighlightedWatch(clickedKey);
    _tableFocus.requestFocus();
    return [
      for (final watch in controller.watches)
        if (_selectedWatchKeys.contains(watch.symbol.key)) watch.symbol.key,
    ];
  }

  void _selectColumn(int index) {
    final additive = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (additive) {
        if (!_selectedColumns.add(index)) _selectedColumns.remove(index);
      } else {
        _selectedWatchKeys.clear();
        _selectedColumns
          ..clear()
          ..add(index);
      }
    });
    _tableFocus.requestFocus();
  }

  int? _columnAt(double x) {
    var left = 0.0;
    for (var index = 0; index < _columnWidths.length; index += 1) {
      if (_hiddenColumns.contains(index)) continue;
      final right = left + _columnWidths[index];
      if (x >= left && x < right) return index;
      left = right;
    }
    return null;
  }

  bool _canStartTableResize(Offset position) {
    final column = _columnAt(position.dx);
    return column != 0 && column != 6;
  }

  RelativeRect _menuPosition(Offset globalPosition) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);
    return RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
  }

  Future<void> _showHeaderContextMenu(
    int clickedColumn,
    _ContextMenuRequest request,
  ) async {
    final targetColumns = _selectedColumns.length > 1
        ? (_selectedColumns.toList()..sort())
        : <int>[clickedColumn];
    final visibleCount = _columnWidths.length - _hiddenColumns.length;
    final canHide =
        visibleCount > 1 &&
        targetColumns.any((column) => !_hiddenColumns.contains(column));
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'hide',
          icon: Icons.visibility_off_outlined,
          label: targetColumns.length == 1
              ? '隐藏该列'
              : '隐藏所选列（${targetColumns.length}）',
          enabled: canHide,
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'showAll',
          icon: Icons.view_column_outlined,
          label: '显示全列',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    setState(() {
      if (action == 'showAll') {
        _hiddenColumns.clear();
        return;
      }
      for (final column in targetColumns) {
        if (_columnWidths.length - _hiddenColumns.length <= 1) break;
        _hiddenColumns.add(column);
      }
    });
  }

  Future<void> _showNameContextMenu(
    String clickedKey,
    _ContextMenuRequest request,
  ) async {
    final keys = _contextWatchKeys(clickedKey);
    if (keys.isEmpty) return;
    final count = keys.length;
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'remove',
          icon: Icons.close,
          label: count == 1 ? '移除该变量' : '移除所选变量（$count）',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'undo',
          icon: Icons.undo,
          label: '撤回删除',
          enabled: controller.canUndoWatchDeletion,
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'redo',
          icon: Icons.redo,
          label: '重做删除 (Ctrl+Y)',
          enabled: controller.canRedoWatchDeletion,
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'copy',
          icon: Icons.copy_outlined,
          label: count == 1 ? '复制命令名' : '复制所选命令名（$count）',
          touchOptimized: request.touchOptimized,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          value: 'only',
          icon: Icons.filter_alt_outlined,
          label: count == 1 ? '仅显示该栏' : '仅显示所选变量（$count）',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'all',
          icon: Icons.visibility_outlined,
          label: '全部显示',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'none',
          icon: Icons.visibility_off_outlined,
          label: '全部隐藏',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'invert',
          icon: Icons.swap_vert,
          label: '反转所选变量图表显示状态',
          touchOptimized: request.touchOptimized,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          value: 'color',
          icon: Icons.palette_outlined,
          label: count == 1 ? '设置曲线颜色' : '为所选变量设置曲线颜色（$count）',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'remove':
        _selectedWatchKeys.removeAll(keys);
        controller.removeWatches(keys);
      case 'undo':
        controller.undoWatchDeletion();
      case 'redo':
        controller.redoWatchDeletion();
      case 'copy':
        final names = [
          for (final watch in controller.watches)
            if (keys.contains(watch.symbol.key)) watch.symbol.name,
        ];
        await Clipboard.setData(ClipboardData(text: names.join('\n')));
      case 'only':
        controller.setOnlyWatchesPlotted(keys);
      case 'all':
        controller.setAllWatchesPlotted(true);
      case 'none':
        controller.setAllWatchesPlotted(false);
      case 'invert':
        controller.invertWatchPlots(keys);
      case 'color':
        final initial = controller.watches
            .firstWhere((watch) => keys.contains(watch.symbol.key))
            .color;
        final color = await showTalDialog<Color>(
          context: context,
          builder: (context) => WatchColorDialog(initialColor: initial),
        );
        if (mounted && color != null) controller.setWatchColors(keys, color);
    }
  }

  Future<void> _showPlotContextMenu(
    String clickedKey,
    _ContextMenuRequest request,
  ) async {
    final keys = _contextWatchKeys(clickedKey);
    if (keys.isEmpty) return;
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'only',
          icon: Icons.filter_alt_outlined,
          label: '仅显示该栏',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'all',
          icon: Icons.visibility_outlined,
          label: '全部显示',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'only') controller.setOnlyWatchesPlotted(keys);
    if (action == 'all') controller.setAllWatchesPlotted(true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.watchChanges,
      builder: (context, _) {
        _normalizeSelection();
        final treeRoots = buildWatchTree(controller.watches);
        _applyPlotSelection(treeRoots);
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Expanded(
                child: PanelKeyboardListener(
                  focusNode: _tableFocus,
                  onKeyEvent: _handleWatchShortcut,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return _ResizableTableViewport(
                        layout: _tableLayout,
                        contentWidth: _tableWidth,
                        horizontalController: _horizontalScrollController,
                        contentKey: const ValueKey('watch-table-content'),
                        resizeRegionKey: const ValueKey(
                          'watch-table-resize-region',
                        ),
                        minimumRowHeight: 40,
                        canStartResizeAt: _canStartTableResize,
                        onLayoutChanged: () => setState(() {}),
                        bodyDecoration: const BoxDecoration(
                          color: TalColors.input,
                          border: Border(
                            left: BorderSide(color: TalColors.border),
                            right: BorderSide(color: TalColors.border),
                            bottom: BorderSide(color: TalColors.border),
                          ),
                        ),
                        header: _WatchTableHeader(
                          columnWidths: _columnWidths,
                          hiddenColumns: _hiddenColumns,
                          selectedColumns: _selectedColumns,
                          onResizeColumn: _resizeColumn,
                          onSelectColumn: _selectColumn,
                          onContextMenu: _showHeaderContextMenu,
                        ),
                        body: treeRoots.isEmpty
                            ? const SizedBox.expand()
                            : ReorderableListView.builder(
                                scrollController: _verticalScrollController,
                                buildDefaultDragHandles: false,
                                proxyDecorator: (child, index, animation) {
                                  final horizontalOffset =
                                      _horizontalScrollController.hasClients
                                      ? _horizontalScrollController.offset
                                      : 0.0;
                                  return ClipRect(
                                    key: const ValueKey('watch-drag-proxy'),
                                    clipper: _WatchDragProxyClipper(
                                      left: horizontalOffset,
                                      width: constraints.maxWidth,
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: child,
                                    ),
                                  );
                                },
                                itemCount: treeRoots.length,
                                onReorderItem: (oldIndex, newIndex) =>
                                    _reorderWatchRoot(
                                      treeRoots,
                                      oldIndex,
                                      newIndex,
                                    ),
                                itemBuilder: (context, index) {
                                  final node = treeRoots[index];
                                  return ReorderableDelayedDragStartListener(
                                    key: ValueKey<String>(
                                      'watch-reorder-${node.watch.symbol.key}',
                                    ),
                                    index: index,
                                    child: _buildWatchTreeBranch(
                                      node,
                                      depth: 0,
                                    ),
                                  );
                                },
                              ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '展开结构体或数组查看成员；读取模式控制采集，眼睛控制曲线显示。监视频率可按变量覆盖默认值。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: talMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TalButton(
                    onPressed: controller.watches.isEmpty
                        ? null
                        : controller.clearWatches,
                    child: const Text('清空监视'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatchDragProxyClipper extends CustomClipper<Rect> {
  const _WatchDragProxyClipper({required this.left, required this.width});

  final double left;
  final double width;

  @override
  Rect getClip(Size size) {
    final clipLeft = left.clamp(0.0, size.width);
    final clipRight = (clipLeft + width).clamp(clipLeft, size.width);
    return Rect.fromLTRB(clipLeft, 0, clipRight, size.height);
  }

  @override
  bool shouldReclip(covariant _WatchDragProxyClipper oldClipper) {
    return oldClipper.left != left || oldClipper.width != width;
  }
}

class _WatchTableHeader extends StatelessWidget {
  const _WatchTableHeader({
    required this.columnWidths,
    required this.hiddenColumns,
    required this.selectedColumns,
    required this.onResizeColumn,
    required this.onSelectColumn,
    required this.onContextMenu,
  });

  final List<double> columnWidths;
  final Set<int> hiddenColumns;
  final Set<int> selectedColumns;
  final _ColumnResizeCallback onResizeColumn;
  final ValueChanged<int> onSelectColumn;
  final _ColumnContextMenuCallback onContextMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TalUiTheme.of(context).targetExtent(36),
      decoration: const BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border.symmetric(
          horizontal: BorderSide(color: TalColors.border),
        ),
      ),
      child: Row(
        children: [
          for (final (index, label) in _watchColumnLabels.indexed)
            if (!hiddenColumns.contains(index))
              _ResizableTableHeaderCell(
                label: label,
                width: columnWidths[index],
                columnIndex: index,
                keyPrefix: 'watch',
                onResize: onResizeColumn,
                selected: selectedColumns.contains(index),
                onSelect: onSelectColumn,
                onContextMenu: onContextMenu,
              ),
        ],
      ),
    );
  }
}

class _WatchRow extends StatefulWidget {
  const _WatchRow({
    required this.controller,
    required this.watch,
    required this.label,
    required this.depth,
    required this.expandable,
    required this.expanded,
    required this.onToggleExpanded,
    required this.columnWidths,
    required this.hiddenColumns,
    required this.selectedColumns,
    required this.rowHeight,
    required this.selected,
    required this.onSelect,
    required this.onNameContextMenu,
    required this.onPlotContextMenu,
    super.key,
  });

  final TakeALookController controller;
  final WatchItem watch;
  final String label;
  final int depth;
  final bool expandable;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final List<double> columnWidths;
  final Set<int> hiddenColumns;
  final Set<int> selectedColumns;
  final double rowHeight;
  final bool selected;
  final ValueChanged<String> onSelect;
  final _WatchRowContextMenuCallback onNameContextMenu;
  final _WatchRowContextMenuCallback onPlotContextMenu;

  @override
  State<_WatchRow> createState() => _WatchRowState();
}

class _WatchRowState extends State<_WatchRow> {
  late final TextEditingController editor;

  @override
  void initState() {
    super.initState();
    editor = TextEditingController(
      text:
          widget.controller.watchInputDrafts[widget.watch.symbol.key] ??
          widget.watch.valueLabel,
    );
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> _chooseColor() async {
    final color = await showTalDialog<Color>(
      context: context,
      builder: (context) => WatchColorDialog(initialColor: widget.watch.color),
    );
    if (!mounted || color == null) return;
    widget.controller.setWatchColor(widget.watch.symbol.key, color);
  }

  @override
  Widget build(BuildContext context) {
    final watch = widget.watch;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kPrimaryMouseButton != 0) {
          widget.onSelect(watch.symbol.key);
        }
      },
      child: Container(
        key: ValueKey('watch-row-${watch.symbol.key}'),
        height: math.max(
          widget.rowHeight,
          TalUiTheme.of(context).controlHeight,
        ),
        decoration: BoxDecoration(
          color: widget.selected ? TalColors.selection : TalColors.input,
          border: const Border(bottom: BorderSide(color: TalColors.borderSoft)),
        ),
        child: Row(
          children: [
            if (!widget.hiddenColumns.contains(0))
              _WatchCell(
                width: widget.columnWidths[0],
                selected: widget.selectedColumns.contains(0),
                onContextMenu: (request) =>
                    widget.onNameContextMenu(watch.symbol.key, request),
                padding: EdgeInsets.only(
                  left: 6 + widget.depth * 18.0,
                  right: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: TalUiTheme.of(context).targetExtent(22),
                      child: widget.expandable
                          ? TalIconButton(
                              key: ValueKey(
                                'watch-tree-toggle-${watch.symbol.key}',
                              ),
                              tooltip: widget.expanded ? '收起' : '展开',
                              onPressed: widget.onToggleExpanded,
                              icon: Icon(
                                widget.expanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                                size: 18,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    const Icon(
                      Icons.data_object,
                      size: 15,
                      color: TalColors.accent,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Tooltip(
                        message: watch.symbol.name,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: talBody,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (!widget.hiddenColumns.contains(1))
              _WatchCell(
                width: widget.columnWidths[1],
                selected: widget.selectedColumns.contains(1),
                child: Text(watch.symbol.addressLabel, style: talMono),
              ),
            if (!widget.hiddenColumns.contains(2))
              _WatchCell(
                width: widget.columnWidths[2],
                selected: widget.selectedColumns.contains(2),
                child: Text(watch.symbol.type, style: talMuted),
              ),
            if (!widget.hiddenColumns.contains(3))
              _WatchCell(
                width: widget.columnWidths[3],
                selected: widget.selectedColumns.contains(3),
                child: AnimatedBuilder(
                  animation: widget.controller.telemetryChanges,
                  builder: (context, _) => Text(
                    widget.expandable ? '展开查看' : widget.watch.valueLabel,
                    style: talMono,
                  ),
                ),
              ),
            if (!widget.hiddenColumns.contains(4))
              _WatchCell(
                width: widget.columnWidths[4],
                selected: widget.selectedColumns.contains(4),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: widget.expandable
                    ? const Center(child: Text('—', style: talMuted))
                    : SizedBox(
                        height: TalUiTheme.of(context).targetExtent(30),
                        child: TextField(
                          controller: editor,
                          onChanged: (value) =>
                              widget.controller.watchInputDrafts[watch
                                      .symbol
                                      .key] =
                                  value,
                          enabled:
                              watch.symbol.writable &&
                              widget.controller.supportsMemoryWrite,
                          style: talMono,
                        ),
                      ),
              ),
            if (!widget.hiddenColumns.contains(5))
              _WatchCell(
                width: widget.columnWidths[5],
                selected: widget.selectedColumns.contains(5),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.expandable)
                      TalIconButton(
                        key: ValueKey('watch-remove-${watch.symbol.key}'),
                        tooltip: '移除变量组',
                        onPressed: () =>
                            widget.controller.removeWatch(watch.symbol.key),
                        icon: const Icon(Icons.close, size: 16),
                      )
                    else ...[
                      TalIconButton(
                        key: ValueKey('watch-edit-${watch.symbol.key}'),
                        tooltip: '写入当前输入值',
                        onPressed:
                            watch.symbol.writable &&
                                widget.controller.supportsMemoryWrite
                            ? () => widget.controller.writeWatch(
                                watch.symbol.key,
                                editor.text,
                              )
                            : null,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                      ),
                      TalIconButton(
                        key: ValueKey('watch-read-${watch.symbol.key}'),
                        tooltip: '立即读取',
                        onPressed:
                            widget.controller.connectionStatus ==
                                ConnectionStatus.connected
                            ? () =>
                                  widget.controller.readWatch(watch.symbol.key)
                            : null,
                        icon: const Icon(Icons.refresh, size: 16),
                      ),
                    ],
                  ],
                ),
              ),
            if (!widget.hiddenColumns.contains(6))
              _WatchCell(
                width: widget.columnWidths[6],
                selected: widget.selectedColumns.contains(6),
                padding: EdgeInsets.zero,
                onContextMenu: (request) =>
                    widget.onPlotContextMenu(watch.symbol.key, request),
                child: Center(
                  child: TalIconButton(
                    key: ValueKey('watch-visibility-${watch.symbol.key}'),
                    tooltip: watch.plotted ? '在图表中隐藏' : '在图表中显示',
                    onPressed: watch.samplingEnabled
                        ? () => widget.controller.toggleWatchPlot(
                            watch.symbol.key,
                            !watch.plotted,
                          )
                        : null,
                    icon: Icon(
                      watch.plotted
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 17,
                      color: watch.plotted ? TalColors.accent : TalColors.muted,
                    ),
                  ),
                ),
              ),
            if (!widget.hiddenColumns.contains(7))
              _WatchCell(
                width: widget.columnWidths[7],
                selected: widget.selectedColumns.contains(7),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: watchColorHex(watch.color),
                    child: Material(
                      color: watch.color,
                      borderRadius: BorderRadius.circular(3),
                      child: InkWell(
                        key: ValueKey('watch-color-${watch.symbol.key}'),
                        onTap: _chooseColor,
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          width: 36,
                          height: 18,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: TalColors.border),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (!widget.hiddenColumns.contains(8))
              _WatchCell(
                width: widget.columnWidths[8],
                selected: widget.selectedColumns.contains(8),
                child: widget.expandable
                    ? const Text('—', style: talMuted)
                    : TalDropdown<WatchReadMode>(
                        key: ValueKey('watch-table-mode-${watch.symbol.key}'),
                        value: watch.readMode,
                        values: WatchReadMode.values,
                        label: (mode) => mode.label,
                        onChanged: (mode) => widget.controller.setWatchReadMode(
                          watch.symbol.key,
                          mode,
                        ),
                      ),
              ),
            if (!widget.hiddenColumns.contains(9))
              _WatchCell(
                width: widget.columnWidths[9],
                selected: widget.selectedColumns.contains(9),
                child:
                    widget.expandable || watch.readMode != WatchReadMode.monitor
                    ? const Text('—', style: talMuted)
                    : widget.controller.usesDevicePush(watch)
                    ? const Text('设备推送', style: talMuted)
                    : TalDropdown<double>(
                        value: watch.monitorRateHz ?? 0,
                        values: {
                          ...[0.0, 0.5, 1.0, 2.0, 5.0, 10.0],
                          if (watch.monitorRateHz != null) watch.monitorRateHz!,
                        }.toList()..sort(),
                        label: (rate) => rate == 0
                            ? '默认 ${formatReadRate(widget.controller.monitorRateHz)}'
                            : formatReadRate(rate),
                        onChanged: (rate) =>
                            widget.controller.setWatchMonitorRate(
                              watch.symbol.key,
                              rate == 0 ? null : rate,
                            ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

PopupMenuEntry<String> _watchPopupItem({
  required String value,
  required IconData icon,
  required String label,
  bool enabled = true,
  required bool touchOptimized,
}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: TalUiTheme.forTouch(touchOptimized).menuItemHeight,
    child: Row(
      children: [Icon(icon, size: 17), const SizedBox(width: 9), Text(label)],
    ),
  );
}

class _WatchCell extends StatelessWidget {
  const _WatchCell({
    required this.width,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.onContextMenu,
    this.selected = false,
  });

  final double width;
  final Widget child;
  final EdgeInsets padding;
  final ValueChanged<_ContextMenuRequest>? onContextMenu;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cell = Container(
      width: width,
      padding: padding,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: selected ? TalColors.selection : Colors.transparent,
        border: const Border(right: BorderSide(color: TalColors.borderSoft)),
      ),
      child: child,
    );
    final callback = onContextMenu;
    if (callback == null) return cell;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => callback(
        _ContextMenuRequest(
          globalPosition: details.globalPosition,
          touchOptimized: false,
        ),
      ),
      child: cell,
    );
  }
}
