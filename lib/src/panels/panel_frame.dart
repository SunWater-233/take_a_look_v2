part of 'panels.dart';

const double _talPanelTabMouseDragSlop = 10;

double talPanelTabWidth(
  WorkspacePanelId tab, {
  required TextScaler textScaler,
  required TextDirection textDirection,
}) {
  final painter = TextPainter(
    text: TextSpan(text: tab.title, style: talBody),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final scaledFontSize = textScaler.scale(talBody.fontSize ?? 13);
  final textWidth = math.max(
    painter.width,
    scaledFontSize * tab.title.runes.length,
  );
  final width = textWidth.ceilToDouble() + 24;
  painter.dispose();
  return width;
}

class TalPanelTabSurface extends StatelessWidget {
  const TalPanelTabSurface({
    required this.tab,
    required this.selected,
    this.width,
    this.surfaceKey,
    this.attention = 0,
    this.unread = false,
    this.workbench = false,
    this.tabsAtBottom = false,
    super.key,
  });

  final WorkspacePanelId tab;
  final bool selected;
  final double? width;
  final Key? surfaceKey;
  final double attention;
  final bool unread;
  final bool workbench;
  final bool tabsAtBottom;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: surfaceKey,
      width:
          width ??
          talPanelTabWidth(
            tab,
            textScaler: MediaQuery.textScalerOf(context),
            textDirection: Directionality.of(context),
          ),
      height: TalUiTheme.of(context).panelTabHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          _sourceAttentionColor.withValues(alpha: attention * 0.13),
          workbench
              ? WorkbenchColors.surface
              : selected
              ? TalColors.surface
              : TalColors.surfaceAlt,
        ),
        border: workbench
            ? (tabsAtBottom
                  ? Border(
                      top: BorderSide(
                        color: selected
                            ? TalColors.accent
                            : WorkbenchColors.border,
                        width: selected ? 2 : 1,
                      ),
                    )
                  : Border(
                      bottom: BorderSide(
                        color: selected
                            ? TalColors.accent
                            : WorkbenchColors.border,
                        width: selected ? 2 : 1,
                      ),
                    ))
            : Border(
                top: BorderSide(
                  color: Color.lerp(
                    selected ? TalColors.accent : TalColors.border,
                    _sourceAttentionColor,
                    attention,
                  )!,
                  width: selected || tab == WorkspacePanelId.sourceDebug
                      ? 2
                      : 1,
                ),
                right: talControlBorder,
                bottom: selected
                    ? talControlBorder.copyWith(color: TalColors.surface)
                    : talControlBorder,
              ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Text(
              workbench && tab == WorkspacePanelId.watch ? '变量监视' : tab.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: talBody.copyWith(
                color: selected ? TalColors.heading : TalColors.muted,
              ),
            ),
          ),
          if (unread)
            const Positioned(
              right: -8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _SourceUnreadDot(key: ValueKey('source-panel-unread')),
              ),
            ),
        ],
      ),
    );
  }
}

class TalPanelFrame extends StatefulWidget {
  const TalPanelFrame({
    required this.panel,
    required this.child,
    this.chrome,
    this.controller,
    this.compact = false,
    super.key,
  });

  final WorkspacePanelId panel;
  final Widget child;
  final PanelChrome? chrome;
  final TakeALookController? controller;
  final bool compact;

  @override
  State<TalPanelFrame> createState() => _TalPanelFrameState();
}

