part of 'watch_panel.dart';

class _WatchNameLabel extends StatelessWidget {
  const _WatchNameLabel(this.name, {required this.style});

  final String name;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      name,
      style: style,
      softWrap: false,
      maxLines: 1,
      overflow: TextOverflow.visible,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth == 0) return const SizedBox.shrink();
        final inheritedStyle = DefaultTextStyle.of(context).style.merge(style);
        final width = TextPainter.computeWidth(
          text: TextSpan(
            text: name,
            style: MediaQuery.boldTextOf(context)
                ? inheritedStyle.copyWith(fontWeight: FontWeight.bold)
                : inheritedStyle,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 1,
        );
        if (width <= constraints.maxWidth) return text;

        // Fade the glyphs into the row's own background, including on hover.
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [Colors.transparent, Colors.white],
            stops: [0, math.min(16 / bounds.width, .5)],
          ).createShader(bounds),
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: 0,
              maxWidth: double.infinity,
              fit: OverflowBoxFit.deferToChild,
              child: text,
            ),
          ),
        );
      },
    );
  }
}

class _WatchBrowserDrag {
  const _WatchBrowserDrag(this.key, this.section);
  final String key;
  final _WatchBrowserSection section;
}

class _WatchRowDraggable extends Draggable<_WatchBrowserDrag> {
  const _WatchRowDraggable({
    super.key,
    required super.data,
    required super.child,
    required super.feedback,
    super.onDragStarted,
    super.onDragCompleted,
    super.onDraggableCanceled,
  }) : super(
         maxSimultaneousDrags: 1,
         dragAnchorStrategy: pointerDragAnchorStrategy,
         hitTestBehavior: HitTestBehavior.opaque,
       );

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _WatchRowDragRecognizer()..onStart = onStart;
}

class _WatchRowDragRecognizer extends ImmediateMultiDragGestureRecognizer {
  final _heldTouch = DelayedMultiDragGestureRecognizer();

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      return super.createNewPointerState(event);
    }
    // A finger can still scroll the list before the long-press delay expires.
    _heldTouch.gestureSettings = gestureSettings;
    return _heldTouch.createNewPointerState(event);
  }

  @override
  void dispose() {
    _heldTouch.dispose();
    super.dispose();
  }
}

class _WatchScrollHints extends StatefulWidget {
  const _WatchScrollHints({required this.section, required this.child});

  final _WatchBrowserSection section;
  final Widget child;

  @override
  State<_WatchScrollHints> createState() => _WatchScrollHintsState();
}

class _WatchScrollHintsState extends State<_WatchScrollHints> {
  bool _above = false;
  bool _below = false;

  void _update(ScrollMetrics metrics) {
    final above = metrics.viewportDimension > 0 && metrics.extentBefore > .5;
    final below = metrics.viewportDimension > 0 && metrics.extentAfter > .5;
    if (_above == above && _below == below) return;
    setState(() {
      _above = above;
      _below = below;
    });
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) _update(notification.metrics);
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) _update(notification.metrics);
            return false;
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  widget.child,
                  if (_above && widget.section != _WatchBrowserSection.members)
                    _watchScrollHint(
                      widget.section,
                      constraints.maxHeight,
                      top: true,
                    ),
                  if (_below)
                    _watchScrollHint(
                      widget.section,
                      constraints.maxHeight,
                      top: false,
                    ),
                ],
              );
            },
          ),
        ),
      );
}

Widget _watchScrollHint(
  _WatchBrowserSection section,
  double viewportHeight, {
  required bool top,
  double topInset = 0,
  Color edge = TalColors.surface,
}) {
  final clear = edge.withValues(alpha: 0);
  return Positioned(
    key: ValueKey('watch-${section.name}-overflow-${top ? 'top' : 'bottom'}'),
    left: 0,
    right: 0,
    top: top ? topInset : null,
    bottom: top ? null : 0,
    height: math.min(24, viewportHeight * .3),
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: top ? [edge, clear] : [clear, edge],
          ),
        ),
      ),
    ),
  );
}

const _watchMemberColumnHeight = 28.0;

class _WatchMembersClipper extends CustomClipper<Rect> {
  const _WatchMembersClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, size.height);

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(_WatchMembersClipper oldClipper) => oldClipper.top != top;
}

class _WatchMembersList extends ListView {
  _WatchMembersList({
    required super.key,
    required super.controller,
    required super.children,
    required this.rows,
    required this.rowHeight,
    required this.stickyRow,
  }) : super(primary: false, padding: EdgeInsets.zero);

  final List<_WatchBrowserEntry> rows;
  final double rowHeight;
  final Widget Function(_WatchBrowserEntry row, VoidCallback reveal) stickyRow;

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    final viewport = super.buildViewport(
      context,
      offset,
      axisDirection,
      slivers,
    );
    final parents = List<int>.filled(rows.length, -1);
    final ends = List<int>.filled(rows.length, rows.length);
    final ancestors = <int>[];
    for (final (index, row) in rows.indexed) {
      while (ancestors.length > row.depth) {
        ends[ancestors.removeLast()] = index;
      }
      parents[index] = ancestors.lastOrNull ?? -1;
      ancestors.add(index);
    }

