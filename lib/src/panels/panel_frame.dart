part of '../panels.dart';

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
      key: ValueKey<String>('panel-frame-${widget.panel.name}'),
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
                  height: 34,
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
                          width: 26,
                          height: 28,
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
                        IconButton(
                          tooltip: '弹出为独立窗口',
                          onPressed: chrome.onFloat,
                          icon: const Icon(Icons.open_in_new, size: 15),
                        ),
                      if (chrome != null &&
                          chrome.showActions &&
                          tabs.length > 1)
                        IconButton(
                          tooltip: '从组合中拆分当前面板',
                          onPressed: chrome.onSeparate,
                          icon: const Icon(Icons.call_split, size: 15),
                        ),
                      if (chrome != null && chrome.showActions)
                        IconButton(
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
                onDragEnd: chrome.onTabDragEnd,
              ),
            if (!collapsed) Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }
}

class _PanelTabs extends StatelessWidget {
  const _PanelTabs({
    required this.tabs,
    required this.selected,
    required this.onSelected,
    required this.groupId,
    required this.draggable,
    required this.onAccept,
    required this.onDragEnd,
  });

  final List<WorkspacePanelId> tabs;
  final WorkspacePanelId selected;
  final ValueChanged<WorkspacePanelId> onSelected;
  final String? groupId;
  final bool draggable;
  final void Function(PanelTabDragData, int targetIndex)? onAccept;
  final void Function(PanelTabDragData, DraggableDetails)? onDragEnd;

  @override
  Widget build(BuildContext context) {
    return _tabStrip(
      ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (index, tab) in tabs.indexed) _buildTab(tab, index),
        ],
      ),
    );
  }

  Widget _tabStrip(Widget child) {
    return Container(
      height: 30,
      color: TalColors.surface,
      alignment: Alignment.bottomLeft,
      child: child,
    );
  }

  Widget _buildTab(WorkspacePanelId tab, int index) {
    final tabWidget = InkWell(
      onTap: () => onSelected(tab),
      child: _tabSurface(tab),
    );
    final sourceGroupId = groupId;
    if (!draggable || sourceGroupId == null || onDragEnd == null) {
      return tabWidget;
    }
    final data = PanelTabDragData(sourceGroupId: sourceGroupId, panel: tab);
    final draggableTab = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<PanelTabDragData>(
        data: data,
        rootOverlay: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () => onSelected(tab),
        onDragEnd: (details) => onDragEnd!(data, details),
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.92, child: _tabSurface(tab)),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: tabWidget),
        child: tabWidget,
      ),
    );
    final accept = onAccept;
    if (accept == null) return draggableTab;
    return DragTarget<PanelTabDragData>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => accept(details.data, index),
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty ? null : TalColors.surfaceAlt,
          border: candidates.isEmpty
              ? null
              : Border.all(color: TalColors.accent),
        ),
        child: draggableTab,
      ),
    );
  }

  Widget _tabSurface(WorkspacePanelId tab) {
    return Container(
      key: ValueKey<String>('panel-tab-${tab.name}'),
      height: 29,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tab == selected ? TalColors.surface : TalColors.surfaceAlt,
        border: Border(
          top: BorderSide(
            color: tab == selected ? TalColors.accent : TalColors.border,
            width: tab == selected ? 2 : 1,
          ),
          right: const BorderSide(color: TalColors.border),
          bottom: BorderSide(
            color: tab == selected ? TalColors.surface : TalColors.border,
          ),
        ),
      ),
      child: Center(child: Text(tab.title, style: talBody)),
    );
  }
}