class _TalPanelFrameState extends State<TalPanelFrame> {
  bool collapsed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.compact) return _buildCompact(context);
    final chrome = widget.chrome;
    final tabs = chrome?.tabs ?? [widget.panel];
    final title = tabs.length > 1
        ? '${widget.panel.title} 组合'
        : widget.panel.title;
    return Container(
      key: ValueKey<String>(
        chrome?.groupId == null
            ? 'panel-frame-${widget.panel.name}'
            : 'panel-frame-group-${chrome!.groupId}',
      ),
      decoration: BoxDecoration(
        color: TalColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: chrome?.highlighted == true
              ? TalColors.accent
              : TalColors.panelBorder,
          width: chrome?.highlighted == true ? 3 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: chrome?.onFloat,
              onPanStart: chrome?.draggable == true
                  ? chrome!.onDragStart
                  : null,
              onPanUpdate: chrome?.draggable == true
                  ? chrome!.onDragUpdate
                  : null,
              onPanEnd: chrome?.draggable == true ? chrome!.onDragEnd : null,
              child: MouseRegion(
                cursor: chrome?.draggable == true
                    ? SystemMouseCursors.grab
                    : MouseCursor.defer,
                child: Container(
                  height: TalUiTheme.of(context).panelHeaderHeight,
                  padding: const EdgeInsets.only(left: 7, right: 4),
                  decoration: const BoxDecoration(
                    color: TalColors.surfaceAlt,
                    border: Border(bottom: BorderSide(color: TalColors.border)),
                  ),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => setState(() => collapsed = !collapsed),
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          width: TalUiTheme.of(context).touchOptimized
                              ? 48
                              : 26,
                          height: TalUiTheme.of(context).touchOptimized
                              ? 48
                              : 28,
                          child: Icon(
                            collapsed
                                ? Icons.keyboard_arrow_right
                                : Icons.keyboard_arrow_down,
                            size: 18,
                          ),
                        ),
                      ),
                      Expanded(
                        child:
                            (tabs.length == 1 || collapsed) &&
                                tabs.contains(WorkspacePanelId.sourceDebug) &&
                                widget.controller != null
                            ? _SourceTabAttention(
                                controller: widget.controller!,
                                builder: (attention, unread) => Container(
                                  color: _sourceAttentionColor.withValues(
                                    alpha: attention * 0.13,
                                  ),
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: talStrong,
                                        ),
                                      ),
                                      if (unread) ...[
                                        const SizedBox(width: 6),
                                        const _SourceUnreadDot(
                                          key: ValueKey('source-panel-unread'),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )
                            : Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: talStrong,
                              ),
                      ),
                      if (chrome != null && chrome.showActions)
                        TalIconButton(
                          tooltip: '弹出为独立窗口',
                          onPressed: chrome.onFloat,
                          icon: const Icon(Icons.open_in_new, size: 15),
                        ),
                      if (chrome != null &&
                          chrome.showActions &&
                          tabs.length > 1)
                        TalIconButton(
                          tooltip: '从组合中拆分当前面板',
                          onPressed: chrome.onSeparate,
                          icon: const Icon(Icons.call_split, size: 15),
                        ),
                      if (chrome != null && chrome.showActions)
                        TalIconButton(
                          tooltip: '隐藏面板（可从“视图”恢复）',
                          onPressed: chrome.onClose,
                          icon: const Icon(Icons.close, size: 17),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (!collapsed && tabs.length > 1)
              _PanelTabs(
                controller: widget.controller,
                tabs: tabs,
                selected: chrome!.activePanel,
                onSelected: chrome.onSelect,
                groupId: chrome.groupId,
                draggable: chrome.tabsDraggable,
                onAccept: chrome.onTabAccept,
                onDragStart: chrome.onTabDragStart,
                onDragUpdate: chrome.onTabDragUpdate,
                onDragEnd: chrome.onTabDragEnd,
              ),
            if (!collapsed) Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context) {
    final chrome = widget.chrome;
    final tabs = chrome?.tabs ?? [widget.panel];
    final tabsAtBottom = chrome?.tabsAtBottom ?? false;
    return Container(
      key: ValueKey(
        chrome?.groupId == null
            ? 'panel-frame-${widget.panel.name}'
            : 'panel-frame-group-${chrome!.groupId}',
      ),
      decoration: const BoxDecoration(color: WorkbenchColors.surface),
      foregroundDecoration: BoxDecoration(
        border: Border.all(
          color: chrome?.highlighted == true
              ? TalColors.accent
              : WorkbenchColors.border,
          width: chrome?.highlighted == true ? 2 : 1,
        ),
      ),
      child: Column(
        verticalDirection: tabsAtBottom
            ? VerticalDirection.up
            : VerticalDirection.down,
        children: [
          Container(
            height: TalUiTheme.of(context).panelHeaderHeight,
            decoration: BoxDecoration(
              color: WorkbenchColors.surface,
              border: tabsAtBottom
                  ? const Border(top: BorderSide(color: WorkbenchColors.border))
                  : const Border(
                      bottom: BorderSide(color: WorkbenchColors.border),
                    ),
            ),
            child: Row(
              children: [
                ?chrome?.headerLeading,
                Expanded(
                  child: Align(
                    alignment: tabsAtBottom
                        ? Alignment.topLeft
                        : Alignment.bottomLeft,
                    child: _PanelTabs(
                      controller: widget.controller,
                      tabs: tabs,
                      selected: widget.panel,
                      onSelected: chrome?.onSelect ?? (_) {},
                      groupId: chrome?.groupId,
                      draggable: chrome?.tabsDraggable ?? false,
                      onAccept: chrome?.onTabAccept,
                      onDragStart: chrome?.onTabDragStart,
                      onDragUpdate: chrome?.onTabDragUpdate,
                      onDragEnd: chrome?.onTabDragEnd,
                      workbench: true,
                      tabsAtBottom: tabsAtBottom,
                    ),
                  ),
                ),
                if (chrome?.draggable == true)
                  GestureDetector(
                    onPanStart: chrome!.onDragStart,
                    onPanUpdate: chrome.onDragUpdate,
                    onPanEnd: chrome.onDragEnd,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: SizedBox(
                        width: 22,
                        child: Icon(Icons.drag_indicator, size: 16),
                      ),
                    ),
                  ),
                if (chrome?.onWorkspaceAction != null)
                  _workspaceMenu(chrome!)
                else if (chrome != null && chrome.showActions) ...[
                  TalIconButton(
                    tooltip: '弹出为独立窗口',
                    onPressed: chrome.onFloat,
                    icon: const Icon(Icons.open_in_new, size: 15),
                  ),
                  if (tabs.length > 1)
                    TalIconButton(
                      tooltip: '从组合中拆分当前面板',
                      onPressed: chrome.onSeparate,
                      icon: const Icon(Icons.call_split, size: 15),
                    ),
                  TalIconButton(
                    tooltip: '隐藏面板（可从“视图”恢复）',
                    onPressed: chrome.onClose,
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  Widget _workspaceMenu(PanelChrome chrome) => MenuAnchor(
    style: Theme.of(
      context,
    ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.bottomStart),
    animated: true,
    builder: (context, controller, child) => TalIconButton(
      key: ValueKey('panel-menu-${chrome.groupId}'),
      tooltip: '标签菜单',
      icon: const Icon(Icons.more_horiz, size: 18),
      onPressed: () {
        if (controller.isOpen) {
          controller.close();
        } else {
          controller.open();
        }
      },
    ),
    menuChildren: [
      if (chrome.tabs.length > 1) ...[
        for (final tab in chrome.tabs)
          MenuItemButton(
            leadingIcon: SizedBox(
              width: 16,
              child: tab == chrome.activePanel
                  ? const Icon(Icons.check, size: 14, color: TalColors.text)
                  : null,
            ),
            onPressed: () {
              if (tab != chrome.activePanel) chrome.onSelect(tab);
            },
            child: Text(tab == WorkspacePanelId.watch ? '变量监视' : tab.title),
          ),
        const Divider(height: 7, thickness: 1, color: TalColors.borderSoft),
      ],
      MenuItemButton(
        onPressed: chrome.sidebar == WorkspaceSidebarSide.left
            ? null
            : () => chrome.onWorkspaceAction!(WorkspacePanelAction.dockLeft),
        child: const Text('移至左侧栏'),
      ),
      MenuItemButton(
        onPressed: chrome.sidebar == WorkspaceSidebarSide.right
            ? null
            : () => chrome.onWorkspaceAction!(WorkspacePanelAction.dockRight),
        child: const Text('移至右侧栏'),
      ),
      MenuItemButton(
        onPressed: chrome.groupId == 'output'
            ? null
            : () => chrome.onWorkspaceAction!(WorkspacePanelAction.dockBottom),
        child: const Text('移至底部'),
      ),
      if (chrome.sidebar != null || chrome.groupId == 'output')
        MenuItemButton(
          onPressed: () =>
              chrome.onWorkspaceAction!(WorkspacePanelAction.moveToWorkspace),
          child: const Text('移回工作区'),
        ),
      if (chrome.sidebar != null)
        MenuItemButton(
          onPressed: () =>
              chrome.onWorkspaceAction!(WorkspacePanelAction.collapse),
          child: const Text('收起侧栏'),
        ),
      const Divider(height: 7, thickness: 1, color: TalColors.borderSoft),
      MenuItemButton(onPressed: chrome.onFloat, child: const Text('弹出为独立窗口')),
      MenuItemButton(onPressed: chrome.onClose, child: const Text('隐藏当前页面')),
    ],
  );
}

class _PanelTabs extends StatefulWidget {
  const _PanelTabs({
    this.controller,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    required this.groupId,
    required this.draggable,
    required this.onAccept,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.workbench = false,
    this.tabsAtBottom = false,
  });

  final List<WorkspacePanelId> tabs;
  final TakeALookController? controller;
  final WorkspacePanelId selected;
  final ValueChanged<WorkspacePanelId> onSelected;
  final String? groupId;
  final bool draggable;
  final void Function(PanelTabDragData, int targetIndex)? onAccept;
  final ValueChanged<PanelTabDragData>? onDragStart;
  final void Function(PanelTabDragData, DragUpdateDetails)? onDragUpdate;
  final void Function(PanelTabDragData, DraggableDetails)? onDragEnd;
  final bool workbench;
  final bool tabsAtBottom;

  @override
  State<_PanelTabs> createState() => _PanelTabsState();
}

class _PanelTabsState extends State<_PanelTabs> {
  static const _reorderDuration = Duration(milliseconds: 180);

  final GlobalKey _tabStripKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  WorkspacePanelId? _draggedPanel;
  int? _previewInsertionIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabList = ListView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      children: [
        for (var index = 0; index <= widget.tabs.length; index++) ...[
          _buildAnimatedGap(index),
          if (index < widget.tabs.length)
            _buildAnimatedTab(widget.tabs[index], index),
        ],
      ],
    );
    final strip = _tabStrip(tabList);
    final accept = widget.onAccept;
    if (!widget.draggable || accept == null) return strip;
    return DragTarget<PanelTabDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        final insertionIndex = _insertionIndexAt(details.offset);
        if (insertionIndex == null ||
            (_draggedPanel == details.data.panel &&
                _previewInsertionIndex == insertionIndex)) {
          return;
        }
        setState(() {
          _draggedPanel = details.data.panel;
          _previewInsertionIndex = insertionIndex;
        });
      },
      onLeave: (data) {
        if (data == null ||
            _draggedPanel != data.panel ||
            _previewInsertionIndex == null) {
          return;
        }
        setState(() => _previewInsertionIndex = null);
      },
      onAcceptWithDetails: (details) {
        final insertionIndex =
            _previewInsertionIndex ?? _insertionIndexAt(details.offset);
        if (insertionIndex == null) return;
        setState(() {
          _draggedPanel = null;
          _previewInsertionIndex = null;
        });
        accept(details.data, insertionIndex);
      },
      builder: (context, candidates, rejected) => strip,
    );
  }

  int? _insertionIndexAt(Offset globalPosition) {
    final renderObject = _tabStripKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return null;
    var x = renderObject.globalToLocal(globalPosition).dx;
    if (_scrollController.hasClients) x += _scrollController.offset;
    var tabLeft = 0.0;
    for (var index = 0; index < widget.tabs.length; index++) {
      final width = _tabWidth(widget.tabs[index]);
      if (x < tabLeft + width / 2) return index;
      tabLeft += width;
    }
    return widget.tabs.length;
  }

  Widget _tabStrip(Widget child) {
    return SizedBox(
      key: _tabStripKey,
      height: TalUiTheme.of(context).panelTabStripHeight,
      // Paint behind the tabs without adding a border inset to their layout.
      child: DecoratedBox(
        decoration: widget.workbench
            ? const BoxDecoration(color: WorkbenchColors.surface)
            : talPanelTabStripDecoration,
        child: Align(
          alignment: widget.tabsAtBottom
              ? Alignment.topLeft
              : Alignment.bottomLeft,
          child: child,
        ),
      ),
    );
  }

  Widget _buildAnimatedGap(int index) {
    final draggedPanel = _draggedPanel;
    final width = draggedPanel == null ? 0.0 : _tabWidth(draggedPanel);
    final expanded = _previewInsertionIndex == index;
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('panel-tab-gap-$index'),
      tween: Tween<double>(begin: 0, end: expanded ? width : 0),
      duration: _reorderDuration,
      curve: Curves.easeOutCubic,
      builder: (context, animatedWidth, child) =>
          SizedBox(width: animatedWidth, height: 29),
    );
  }

  Widget _buildAnimatedTab(WorkspacePanelId tab, int index) {
    final width = _tabWidth(tab);
    final hidden = _draggedPanel == tab;
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('panel-tab-slot-${tab.name}'),
      tween: Tween<double>(begin: width, end: hidden ? 0 : width),
      duration: _reorderDuration,
      curve: Curves.easeOutCubic,
      builder: (context, animatedWidth, child) => SizedBox(
        width: animatedWidth,
        height: 29,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: width,
            maxWidth: width,
            child: child,
          ),
        ),
      ),
      child: _buildTab(tab, index),
    );
  }

  double _tabWidth(WorkspacePanelId tab) {
    return talPanelTabWidth(
      tab,
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    );
  }

  Widget _buildTab(WorkspacePanelId tab, int index) {
    final tabWidget = Tooltip(
      message: tab.title,
      child: InkWell(
        onTap: () => widget.onSelected(tab),
        child: _tabSurface(tab),
      ),
    );
    final sourceGroupId = widget.groupId;
    if (!widget.draggable ||
        sourceGroupId == null ||
        widget.onDragEnd == null) {
      return tabWidget;
    }
    final data = PanelTabDragData(sourceGroupId: sourceGroupId, panel: tab);
    final sourceTab = Opacity(
      key: ValueKey<String>('panel-tab-drag-source-${tab.name}'),
      opacity: _draggedPanel == tab ? 0 : 1,
      child: tabWidget,
    );
    final draggableTab = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: _TabDraggable<PanelTabDragData>(
        data: data,
        rootOverlay: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          setState(() {
            _draggedPanel = tab;
            _previewInsertionIndex = index;
          });
          widget.onDragStart?.call(data);
        },
        onDragUpdate: (details) => widget.onDragUpdate?.call(data, details),
        onDragEnd: (details) {
          if (mounted) {
            setState(() {
              _draggedPanel = null;
              _previewInsertionIndex = null;
            });
          }
          widget.onDragEnd!(data, details);
        },
        feedback: SizedBox(
          key: ValueKey<String>('panel-tab-drag-feedback-${tab.name}'),
          width: 1,
          height: 1,
        ),
        childWhenDragging: const SizedBox.shrink(),
        child: sourceTab,
      ),
    );
    return draggableTab;
  }

  Widget _tabSurface(WorkspacePanelId tab) {
    Widget surface(double attention, bool unread) => TalPanelTabSurface(
      tab: tab,
      selected: tab == widget.selected,
      width: _tabWidth(tab),
      surfaceKey: ValueKey<String>('panel-tab-${tab.name}'),
      attention: attention,
      unread: unread,
      workbench: widget.workbench,
      tabsAtBottom: widget.tabsAtBottom,
    );
    final controller = widget.controller;
    return tab == WorkspacePanelId.sourceDebug && controller != null
        ? _SourceTabAttention(controller: controller, builder: surface)
        : surface(0, false);
  }
}

class _TabDraggable<T extends Object> extends Draggable<T> {
  const _TabDraggable({
    required super.data,
    required super.feedback,
    required super.child,
    super.childWhenDragging,
    super.rootOverlay,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _TabMultiDragGestureRecognizer(
      mouseDragSlop: _talPanelTabMouseDragSlop,
      allowedButtonsFilter: allowedButtonsFilter,
    )..onStart = onStart;
  }
}

class _TabMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  _TabMultiDragGestureRecognizer({
    required this.mouseDragSlop,
    super.allowedButtonsFilter,
  }) : super(debugOwner: null);

  final double mouseDragSlop;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _TabMultiDragPointerState(
      event.position,
      event.kind,
      gestureSettings,
      mouseDragSlop,
    );
  }

  @override
  String get debugDescription => 'tab multidrag';
}

class _TabMultiDragPointerState extends MultiDragPointerState {
  _TabMultiDragPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    this.mouseDragSlop,
  );

  final double mouseDragSlop;

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta;
    if (delta == null) return;
    final platformSlop = computeHitSlop(kind, gestureSettings);
    if (delta.distance > math.max(mouseDragSlop, platformSlop)) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}
