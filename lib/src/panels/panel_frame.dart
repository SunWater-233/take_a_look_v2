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
    super.key,
  });

  final WorkspacePanelId tab;
  final bool selected;
  final double? width;
  final Key? surfaceKey;

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
        color: selected ? TalColors.surface : TalColors.surfaceAlt,
        border: Border(
          top: BorderSide(
            color: selected ? TalColors.accent : TalColors.border,
            width: selected ? 2 : 1,
          ),
          right: const BorderSide(color: TalColors.border),
          bottom: BorderSide(
            color: selected ? TalColors.surface : TalColors.border,
          ),
        ),
      ),
      child: Center(
        child: Text(
          tab.title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: talBody,
        ),
      ),
    );
  }
}

class TalPanelFrame extends StatefulWidget {
  const TalPanelFrame({
    required this.panel,
    required this.child,
    this.chrome,
    super.key,
  });

  final WorkspacePanelId panel;
  final Widget child;
  final PanelChrome? chrome;

  @override
  State<TalPanelFrame> createState() => _TalPanelFrameState();
}

class _TalPanelFrameState extends State<TalPanelFrame> {
  bool collapsed = false;

  @override
  Widget build(BuildContext context) {
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
                        child: Text(
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
}

class _PanelTabs extends StatefulWidget {
  const _PanelTabs({
    required this.tabs,
    required this.selected,
    required this.onSelected,
    required this.groupId,
    required this.draggable,
    required this.onAccept,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final List<WorkspacePanelId> tabs;
  final WorkspacePanelId selected;
  final ValueChanged<WorkspacePanelId> onSelected;
  final String? groupId;
  final bool draggable;
  final void Function(PanelTabDragData, int targetIndex)? onAccept;
  final ValueChanged<PanelTabDragData>? onDragStart;
  final void Function(PanelTabDragData, DragUpdateDetails)? onDragUpdate;
  final void Function(PanelTabDragData, DraggableDetails)? onDragEnd;

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
    return Container(
      key: _tabStripKey,
      height: TalUiTheme.of(context).panelTabStripHeight,
      color: TalColors.surface,
      alignment: Alignment.bottomLeft,
      child: child,
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
    final tabWidget = InkWell(
      onTap: () => widget.onSelected(tab),
      child: _tabSurface(tab),
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
    return TalPanelTabSurface(
      tab: tab,
      selected: tab == widget.selected,
      width: _tabWidth(tab),
      surfaceKey: ValueKey<String>('panel-tab-${tab.name}'),
    );
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
