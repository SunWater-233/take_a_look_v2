part of 'panels.dart';

class _WatchBrowserEntry {
  const _WatchBrowserEntry({
    required this.key,
    required this.label,
    required this.depth,
    this.node,
    this.members = const [],
    this.pinned = false,
  });
  final String key, label;
  final int depth;
  final WatchTreeNode? node;
  final List<WatchTreeNode> members;
  final bool pinned;
  bool get expandable => members.isNotEmpty;
}

class _CompactWatchPanel extends StatefulWidget {
  const _CompactWatchPanel({
    required this.controller,
    this.onShowSymbols,
    this.visible = true,
  });
  final TakeALookController controller;
  final VoidCallback? onShowSymbols;
  final bool visible;
  @override
  State<_CompactWatchPanel> createState() => _CompactWatchPanelState();
}

class _CompactWatchPanelState extends State<_CompactWatchPanel> {
  final _panelFocus = FocusNode(debugLabel: 'watch-browser');
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Set<String> get _rangeExpansions => controller.compactExpandedWatches;
  late final String _scope =
      'watch-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  int _plotRevision = -1;
  double? _valueColumnWidth;
  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _search.text = controller.watchSearchQuery;
  }

  @override
  void didUpdateWidget(covariant _CompactWatchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.setWatchMonitorScope(_scope, null);
      _search.text = controller.watchSearchQuery;
      _plotRevision = -1;
    }
  }

  @override
  void dispose() {
    controller.setWatchMonitorScope(_scope, null);
    _panelFocus.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _select(String key) {
    setState(() => controller.compactWatchSelection = key);
    controller.setPlotHighlightedWatch(key);
  }

  void _toggle(_WatchBrowserEntry entry) {
    if (entry.node != null) _select(entry.key);
    setState(() {
      final expanded = entry.node == null
          ? _rangeExpansions
          : controller.compactExpandedWatches;
      if (!expanded.add(entry.key)) expanded.remove(entry.key);
    });
    _panelFocus.requestFocus();
  }

  KeyEventResult _shortcut(KeyEvent event) {
    if (!widget.visible ||
        ModalRoute.of(context)?.isCurrent == false ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return KeyEventResult.ignored;
    }
    if (WorkspaceShortcut.undoWatchDeletion.matches(event)) {
      controller.undoWatchDeletion();
      return KeyEventResult.handled;
    }
    if (WorkspaceShortcut.redoWatchDeletion.matches(event)) {
      controller.redoWatchDeletion();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.delete &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        controller.compactWatchSelection != null) {
      controller.removeWatch(controller.compactWatchSelection!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _syncSelection(List<WatchTreeNode> roots) {
    final keys = controller.watches.map((w) => w.symbol.key).toSet();
    if (!keys.contains(controller.compactWatchSelection)) {
      controller.compactWatchSelection =
          controller.watches.firstOrNull?.symbol.key;
    }
    if (_plotRevision == controller.plotWatchSelectionRevision) return;
    _plotRevision = controller.plotWatchSelectionRevision;
    final key = controller.plotHighlightedWatchKey;
    if (key == null || !keys.contains(key)) return;
    controller.compactWatchSelection = key;
    // A curve selection reveals its source, including an array's range group.
    bool reveal(WatchTreeNode node) {
      if (node.watch.symbol.key == key) return true;
      for (var i = 0; i < node.children.length; i++) {
        if (reveal(node.children[i])) {
          controller.compactExpandedWatches.add(node.watch.symbol.key);
          _rangeExpansions.add('${node.watch.symbol.key}:range:${i ~/ 32}');
          return true;
        }
      }
      return false;
    }

    for (final root in roots) {
      if (reveal(root)) break;
    }
  }

  List<_WatchBrowserEntry> _rows(List<WatchTreeNode> roots) {
    final query = _search.text.trim().toLowerCase();
    final matches = <String, bool>{};
    bool match(WatchTreeNode n) => matches.putIfAbsent(
      n.watch.symbol.key,
      () =>
          n.watch.symbol.name.toLowerCase().contains(query) ||
          n.children.any(match),
    );
    final rows = <_WatchBrowserEntry>[];
    void visit(WatchTreeNode n, int depth) {
      if (query.isNotEmpty && !match(n)) return;
      rows.add(
        _WatchBrowserEntry(
          key: n.watch.symbol.key,
          label: n.label,
          depth: depth,
          node: n,
          members: n.children,
        ),
      );
      if (n.children.isEmpty ||
          (query.isEmpty &&
              !controller.compactExpandedWatches.contains(
                n.watch.symbol.key,
              ))) {
        return;
      }
      final grouped =
          query.isEmpty &&
          n.children.length > 64 &&
          n.children.every((child) => child.label.startsWith('['));
      if (!grouped) {
        for (final child in n.children) {
          visit(child, depth + 1);
        }
        return;
      }
      for (var start = 0; start < n.children.length; start += 32) {
        final members = n.children.sublist(
          start,
          math.min(start + 32, n.children.length),
        );
        final key = '${n.watch.symbol.key}:range:${start ~/ 32}';
        rows.add(
          _WatchBrowserEntry(
            key: key,
            label: '${members.first.label}…${members.last.label}',
            depth: depth + 1,
            members: members,
          ),
        );
        if (_rangeExpansions.contains(key)) {
          for (final child in members) {
            visit(child, depth + 2);
          }
        }
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return rows;
  }

  Future<void> _adjustColor(WatchItem watch) async {
    _select(watch.symbol.key);
    _panelFocus.requestFocus();
    final color = await showTalDialog<Color>(
      context: context,
      builder: (_) => WatchColorDialog(initialColor: watch.color),
    );
    if (mounted && color != null) {
      controller.setWatchColor(watch.symbol.key, color);
    }
  }

  Future<void> _menu(WatchItem watch, Offset position) async {
    _select(watch.symbol.key);
    _panelFocus.requestFocus();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showTalContextMenu<String>(
      context: context,
      position: RelativeRect.fromSize(
        overlay.globalToLocal(position) & Size.zero,
        overlay.size,
      ),
      items: [
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'pin',
          icon: Icons.push_pin_outlined,
          label: watch.pinned ? '取消固定' : '固定成员',
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'color',
          icon: Icons.palette_outlined,
          label: '颜色调整',
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'visibility',
          icon: Icons.show_chart,
          label: watch.plotted ? '隐藏曲线' : '显示曲线',
          enabled: watch.samplingEnabled,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'delete',
          icon: Icons.delete_outline,
          label: '删除变量',
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'undo',
          icon: Icons.undo,
          label: '撤回删除',
          enabled: controller.canUndoWatchDeletion,
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'redo',
          icon: Icons.redo,
          label: '重做删除 (Ctrl+Y)',
          enabled: controller.canRedoWatchDeletion,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'pin':
        controller.setWatchPinned(watch.symbol.key, !watch.pinned);
      case 'visibility':
        controller.toggleWatchPlot(watch.symbol.key, !watch.plotted);
      case 'delete':
        controller.removeWatch(watch.symbol.key);
      case 'undo':
        controller.undoWatchDeletion();
      case 'redo':
        controller.redoWatchDeletion();
      case 'color':
        await _adjustColor(watch);
    }
  }

  Widget _row(_WatchBrowserEntry entry, bool wide, double valueWidth) {
    final node = entry.node, watch = node?.watch;
    final selected =
        watch != null && controller.compactWatchSelection == entry.key;
    final ui = TalUiTheme.of(context);
    final height = ui.targetExtent(32);
    final expanded =
        _search.text.trim().isNotEmpty ||
        (node == null
            ? _rangeExpansions.contains(entry.key)
            : controller.compactExpandedWatches.contains(entry.key));
    void activate() {
      if (entry.expandable) {
        _toggle(entry);
      } else {
        _select(entry.key);
        _panelFocus.requestFocus();
      }
    }

    final content = InkWell(
      onTap: activate,
      onSecondaryTapUp: watch == null
          ? null
          : (d) => _menu(watch, d.globalPosition),
      onLongPress: watch == null
          ? null
          : () {
              final box = context.findRenderObject()! as RenderBox;
              _menu(watch, box.localToGlobal(box.size.center(Offset.zero)));
            },
      child: Container(
        height: height,
        padding: const EdgeInsets.only(right: 5),
        decoration: BoxDecoration(
          color: selected ? TalColors.selection : null,
          border: Border(
            left: BorderSide(
              width: 2,
              color: selected ? TalColors.accent : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 25 + math.min(entry.depth, 8) * 12.0,
              height: height,
              child: entry.expandable
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 16,
                        color: TalColors.muted,
                      ),
                    )
                  : watch != null && watch.samplingEnabled && watch.plotted
                  ? Tooltip(
                      message: '双击调整绘制颜色',
                      triggerMode: TooltipTriggerMode.manual,
                      child: GestureDetector(
                        key: ValueKey(
                          'compact-watch-color-${entry.pinned ? 'pinned-' : ''}${entry.key}',
                        ),
                        behavior: HitTestBehavior.opaque,
                        onTap: activate,
                        onDoubleTap: () => _adjustColor(watch),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 3,
                              height: height - 12,
                              child: DecoratedBox(
                                key: ValueKey(
                                  'compact-watch-color-bar-${entry.pinned ? 'pinned-' : ''}${entry.key}',
                                ),
                                decoration: BoxDecoration(
                                  color: watch.color,
                                  borderRadius: BorderRadius.circular(1.5),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: Tooltip(
                triggerMode: TooltipTriggerMode.manual,
                message: watch?.symbol.name ?? entry.label,
                child: Text(
                  entry.label,
                  style: talMono.copyWith(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (wide)
              SizedBox(
                width: 88,
                child: Text(
                  watch?.symbol.type ?? '',
                  style: workbenchMuted.copyWith(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(width: 12),
            SizedBox(
              width: valueWidth,
              child: entry.expandable && wide
                  ? const SizedBox.shrink()
                  : entry.expandable
                  ? Text(
                      watch?.symbol.type ?? '${entry.members.length} 项',
                      style: workbenchMuted.copyWith(fontSize: 11),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : _WatchValueCell(
                      key: ValueKey(
                        '${entry.pinned ? 'pinned' : 'compact'}-watch-cell-${entry.key}',
                      ),
                      controller: controller,
                      watch: watch!,
                      pinned: entry.pinned,
                      onSelect: () => _select(entry.key),
                    ),
            ),
            if (entry.expandable)
              SizedBox(
                width: ui.compactIconButtonSize * 2,
                child: Text(
                  '${entry.members.length} 项',
                  textAlign: TextAlign.right,
                  style: workbenchMuted.copyWith(fontSize: 11),
                ),
              )
            else ...[
              _rowIcon(
                ui,
                '固定',
                watch!.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                'watch-pin-${entry.pinned ? 'pinned-' : ''}${entry.key}',
                watch.pinned,
                () => controller.setWatchPinned(entry.key, !watch.pinned),
              ),
              _rowIcon(
                ui,
                watch.plotted ? '隐藏曲线' : '加入曲线',
                Icons.show_chart,
                'compact-watch-plot-${entry.pinned ? 'pinned-' : ''}${entry.key}',
                watch.plotted,
                () {
                  if (!watch.samplingEnabled) {
                    controller.setWatchReadMode(
                      entry.key,
                      WatchReadMode.capture,
                    );
                  } else {
                    controller.toggleWatchPlot(entry.key, !watch.plotted);
                  }
                },
                color: watch.plotted ? watch.color : null,
              ),
            ],
          ],
        ),
      ),
    );
    return watch == null
        ? content
        : WatchRowAnchor(
            key: ValueKey(
              '${entry.pinned ? 'pinned' : 'compact'}-watch-${entry.key}',
            ),
            controller: controller,
            watchKey: entry.key,
            child: content,
          );
  }

  Widget _rowIcon(
    TalUiTheme ui,
    String label,
    IconData icon,
    String key,
    bool active,
    VoidCallback onPressed, {
    Color? color,
  }) => SizedBox.square(
    dimension: ui.compactIconButtonSize,
    child: TalIconButton(
      key: ValueKey(key),
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.square(ui.compactIconButtonSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        icon,
        size: 15,
        color: color ?? (active ? TalColors.accent : TalColors.muted),
      ),
    ),
  );

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(9, 5, 5, 5),
    child: Row(
      children: [
        const Flexible(
          child: Text(
            '监视默认',
            style: workbenchMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 7),
        SizedBox(
          width: TalUiTheme.of(context).touchOptimized ? 110 : 96,
          child: TalDropdown<double>(
            key: const ValueKey('watch-default-monitor-rate'),
            value: controller.monitorRateHz,
            values: const [.5, 1, 2, 5, 10],
            label: formatReadRate,
            onChanged: controller.setMonitorRate,
          ),
        ),
        const Spacer(),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.watchChanges,
      controller.samplingChanges,
      controller.connectionChanges,
    ]),
    builder: (_, _) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 48) return const SizedBox.shrink();
        final roots = buildWatchTree(controller.watches);
        _syncSelection(roots);
        final rows = _rows(roots);
        final selected = controller.watches
            .where((w) => w.symbol.key == controller.compactWatchSelection)
            .firstOrNull;
        final allNodes = <String, WatchTreeNode>{};
        void collect(WatchTreeNode node) {
          allNodes[node.watch.symbol.key] = node;
          for (final c in node.children) {
            collect(c);
          }
        }

        for (final root in roots) {
          collect(root);
        }
        final pinned = controller.watches
            .where((w) => w.pinned && allNodes[w.symbol.key]!.children.isEmpty)
            .toList();
        final visible = <String>{
          for (final row in rows)
            if (row.node != null && !row.expandable) row.key,
          for (final w in pinned) w.symbol.key,
          if (selected != null &&
              allNodes[selected.symbol.key]!.children.isEmpty)
            selected.symbol.key,
        };
        final owner = controller;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && owner == controller) {
            owner.setWatchMonitorScope(
              _scope,
              widget.visible ? visible : <String>{},
            );
          }
        });
        final wide = constraints.maxWidth >= 760;
        final listWidth = constraints.maxWidth - (wide ? 310 : 0);
        final maxDepth = rows.fold<int>(
          0,
          (depth, row) => math.max(depth, row.depth),
        );
        final maxValueWidth = math.max(
          64.0,
          listWidth -
              TalUiTheme.of(context).compactIconButtonSize * 2 -
              (wide ? 192 : 104) -
              math.min(maxDepth, 8) * 12,
        );
        final valueWidth = (_valueColumnWidth ?? (wide ? 112.0 : 88.0)).clamp(
          64.0,
          maxValueWidth,
        );
        final list = ListView(
          controller: _scroll,
          key: const ValueKey('compact-watch-list'),
          children: [
            if (pinned.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.push_pin_outlined,
                      size: 13,
                      color: TalColors.muted,
                    ),
                    SizedBox(width: 5),
                    Text('已固定', style: workbenchMuted),
                    Spacer(),
                    Text('折叠后仍刷新', style: workbenchMuted),
                  ],
                ),
              ),
              for (final w in pinned)
                _row(
                  _WatchBrowserEntry(
                    key: w.symbol.key,
                    label: w.symbol.name,
                    depth: 0,
                    node: allNodes[w.symbol.key],
                    pinned: true,
                  ),
                  wide,
                  valueWidth,
                ),
              const Divider(height: 12, color: TalColors.borderSoft),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
              child: Row(
                children: [
                  Text(
                    _search.text.trim().isEmpty ? '成员' : '搜索结果',
                    style: workbenchMuted,
                  ),
                  const Spacer(),
                  Tooltip(
                    message: '左右拖动调整当前值列宽',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        key: const ValueKey('watch-value-column-resize'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) => setState(() {
                          _valueColumnWidth = (valueWidth - details.delta.dx)
                              .clamp(64.0, maxValueWidth);
                        }),
                        child: const SizedBox(
                          width: 12,
                          height: 24,
                          child: Center(
                            child: SizedBox(
                              width: 1,
                              height: 14,
                              child: ColoredBox(color: TalColors.border),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: valueWidth,
                    child: const Text(
                      '当前值',
                      style: workbenchMuted,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: TalUiTheme.of(context).compactIconButtonSize * 2,
                  ),
                ],
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      controller.watches.isEmpty ? '从符号变量加入变量' : '没有匹配的成员',
                      style: workbenchMuted,
                    ),
                    if (_search.text.isNotEmpty)
                      TalButton(
                        onPressed: () => setState(() {
                          _search.clear();
                          controller.watchSearchQuery = '';
                        }),
                        child: const Text('清空搜索'),
                      ),
                    if (controller.watches.isEmpty &&
                        widget.onShowSymbols != null)
                      TalButton(
                        onPressed: widget.onShowSymbols,
                        child: const Text('打开符号变量'),
                      ),
                  ],
                ),
              ),
            for (final row in rows) _row(row, wide, valueWidth),
          ],
        );
        final details = selected == null
            ? const SizedBox.shrink()
            : _WatchMemberDetails(
                key: ValueKey('watch-details-${selected.symbol.key}'),
                controller: controller,
                watch: selected,
                node: allNodes[selected.symbol.key]!,
              );
        return PanelKeyboardListener(
          focusNode: _panelFocus,
          onKeyEvent: _shortcut,
          child: Material(
            color: TalColors.surface,
            child: Column(
              children: [
                if (constraints.maxHeight > 130) _toolbar(),
                if (constraints.maxHeight > 210)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                    child: TextField(
                      key: const ValueKey('watch-member-search'),
                      controller: _search,
                      style: workbenchBody,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 17),
                        hintText: '搜索成员名称或路径，如 current.q',
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : TalIconButton(
                                tooltip: '清空搜索',
                                onPressed: () => setState(() {
                                  _search.clear();
                                  controller.watchSearchQuery = '';
                                }),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                      ),
                      onChanged: (value) =>
                          setState(() => controller.watchSearchQuery = value),
                    ),
                  ),
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: list),
                            SizedBox(
                              width: 310,
                              child: ColoredBox(
                                color: TalColors.background,
                                child: SingleChildScrollView(child: details),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: list),
                            if (selected != null && constraints.maxHeight > 260)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: math.min(
                                    300,
                                    constraints.maxHeight * .46,
                                  ),
                                ),
                                child: SingleChildScrollView(child: details),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