    // Keep the headers inside the Scrollable so wheel and touch input over a
    // header still scrolls the member list.
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: offset,
        child: viewport,
        builder: (context, child) {
          final height = constraints.maxHeight;
          final maxScroll = math.max(
            0.0,
            _watchMemberColumnHeight + rows.length * rowHeight - height,
          );
          final pixels = offset.hasPixels ? offset.pixels : 0.0;
          final scroll = pixels.clamp(0.0, maxScroll);
          final headers = <Widget>[];
          var stickyHeight = 0.0;
          // Leave room for at least one member row on short viewports.
          for (var depth = 0; (depth + 2) * rowHeight <= height; depth++) {
            final slot = depth * rowHeight;
            final leading = scroll + slot - _watchMemberColumnHeight;
            var index = (leading / rowHeight).floor();
            if (index < 0 || index >= rows.length) break;
            while (rows[index].depth > depth) {
              index = parents[index];
            }
            final start = index * rowHeight;
            final end = ends[index] * rowHeight;
            if (rows[index].depth != depth ||
                ends[index] == index + 1 ||
                start >= leading) {
              break;
            }

            // As the subtree ends, the next row pushes this header up behind
            // the preceding ancestor (or out of the viewport at depth zero).
            final visibleHeight = math.min(rowHeight, end - leading);
            final revealOffset = _watchMemberColumnHeight + start - slot;
            final row = rows[index];
            stickyHeight += visibleHeight;
            headers.add(
              SizedBox(
                key: ValueKey('watch-sticky-${row.rowKey}'),
                height: visibleHeight,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.bottomCenter,
                    minHeight: rowHeight,
                    maxHeight: rowHeight,
                    child: Semantics(
                      tagForChildren: RenderViewport.useTwoPaneSemantics,
                      child: Semantics(
                        tagForChildren: RenderViewport.excludeFromScrolling,
                        child: Material(
                          type: MaterialType.transparency,
                          child: stickyRow(
                            row,
                            () => offset.jumpTo(revealOffset),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (visibleHeight < rowHeight) break;
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              // Clip the scrolling rows themselves so they can't bleed through
              // the sticky surface at a fractional viewport edge.
              ClipRect(
                clipBehavior: headers.isEmpty ? Clip.none : Clip.hardEdge,
                clipper: _WatchMembersClipper(stickyHeight),
                child: child,
              ),
              if (headers.isNotEmpty)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: stickyHeight,
                  // A single opaque surface covers the list at every seam,
                  // including when scaling places row edges on fractional pixels.
                  child: Material(
                    color: TalColors.surface,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: headers,
                    ),
                  ),
                ),
              if (scroll > .5)
                _watchScrollHint(
                  _WatchBrowserSection.members,
                  height - stickyHeight,
                  top: true,
                  topInset: stickyHeight,
                  edge: headers.isEmpty
                      ? TalColors.surface
                      : Colors.black.withValues(alpha: .45),
                ),
            ],
          );
        },
      ),
    );
  }
}

class CompactWatchPanel extends StatefulWidget {
  const CompactWatchPanel({
    super.key,
    required this.controller,
    this.onShowSymbols,
    this.visible = true,
  });
  final TakeALookController controller;
  final VoidCallback? onShowSymbols;
  final bool visible;
  @override
  State<CompactWatchPanel> createState() => _CompactWatchPanelState();
}

class _CompactWatchPanelState extends State<CompactWatchPanel> {
  final _panelFocus = FocusNode(debugLabel: 'watch-browser');
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _summaryScroll = ScrollController();
  final _pinnedScroll = ScrollController();
  final _projectionCache = _WatchProjectionCache();
  (_WatchBrowserSection, String, bool)? _dropTarget;
  EdgeDraggingAutoScroller? _dragScroller;
  Offset? _dragPosition;
  Offset? _dragOrigin;
  PointerDeviceKind? _dragKind;
  final _selection = _WatchSelection();
  final Set<_WatchBrowserSection> _collapsedSections = {};
  List<_WatchRowId> _selectionOrder = [];
  ({String key, bool standalone})? _pendingReveal;
  bool _selectionInitialized = false;
  int _plotRevision = -1;
  double? _valueColumnWidth;
  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _search.text = controller.watchSearchQuery;
  }

  @override
  void didUpdateWidget(covariant CompactWatchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      _search.text = controller.watchSearchQuery;
      _plotRevision = -1;
      _projectionCache.current = null;
      _selection.keys.clear();
      _collapsedSections.clear();
      _selection.anchor = null;
      _pendingReveal = null;
      _selectionInitialized = false;
    }
  }

  @override
  void dispose() {
    _panelFocus.dispose();
    _search.dispose();
    _scroll.dispose();
    _summaryScroll.dispose();
    _pinnedScroll.dispose();
    _dragScroller?.stopAutoScroll();
    super.dispose();
  }

  void _selectRow(_WatchBrowserEntry entry, {bool preserveSelection = false}) {
    final key = entry.key;
    final keyboard = HardwareKeyboard.instance;
    setState(() {
      controller.compactWatchSelection = _selection.select(
        (key, entry.section, entry.rowKey),
        order: _selectionOrder,
        preserve: preserveSelection,
        additive: keyboard.isControlPressed || keyboard.isMetaPressed,
        extend: keyboard.isShiftPressed,
      );
    });
    controller.setPlotHighlightedWatch(key);
  }

  void _selectAll() {
    final keys = controller.watches.map((w) => w.symbol.key);
    setState(() {
      _selection.keys
        ..clear()
        ..addAll(keys);
      _selection.anchor = _selectionOrder.firstOrNull;
      controller.compactWatchSelection ??= _selection.anchor?.$1;
    });
    _panelFocus.requestFocus();
  }

  void _toggle(_WatchBrowserEntry entry) {
    if (entry.node != null) _selectRow(entry);
    if (entry.node != null &&
        (HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _panelFocus.requestFocus();
      return;
    }
    setState(() {
      final expanded = controller.compactExpandedWatches;
      if (!expanded.add(entry.rowKey)) expanded.remove(entry.rowKey);
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
    if (WorkspaceShortcut.selectAllWatches.matches(event)) {
      _selectAll();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.delete &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        _selection.keys.isNotEmpty) {
      controller.removeWatches(_selection.keys);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _syncSelection(_WatchProjection projection) {
    final keys = projection.nodes.keys;
    final lostSelection = _selection.keys.any((key) => !keys.contains(key));
    _selection.keys.removeWhere((key) => !keys.contains(key));
    if (!keys.contains(_selection.anchor?.$1)) _selection.anchor = null;
    if (!keys.contains(controller.compactWatchSelection) &&
        (controller.compactWatchSelection != null ||
            !_selectionInitialized ||
            lostSelection)) {
      controller.compactWatchSelection =
          _selection.keys.firstOrNull ??
          controller.watches.firstOrNull?.symbol.key;
    }
    final selected = controller.compactWatchSelection;
    if (selected != null && !_selection.keys.contains(selected)) {
      _selection.keys
        ..clear()
        ..add(selected);
      _selection.anchor = (selected, _WatchBrowserSection.members, selected);
    }
    _selectionInitialized = true;
    if (_plotRevision == controller.plotWatchSelectionRevision) return;
    final initiatedByChart = controller.plotWatchSelectionRevision > 0;
    _plotRevision = controller.plotWatchSelectionRevision;
    final key = controller.plotHighlightedWatchKey;
    if (key == null || !keys.contains(key)) {
      if (initiatedByChart) {
        controller.compactWatchSelection = null;
        _selection.keys.clear();
        _selection.anchor = null;
        _pendingReveal = null;
      }
      return;
    }
    controller.compactWatchSelection = key;
    _selection.keys
      ..clear()
      ..add(key);
    _selection.anchor = (key, _WatchBrowserSection.members, key);
    _collapsedSections.remove(_WatchBrowserSection.members);
    _pendingReveal = (key: key, standalone: false);
    // A curve selection reveals its source, including an array's range group.
    bool reveal(WatchTreeNode node) {
      if (node.watch.symbol.key == key) return true;
      for (var i = 0; i < node.children.length; i++) {
        if (reveal(node.children[i])) {
          controller.compactExpandedWatches.add(node.watch.symbol.key);
          controller.compactExpandedWatches.add(
            '${node.watch.symbol.key}:range:${i ~/ 32}',
          );
          return true;
        }
      }
      return false;
    }

    for (final root in projection.roots) {
      if (reveal(root)) break;
    }
  }

  void _revealRow(List<_WatchBrowserEntry> rows, double rowHeight) {
    final reveal = _pendingReveal;
    if (reveal == null) return;
    final index = rows.indexWhere(
      (row) => reveal.standalone
          ? row.standaloneRoot == reveal.key && row.depth == 0
          : row.key == reveal.key,
    );
    if (index < 0) return;
    _pendingReveal = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = index == 0
          ? 0.0
          : _watchMemberColumnHeight + index * rowHeight;
      final bottom = top + rowHeight;
      if (!reveal.standalone &&
          top >= position.pixels &&
          bottom <= position.pixels + position.viewportDimension) {
        return;
      }
      _scroll.jumpTo(
        top.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  Future<void> _adjustColor(_WatchBrowserEntry entry) async {
    _selectRow(entry, preserveSelection: true);
    final keys = _selection.keys.toList();
    _panelFocus.requestFocus();
    final color = await showTalDialog<Color>(
      context: context,
      builder: (_) => WatchColorDialog(initialColor: entry.node!.watch.color),
    );
    if (mounted && color != null) {
      controller.setWatchColors(keys, color);
    }
  }

  Future<void> _menu(_WatchBrowserEntry entry, Offset position) async {
    final watch = entry.node!.watch;
    final addStandalone = !watch.standalone;
    final touch = TalUiTheme.of(context).touchOptimized;
    _selectRow(entry, preserveSelection: true);
    final keys = _selection.keys.toList();
    final hexWatches = controller.watchesForHexDisplay(keys);
    final allHex =
        hexWatches.isNotEmpty && hexWatches.every((w) => w.displayHex);
    final plotKeys = <String>{};
    void collect(WatchTreeNode node) {
      if (_selection.keys.contains(node.watch.symbol.key)) {
        plotKeys.addAll(node.watchesInDisplayOrder.map((w) => w.symbol.key));
      } else {
        for (final child in node.children) {
          collect(child);
        }
      }
    }

    for (final root in buildWatchTree(controller.watches)) {
      collect(root);
    }
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
        if (controller.canSetWatchStandalone(entry.key))
          _watchPopupItem(
            touchOptimized: touch,
            value: 'standalone',
            icon: addStandalone
                ? Icons.add_box_outlined
                : Icons.remove_circle_outline,
            label: addStandalone ? '单独添加到监视' : '取消单独监视',
          ),
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
          icon: watch.plotted
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          label: watch.plotted ? '隐藏曲线' : '显示曲线',
          enabled: watch.samplingEnabled,
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'isolate',
          icon: Icons.filter_center_focus,
          label: '孤立',
          enabled: controller.watches.any(
            (w) => plotKeys.contains(w.symbol.key) && w.samplingEnabled,
          ),
        ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'radix',
          icon: Icons.numbers,
          label: allHex ? '十进制显示' : '十六进制显示',
          enabled: hexWatches.isNotEmpty,
        ),
        const PopupMenuDivider(),
        if (controller.isAggregateWatch(watch.symbol.key))
          _watchPopupItem(
            touchOptimized: TalUiTheme.of(context).touchOptimized,
            value: 'restoreMembers',
            icon: Icons.restore,
            label: '恢复成员',
            enabled: controller.canRestoreWatchMembers(watch.symbol.key),
          ),
        _watchPopupItem(
          touchOptimized: TalUiTheme.of(context).touchOptimized,
          value: 'delete',
          icon: Icons.delete_outline,
          label: keys.length > 1 ? '删除所选变量（${keys.length}）' : '删除变量',
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
      case 'standalone':
        _pendingReveal = addStandalone
            ? (key: entry.key, standalone: true)
            : null;
        _collapsedSections.remove(_WatchBrowserSection.members);
        if (addStandalone && entry.expandable) {
          controller.compactExpandedWatches.add(
            _standaloneRowKey(entry.key, entry.key),
          );
        }
        controller.setWatchStandalone(entry.key, addStandalone);
      case 'pin':
        final pinned = !watch.pinned;
        for (final key in keys) {
          controller.setWatchPinned(key, pinned);
        }
      case 'visibility':
        final plotted = !watch.plotted;
        for (final key in keys) {
          controller.toggleWatchPlot(key, plotted);
        }
      case 'isolate':
        controller.isolateWatchPlots(plotKeys);
      case 'radix':
        controller.setWatchesHexDisplay(keys, !allHex);
      case 'delete':
        controller.removeWatches(keys);
      case 'restoreMembers':
        controller.restoreWatchMembers(watch.symbol.key);
      case 'undo':
        controller.undoWatchDeletion();
      case 'redo':
        controller.redoWatchDeletion();
      case 'color':
        await _adjustColor(entry);
    }
  }

  Future<void> _blankMenu(Offset position) async {
    _panelFocus.requestFocus();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final touch = TalUiTheme.of(context).touchOptimized;
    final action = await showTalContextMenu<String>(
      context: context,
      position: RelativeRect.fromSize(
        overlay.globalToLocal(position) & Size.zero,
        overlay.size,
      ),
      items: [
        _watchPopupItem(
          touchOptimized: touch,
          value: 'collapse',
          icon: Icons.unfold_less,
          label: '折叠所有',
          enabled:
              controller.compactExpandedWatches.isNotEmpty ||
              _search.text.isNotEmpty,
        ),
        _watchPopupItem(
          touchOptimized: touch,
          value: 'exitIsolation',
          icon: Icons.filter_center_focus_outlined,
          label: '退出孤立',
          enabled: controller.watchPlotsIsolated,
        ),
        _watchPopupItem(
          touchOptimized: touch,
          value: 'selectAll',
          icon: Icons.select_all,
          label: '全选',
          enabled: controller.watches.isNotEmpty,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          touchOptimized: touch,
          value: 'deleteAll',
          icon: Icons.delete_sweep_outlined,
          label: '删除全部',
          enabled: controller.watches.isNotEmpty,
        ),
        _watchPopupItem(
          touchOptimized: touch,
          value: 'undo',
          icon: Icons.undo,
          label: '撤回删除',
          enabled: controller.canUndoWatchDeletion,
        ),
        _watchPopupItem(
          touchOptimized: touch,
          value: 'redo',
          icon: Icons.redo,
          label: '重做删除 (Ctrl+Y)',
          enabled: controller.canRedoWatchDeletion,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'collapse':
        setState(() {
          controller.compactExpandedWatches.clear();
          _search.clear();
          controller.watchSearchQuery = '';
        });
      case 'exitIsolation':
        controller.exitWatchPlotIsolation();
      case 'selectAll':
        _selectAll();
      case 'deleteAll':
        controller.clearWatches();
      case 'undo':
        controller.undoWatchDeletion();
      case 'redo':
        controller.redoWatchDeletion();
    }
  }

  bool _canReorder(_WatchBrowserDrag drag, _WatchBrowserEntry entry) =>
      drag.section == entry.section &&
      (_projectionCache.current?.canReorder(
            entry.section,
            drag.key,
            entry.key,
          ) ??
          false);

  void _finishRowDrag() {
    _dragScroller?.stopAutoScroll();
    _dragScroller = null;
    _dragPosition = null;
    _dragOrigin = null;
    _dragKind = null;
    if (mounted) setState(() => _dropTarget = null);
  }

  void _scrollRowDrag(PointerMoveEvent event) {
    _dragPosition = event.position;
    _updateDragScroll();
  }

  void _updateDragScroll() {
    final scroller = _dragScroller;
    final position = _dragPosition;
    if (scroller == null || position == null) return;
    final box = scroller.scrollable.context.findRenderObject()! as RenderBox;
    scroller.startAutoScrollIfNecessary(
      Rect.fromCenter(
        center: position,
        width: math.min(1.0, box.size.width),
        height: math.min(32.0, box.size.height),
      ),
    );
  }

  Widget _dragSource(_WatchBrowserEntry entry, Widget child) => Builder(
    builder: (context) => _WatchRowDraggable(
      key: ValueKey('watch-reorder-${entry.section.name}-${entry.key}'),
      data: _WatchBrowserDrag(entry.key, entry.section),
      onDragStarted: () {
        _dragScroller?.stopAutoScroll();
        _dragScroller = EdgeDraggingAutoScroller(
          Scrollable.of(context),
          velocityScalar: 20,
          onScrollViewScrolled: _updateDragScroll,
        );
        _updateDragScroll();
      },
      onDragCompleted: _finishRowDrag,
      onDraggableCanceled: (_, offset) {
        final origin = _dragOrigin;
        final showMenu =
            _dragKind != PointerDeviceKind.mouse &&
            origin != null &&
            (offset - origin).distance <= kTouchSlop;
        _finishRowDrag();
        // A stationary touch hold keeps the existing context menu action.
        if (showMenu && mounted) {
          _menu(entry, origin);
        }
      },
      feedback: Material(
        elevation: 6,
        color: TalColors.surface,
        child: Container(
          width: 240,
          height: TalUiTheme.of(context).targetExtent(32),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: TalColors.accent),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            entry.node!.watch.symbol.name,
            style: talMono.copyWith(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      child: child,
    ),
  );

  Widget _row(
    _WatchBrowserEntry entry,
    bool wide,
    double valueWidth, {
    VoidCallback? revealSticky,
  }) {
    BuildContext? rowContext;
    final node = entry.node, watch = node?.watch;
    final selected =
        revealSticky == null &&
        watch != null &&
        _selection.keys.contains(entry.key);
    final ui = TalUiTheme.of(context);
    final height = ui.targetExtent(32);
    final expanded =
        _search.text.trim().isNotEmpty ||
        controller.compactExpandedWatches.contains(entry.rowKey);
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final showPin = !ui.touchOptimized || constraints.maxWidth >= 280;
        final actionWidth = ui.compactIconButtonSize * (showPin ? 3 : 2);
        // Reserve padding, the value gap and at least 32 pixels for the name.
        final maxIndentWidth = math.max(
          25.0,
          constraints.maxWidth -
              valueWidth -
              actionWidth -
              (wide ? 88 : 0) -
              51,
        );
        void activate() {
          if (entry.expandable) {
            _toggle(entry);
          } else {
            _selectRow(entry);
            _panelFocus.requestFocus();
          }
          if (revealSticky != null) {
            revealSticky();
            return;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              Scrollable.ensureVisible(
                context,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          });
        }

        return InkWell(
          // Selection owns the row highlight. Descendant editor focus must not
          // add independent ink that can linger after editing and deselection.
          focusColor: Colors.transparent,
          onTap: activate,
          onSecondaryTapUp: watch == null
              ? null
              : (d) => _menu(entry, d.globalPosition),
          onLongPress: watch == null || entry.standaloneRoot == null
              ? null
              : () {
                  final box = context.findRenderObject()! as RenderBox;
                  _menu(entry, box.localToGlobal(box.size.center(Offset.zero)));
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
                  width: math.min(
                    25 + math.min(entry.depth, 8) * 12.0,
                    maxIndentWidth,
                  ),
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
                              'compact-watch-color-${entry.section.actionPrefix}${entry.rowKey}',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTap: activate,
                            onDoubleTap: () => _adjustColor(entry),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: SizedBox(
                                  width: 3,
                                  height: height - 12,
                                  child: DecoratedBox(
                                    key: ValueKey(
                                      'compact-watch-color-bar-${entry.section.actionPrefix}${entry.rowKey}',
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
                    child: _WatchNameLabel(
                      watch?.symbol.missing == true
                          ? '${entry.label}（新固件中不存在）'
                          : entry.label,
                      style: talMono.copyWith(
                        fontSize: 12,
                        color: watch?.symbol.missing == true
                            ? TalColors.warning
                            : null,
                      ),
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
                            '${entry.section.rowPrefix}-watch-cell-${entry.rowKey}',
                          ),
                          controller: controller,
                          watch: watch!,
                          prefix: entry.standaloneRoot == null
                              ? entry.section.rowPrefix
                              : 'standalone-${entry.standaloneRoot}',
                          onSelect: activate,
                        ),
                ),
                if (entry.expandable)
                  SizedBox(
                    width: actionWidth,
                    child: Text(
                      '${entry.members.length} 项',
                      textAlign: TextAlign.right,
                      style: workbenchMuted.copyWith(fontSize: 11),
                    ),
                  )
                else ...[
                  if (showPin)
                    _rowIcon(
                      ui,
                      '固定',
                      watch!.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      'watch-pin-${entry.section.actionPrefix}${entry.rowKey}',
                      watch.pinned,
                      () => controller.setWatchPinned(entry.key, !watch.pinned),
                    ),
                  _rowIcon(
                    ui,
                    watch!.samplingEnabled ? '移出采集' : '加入采集',
                    Icons.sensors,
                    'compact-watch-capture-${entry.section.actionPrefix}${entry.rowKey}',
                    watch.samplingEnabled,
                    watch.symbol.missing
                        ? null
                        : () => controller.setWatchReadMode(
                            entry.key,
                            watch.samplingEnabled
                                ? WatchReadMode.monitor
                                : WatchReadMode.capture,
                          ),
                  ),
                  if (watch.samplingEnabled)
                    _rowIcon(
                      ui,
                      watch.plotted ? '隐藏曲线' : '显示曲线',
                      watch.plotted
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      'compact-watch-plot-${entry.section.actionPrefix}${entry.rowKey}',
                      watch.plotted,
                      () =>
                          controller.toggleWatchPlot(entry.key, !watch.plotted),
                      color: watch.plotted ? watch.color : null,
                    )
                  else
                    SizedBox(width: ui.compactIconButtonSize),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (watch == null) return content;
    Widget anchor(Widget child) => WatchRowAnchor(
      key: revealSticky == null
          ? ValueKey('${entry.section.rowPrefix}-watch-${entry.rowKey}')
          : null,
      controller: controller,
      watchKey: entry.key,
      child: child,
    );
    if (entry.standaloneRoot != null) return anchor(content);
    return anchor(
      _dragSource(
        entry,
        DragTarget<_WatchBrowserDrag>(
          onWillAcceptWithDetails: (details) =>
              _canReorder(details.data, entry),
          onMove: (details) {
            if (!_canReorder(details.data, entry)) return;
            final targetBox = rowContext!.findRenderObject()! as RenderBox;
            final after =
                targetBox.globalToLocal(details.offset).dy >=
                targetBox.size.height / 2;
            final target = (entry.section, entry.key, after);
            if (_dropTarget != target) setState(() => _dropTarget = target);
          },
          onLeave: (_) {
            if (_dropTarget?.$1 == entry.section &&
                _dropTarget?.$2 == entry.key) {
              setState(() => _dropTarget = null);
            }
          },
          onAcceptWithDetails: (details) {
            if (!_canReorder(details.data, entry)) return;
            final keys = _projectionCache.current!.move(
              entry.section,
              details.data.key,
              entry.key,
              after: _dropTarget?.$3 == true,
            );
            setState(() {
              controller.compactWatchSectionOrders[entry.section.name] = keys;
              _dropTarget = null;
            });
          },
          builder: (context, candidates, rejected) {
            rowContext = context;
            final target = _dropTarget;
            return Stack(
              children: [
                content,
                if (target?.$1 == entry.section && target?.$2 == entry.key)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: target!.$3 ? null : 0,
                    bottom: target.$3 ? 0 : null,
                    child: const SizedBox(
                      height: 2,
                      child: ColoredBox(color: TalColors.accent),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _rowIcon(
    TalUiTheme ui,
    String label,
    IconData icon,
    String key,
    bool active,
    VoidCallback? onPressed, {
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
        maximumSize: Size.square(ui.compactIconButtonSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        icon,
        size: 15,
        color: color ?? (active ? TalColors.accent : TalColors.muted),
      ),
    ),
  );

  Widget _actionHeader(TalUiTheme ui, String label) => Container(
    width: ui.compactIconButtonSize,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      border: Border(left: BorderSide(color: TalColors.borderSoft)),
    ),
    child: Text(
      label,
      maxLines: 1,
      softWrap: false,
      style: workbenchMuted.copyWith(fontSize: 10),
    ),
  );

  Widget _sectionHeader(
    _WatchBrowserSection section,
    String label, {
    IconData? icon,
    int? count,
    String? hint,
  }) {
    final expanded = !_collapsedSections.contains(section);
    return Tooltip(
      message: '${expanded ? '收起' : '展开'}$label',
      child: InkWell(
        key: ValueKey('watch-${section.name}-section'),
        onTap: () => setState(() {
          if (!_collapsedSections.add(section)) {
            _collapsedSections.remove(section);
          }
        }),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: TalUiTheme.of(context).targetExtent(30),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: TalColors.muted,
                ),
                const SizedBox(width: 4),
                if (icon != null) ...[
                  Icon(icon, size: 13, color: TalColors.muted),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: workbenchMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: 5),
                        Text('$count', style: workbenchMuted),
                      ],
                    ],
                  ),
                ),
                if (hint != null)
                  Text(
                    hint,
                    style: workbenchMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionPane({
    required _WatchBrowserSection section,
    required Widget header,
    required Widget list,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final headerHeight = TalUiTheme.of(context).targetExtent(30);
      return Column(
        children: [
          SizedBox(
            height: math.min(headerHeight, constraints.maxHeight),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: headerHeight,
                maxHeight: headerHeight,
                child: header,
              ),
            ),
          ),
          Expanded(
            child: _WatchScrollHints(section: section, child: list),
          ),
        ],
      );
    },
  );

  Widget _splitLists({
    required Widget summary,
    required Widget members,
    required double initialSummaryHeight,
    Widget? pinned,
    double initialPinnedHeight = 0,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final ui = TalUiTheme.of(context);
      final handleHeight = math.min(
        ui.touchOptimized ? 24.0 : 12.0,
        constraints.maxHeight,
      );
      final available = constraints.maxHeight - handleHeight;
      final innerHandleHeight = pinned == null
          ? 0.0
          : math.min(handleHeight, available);
      final minHeight = math.min(
        ui.targetExtent(30),
        math.max(0.0, available - innerHandleHeight) / (pinned == null ? 2 : 3),
      );
      final preferredMinHeight = math.min(
        ui.targetExtent(30) + ui.targetExtent(32),
        math.max(0.0, available - innerHandleHeight) / (pinned == null ? 2 : 3),
      );
      final pinnedExpanded = !_collapsedSections.contains(
        _WatchBrowserSection.pinned,
      );
      final captureExpanded = !_collapsedSections.contains(
        _WatchBrowserSection.capture,
      );
      final membersExpanded = !_collapsedSections.contains(
        _WatchBrowserSection.members,
      );
      final maxHeight = available - minHeight;
      final pinnedHeight = pinned == null
          ? 0.0
          : !pinnedExpanded
          ? minHeight
          : (controller.compactWatchPinnedFraction == null
                    ? initialPinnedHeight
                    : available * controller.compactWatchPinnedFraction!)
                .clamp(
                  minHeight,
                  math.max(
                    minHeight,
                    controller.compactWatchPinnedFraction == null
                        ? available - innerHandleHeight - preferredMinHeight * 2
                        : maxHeight - innerHandleHeight - minHeight,
                  ),
                )
                .toDouble();
      final minSummaryHeight = pinned == null
          ? minHeight
          : math.min(maxHeight, pinnedHeight + innerHandleHeight + minHeight);
      final preferredMinSummaryHeight = pinned == null
          ? preferredMinHeight
          : math.min(
              maxHeight,
              pinnedHeight + innerHandleHeight + preferredMinHeight,
            );
      final preferredSummaryHeight =
          (controller.compactWatchSummaryFraction == null
          ? math
                .min(initialSummaryHeight, available * .45)
                .clamp(
                  preferredMinSummaryHeight,
                  math.max(
                    preferredMinSummaryHeight,
                    available - preferredMinHeight,
                  ),
                )
          : (available * controller.compactWatchSummaryFraction!).clamp(
              minSummaryHeight,
              maxHeight,
            ));
      final heights = <_WatchBrowserSection, double>{
        if (pinned != null) _WatchBrowserSection.pinned: pinnedHeight,
        _WatchBrowserSection.capture:
            preferredSummaryHeight - pinnedHeight - innerHandleHeight,
        _WatchBrowserSection.members: available - preferredSummaryHeight,
      };
      // Collapsed panes retain only their header. Give their space to the
      // nearest expanded pane without changing the saved expanded sizes.
      for (final section in [
        _WatchBrowserSection.capture,
        _WatchBrowserSection.members,
      ]) {
        if (!_collapsedSections.contains(section)) continue;
        final released = heights[section]! - minHeight;
        heights[section] = minHeight;
        final recipients = section == _WatchBrowserSection.capture
            ? [_WatchBrowserSection.members, _WatchBrowserSection.pinned]
            : [_WatchBrowserSection.capture, _WatchBrowserSection.pinned];
        final recipient = recipients
            .where(
              (candidate) =>
                  heights.containsKey(candidate) &&
                  !_collapsedSections.contains(candidate),
            )
            .firstOrNull;
        if (recipient != null) {
          heights[recipient] = heights[recipient]! + released;
        }
      }
      final visiblePinnedHeight = heights[_WatchBrowserSection.pinned] ?? 0;
      final summaryHeight =
          visiblePinnedHeight +
          innerHandleHeight +
          heights[_WatchBrowserSection.capture]!;
      return Column(
        children: [
          SizedBox(
            key: const ValueKey('watch-summary-pane'),
            height: summaryHeight,
            child: pinned == null
                ? summary
                : Column(
                    children: [
                      SizedBox(
                        key: const ValueKey('watch-pinned-pane'),
                        height: visiblePinnedHeight,
                        child: pinned,
                      ),
                      _sectionResizeHandle(
                        key: const ValueKey('watch-pinned-capture-resize'),
                        height: innerHandleHeight,
                        tooltip: '上下拖动调整已固定和正在采集区域高度',
                        onUpdate: (delta) {
                          if (available <= innerHandleHeight ||
                              !pinnedExpanded ||
                              !captureExpanded) {
                            return;
                          }
                          setState(() {
                            final maximum = math.max(
                              minHeight,
                              summaryHeight - innerHandleHeight - minHeight,
                            );
                            final currentHeight =
                                (available *
                                        (controller
                                                .compactWatchPinnedFraction ??
                                            pinnedHeight / available))
                                    .clamp(minHeight, maximum);
                            controller.compactWatchPinnedFraction =
                                (currentHeight + delta).clamp(
                                  minHeight,
                                  maximum,
                                ) /
                                available;
                          });
                        },
                      ),
                      Expanded(
                        key: const ValueKey('watch-capture-pane'),
                        child: summary,
                      ),
                    ],
                  ),
          ),
          _sectionResizeHandle(
            key: const ValueKey('watch-sections-resize'),
            height: handleHeight,
            tooltip: '上下拖动调整正在采集和正在监视区域高度',
            onUpdate: (delta) {
              if (available <= innerHandleHeight ||
                  !captureExpanded ||
                  !membersExpanded) {
                return;
              }
              setState(() {
                final currentHeight =
                    (available *
                            (controller.compactWatchSummaryFraction ??
                                summaryHeight / available))
                        .clamp(minSummaryHeight, maxHeight);
                controller.compactWatchSummaryFraction =
                    (currentHeight + delta).clamp(minSummaryHeight, maxHeight) /
                    available;
              });
            },
          ),
          SizedBox(
            key: const ValueKey('watch-members-pane'),
            height: heights[_WatchBrowserSection.members],
            child: members,
          ),
          if (!captureExpanded &&
              !membersExpanded &&
              (pinned == null || !pinnedExpanded))
            const Spacer(),
        ],
      );
    },
  );

  Widget _sectionResizeHandle({
    required Key key,
    required double height,
    required String tooltip,
    required ValueChanged<double> onUpdate,
  }) => Tooltip(
    message: tooltip,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragUpdate: (details) => onUpdate(details.delta.dy),
        child: SizedBox(
          height: height,
          child: const Stack(
            alignment: Alignment.center,
            children: [
              Divider(height: 1, color: TalColors.borderSoft),
              Center(
                child: SizedBox(
                  width: 28,
                  height: 3,
                  child: ColoredBox(color: TalColors.border),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.watchChanges,
      controller.samplingChanges,
      controller.connectionChanges,
      controller.compactWatchDetailsExpanded,
    ]),
    builder: (_, _) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 48) {
          return _WatchMonitorScope(
            controller: controller,
            keys: const {},
            child: const SizedBox.shrink(),
          );
        }
        final projection = _projectionCache.update(
          controller.watchRevision,
          () => controller.watches,
          controller.compactWatchSectionOrders,
        );
        final allNodes = projection.nodes;
        _syncSelection(projection);
        final selected = allNodes[controller.compactWatchSelection]?.watch;
        final rows = projection.rows(
          _search.text,
          controller.compactExpandedWatches,
        );
        final pinned = projection.pinned;
        final captured = projection.captured;
        final pinnedExpanded = !_collapsedSections.contains(
          _WatchBrowserSection.pinned,
        );
        final captureExpanded = !_collapsedSections.contains(
          _WatchBrowserSection.capture,
        );
        final membersExpanded = !_collapsedSections.contains(
          _WatchBrowserSection.members,
        );
        _selectionOrder = [
          if (pinnedExpanded)
            for (final w in pinned)
              (w.symbol.key, _WatchBrowserSection.pinned, w.symbol.key),
          if (captureExpanded)
            for (final w in captured)
              (w.symbol.key, _WatchBrowserSection.capture, w.symbol.key),
          if (membersExpanded)
            for (final row in rows)
              if (row.node != null) (row.key, row.section, row.rowKey),
        ];
        final wide = constraints.maxWidth >= 760;
        final detailsExpanded = controller.compactWatchDetailsExpanded.value;
        final detailsVisible = wide || constraints.maxHeight > 260;
        final visible = <String>{
          if (membersExpanded)
            for (final row in rows)
              if (row.node != null && !row.expandable) row.key,
          if (detailsVisible &&
              detailsExpanded &&
              selected != null &&
              allNodes[selected.symbol.key]!.children.isEmpty)
            selected.symbol.key,
        };
        final ui = TalUiTheme.of(context);
        if (membersExpanded) _revealRow(rows, ui.targetExtent(32));
        final detailsWidth = detailsExpanded ? 310.0 : ui.iconButtonSize;
        final listWidth = constraints.maxWidth - (wide ? detailsWidth : 0);
        final showPin = !ui.touchOptimized || listWidth >= 280;
        final maxDepth = rows.fold<int>(
          0,
          (depth, row) => math.max(depth, row.depth),
        );
        final maxValueWidth = math.max(
          64.0,
          listWidth -
              ui.compactIconButtonSize * (showPin ? 3 : 2) -
              (wide ? 192 : 104) -
              math.min(maxDepth, 8) * 12,
        );
        final valueWidth = (_valueColumnWidth ?? (wide ? 112.0 : 88.0)).clamp(
          64.0,
          maxValueWidth,
        );
        final list = Listener(
          onPointerDown: (event) {
            if (_dragScroller != null) return;
            _dragOrigin = _dragPosition = event.position;
            _dragKind = event.kind;
          },
          onPointerMove: _scrollRowDrag,
          child: GestureDetector(
            key: const ValueKey('compact-watch-list-context-area'),
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (details) => _blankMenu(details.globalPosition),
            onLongPressStart: (details) => _blankMenu(details.globalPosition),
            child: _splitLists(
              initialSummaryHeight:
                  ui.targetExtent(30) +
                  (captured.isEmpty
                      ? 28
                      : math.min(captured.length, 3) * ui.targetExtent(32)) +
                  (pinned.isEmpty
                      ? 0
                      : ui.targetExtent(30) +
                            pinned.length * ui.targetExtent(32) +
                            12),
              summary: _sectionPane(
                section: _WatchBrowserSection.capture,
                header: _sectionHeader(
                  _WatchBrowserSection.capture,
                  '正在采集',
                  icon: Icons.sensors,
                  count: captured.length,
                ),
                list: ListView.builder(
                  controller: _summaryScroll,
                  key: const ValueKey('watch-capture-list'),
                  primary: false,
                  itemCount: captureExpanded ? math.max(1, captured.length) : 0,
                  itemBuilder: (context, index) => captured.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Text('暂无正在采集的变量', style: workbenchMuted),
                        )
                      : _row(
                          projection.summaryRow(
                            captured[index],
                            _WatchBrowserSection.capture,
                          ),
                          wide,
                          valueWidth,
                        ),
                ),
              ),
              initialPinnedHeight:
                  ui.targetExtent(30) + pinned.length * ui.targetExtent(32),
              pinned: pinned.isEmpty
                  ? null
                  : _sectionPane(
                      section: _WatchBrowserSection.pinned,
                      header: _sectionHeader(
                        _WatchBrowserSection.pinned,
                        '已固定',
                        icon: Icons.push_pin_outlined,
                        hint: '折叠后仍刷新',
                      ),
                      list: ListView.builder(
                        controller: _pinnedScroll,
                        key: const ValueKey('watch-pinned-list'),
                        primary: false,
                        itemCount: pinnedExpanded ? pinned.length : 0,
                        itemBuilder: (context, index) => _row(
                          projection.summaryRow(
                            pinned[index],
                            _WatchBrowserSection.pinned,
                          ),
                          wide,
                          valueWidth,
                        ),
                      ),
                    ),
              members: _sectionPane(
                section: _WatchBrowserSection.members,
                header: Row(
                  children: [
                    Expanded(
                      child: _sectionHeader(
                        _WatchBrowserSection.members,
                        _search.text.trim().isEmpty ? '正在监视' : '搜索结果',
                        icon: Icons.monitor_heart_outlined,
                        count: rows.where((row) => row.depth == 0).length,
                      ),
                    ),
                    SizedBox(
                      width: math.min(
                        ui.touchOptimized ? 110.0 : 96.0,
                        listWidth / 2,
                      ),
                      height: ui.targetExtent(24),
                      child: Semantics(
                        label: '默认监视频率',
                        child: TalDropdown<double>(
                          key: const ValueKey('watch-default-monitor-rate'),
                          value: controller.monitorRateHz,
                          values: monitorRatePresets,
                          label: formatReadRate,
                          editor: monitorRateEditor,
                          onChanged: controller.setMonitorRate,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                list: _WatchMembersList(
                  controller: _scroll,
                  key: const ValueKey('compact-watch-list'),
                  rows: membersExpanded ? rows : const [],
                  rowHeight: ui.targetExtent(32),
                  stickyRow: (row, reveal) =>
                      _row(row, wide, valueWidth, revealSticky: reveal),
                  children: [
                    if (membersExpanded) ...[
                      Container(
                        height: _watchMemberColumnHeight,
                        padding: const EdgeInsets.fromLTRB(27, 2, 5, 2),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '名称',
                                style: workbenchMuted,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Tooltip(
                              message: '左右拖动调整当前值列宽',
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeColumn,
                                child: GestureDetector(
                                  key: const ValueKey(
                                    'watch-value-column-resize',
                                  ),
                                  behavior: HitTestBehavior.opaque,
                                  onHorizontalDragUpdate: (details) =>
                                      setState(() {
                                        _valueColumnWidth =
                                            (valueWidth - details.delta.dx)
                                                .clamp(64.0, maxValueWidth);
                                      }),
                                  child: const SizedBox(
                                    width: 12,
                                    height: 24,
                                    child: Center(
                                      child: SizedBox(
                                        width: 1,
                                        height: 14,
                                        child: ColoredBox(
                                          color: TalColors.border,
                                        ),
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
                            if (showPin)
                              SizedBox(width: ui.compactIconButtonSize),
                            _actionHeader(ui, '采集'),
                            _actionHeader(ui, '绘制'),
                          ],
                        ),
                      ),
                      if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              Text(
                                controller.watches.isEmpty
                                    ? '从符号变量加入变量'
                                    : '没有匹配的成员',
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
                  ],
                ),
              ),
            ),
          ),
        );
        final details = selected == null
            ? const SizedBox.shrink()
            : _WatchMemberDetails(
                key: ValueKey('watch-details-${selected.symbol.key}'),
                controller: controller,
                watch: selected,
                node: allNodes[selected.symbol.key]!,
                expanded: detailsExpanded,
                compactHeader: wide && !detailsExpanded,
                onToggleExpanded: () =>
                    controller.compactWatchDetailsExpanded.value =
                        !detailsExpanded,
              );
        return _WatchMonitorScope(
          controller: controller,
          keys: widget.visible ? visible : <String>{},
          child: PanelKeyboardListener(
            focusNode: _panelFocus,
            onKeyEvent: _shortcut,
            child: Material(
              color: TalColors.surface,
              child: Column(
                children: [
                  if (constraints.maxHeight > 210)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                      child: SizedBox(
                        height: ui.controlHeight,
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
                          onChanged: (value) => setState(
                            () => controller.watchSearchQuery = value,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: list),
                              SizedBox(
                                width: detailsWidth,
                                child: ColoredBox(
                                  color: TalColors.background,
                                  child: details,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(child: list),
                              if (selected != null &&
                                  constraints.maxHeight > 260)
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: math.min(
                                      300,
                                      constraints.maxHeight * .46,
                                    ),
                                  ),
                                  child: details,
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
