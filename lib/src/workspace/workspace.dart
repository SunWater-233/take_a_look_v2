import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/controller.dart';
import 'detached_window_coordinator.dart';
import 'panel_types.dart';
import '../panels/panels.dart';
import 'tab_drag_preview_coordinator.dart';
import '../theme/theme.dart';
import 'window_sync.dart';
import 'workspace_geometry.dart';
import 'workspace_layout.dart';
import 'workspace_session.dart';
import 'workspace_widgets.dart';

const _geometry = WorkspaceGeometry();

class DockingWorkspace extends StatefulWidget {
  const DockingWorkspace({
    required this.controller,
    required this.windowSync,
    this.layoutFile,
    this.onPanelVisibilityChanged,
    this.workbenchLayout = false,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;
  final File? layoutFile;
  final VoidCallback? onPanelVisibilityChanged;
  final bool workbenchLayout;

  @override
  DockingWorkspaceState createState() => DockingWorkspaceState();
}

class DockingWorkspaceState extends State<DockingWorkspace> {
  late final DetachedWindowCoordinator detachedWindows;
  late final TabDragPreviewCoordinator tabDragPreview;
  final Map<WorkspacePanelId, DetachedPanelPlacement> _detachedPlacements =
      <WorkspacePanelId, DetachedPanelPlacement>{};
  StreamSubscription<void>? windowSubscription;
  StreamSubscription<DetachedTabDragEvent>? detachedTabDragSubscription;
  final WorkspaceSession _session = WorkspaceSession();
  Timer? _tabMergeTimer;
  String? _tabMergeCandidate;
  String? _armedTabMergeTarget;
  String? _draggedTabSource;
  Offset _mainWindowOrigin = Offset.zero;
  Offset _tabDragPreviewAnchor = Offset.zero;
  Offset? _lastTabDragPreviewPosition;
  String? _detachedDragSourceWindowId;
  WorkspacePanelId? _detachedDraggedPanel;
  int _sourceAdditionRevision = 0;
  bool _legacyLayout = false;
  WorkspacePanelId _workbenchView = WorkspacePanelId.plot;
  bool _focusedWorkbench = false;
  bool _automaticWorkbenchLayout = true;

  bool get usesWorkbenchLayout => widget.workbenchLayout && !_legacyLayout;
  WorkspacePanelId get workbenchView => _workbenchView;
  bool get resourceDocked => _session.groups.any(
    (group) => group.panels.contains(WorkspacePanelId.symbols),
  );
  bool get outputDocked => _session.groups.any(
    (group) => group.panels.contains(WorkspacePanelId.log),
  );
  bool get focusedWorkbench => _focusedWorkbench;
  WorkspaceGroup? get _primaryGroup =>
      _session.groups.where((group) => group.id == 'plot').firstOrNull;
  bool get _expandedAnalysis =>
      usesWorkbenchLayout &&
      _primaryGroup?.activePanel == WorkspacePanelId.analysis &&
      _session.groups.any(
        (group) =>
            group.id == 'watch' &&
            group.panels.length == 1 &&
            (group.rect.left - (_primaryGroup?.rect.right ?? 0)).abs() < .001,
      );

  Future<void> activateWorkbenchView(WorkspacePanelId panel) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    var group = _session.groups
        .where((group) => group.panels.contains(panel))
        .firstOrNull;
    if (group == null) {
      group = _primaryGroup;
      if (group != null) {
        group.panels.add(panel);
      } else {
        group = WorkspaceGroup(
          id: 'plot',
          panels: [panel],
          activePanel: panel,
          rect: const Rect.fromLTWH(0, 0, .72, 1),
          z: ++_session.zCursor,
        );
        _session.groups.add(group);
      }
    }
    _selectGroupPanel(group, panel);
  }

  void _selectGroupPanel(WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() {
      group.activePanel = panel;
      if (const [
        WorkspacePanelId.plot,
        WorkspacePanelId.sourceDebug,
        WorkspacePanelId.analysis,
      ].contains(panel)) {
        _workbenchView = panel;
      }
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void toggleWorkbenchFocus() {
    setState(() => _focusedWorkbench = !_focusedWorkbench);
    widget.onPanelVisibilityChanged?.call();
  }

  Future<void> toggleWorkbenchResource() async {
    if (await detachedWindows.showIfOpen(WorkspacePanelId.symbols)) return;
    final existing = _session.groups
        .where((group) => group.panels.contains(WorkspacePanelId.symbols))
        .firstOrNull;
    setState(() {
      if (existing != null) {
        _detachPanel(existing, WorkspacePanelId.symbols);
      } else {
        _session.groups.add(
          WorkspaceGroup(
            id: 'resources',
            panels: [WorkspacePanelId.symbols],
            activePanel: WorkspacePanelId.symbols,
            rect: const Rect.fromLTWH(0, 0, .2, 1),
            z: ++_session.zCursor,
          ),
        );
      }
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
  }

  Future<void> toggleWorkbenchOutput() async {
    if (await detachedWindows.showIfOpen(WorkspacePanelId.log)) return;
    final existing = _session.groups
        .where((group) => group.panels.contains(WorkspacePanelId.log))
        .firstOrNull;
    setState(() {
      if (existing != null) {
        _detachPanel(existing, WorkspacePanelId.log);
      } else {
        _session.groups.add(
          WorkspaceGroup(
            id: 'output',
            panels: [WorkspacePanelId.log],
            activePanel: WorkspacePanelId.log,
            rect: const Rect.fromLTWH(0, .76, 1, .24),
            z: ++_session.zCursor,
          ),
        );
      }
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void _reflowWorkbench() {
    if (!usesWorkbenchLayout) return;
    final left = _session.groups.any((group) => group.id == 'resources')
        ? .20
        : 0.0;
    final height = _session.groups.any((group) => group.id == 'output')
        ? .76
        : 1.0;
    final watchGroup = _session.groups
        .where((group) => group.id == 'watch')
        .firstOrNull;
    final sidebarWidth = _session.workspaceSize.width <= 0
        ? .28
        : (340 / _session.workspaceSize.width).clamp(.18, .42);
    final right = watchGroup == null
        ? 1.0
        : _automaticWorkbenchLayout
        ? 1 - sidebarWidth
        : watchGroup.rect.left;
    for (final group in _session.groups) {
      if (group.id == 'plot') {
        group.rect = Rect.fromLTWH(left, 0, right - left, height);
      }
      if (group.id == 'watch') {
        group.rect = Rect.fromLTWH(right, 0, 1 - right, height);
      }
      if (group.id == 'resources') {
        group.rect = Rect.fromLTWH(0, 0, .20, height);
      }
    }
  }

  @visibleForTesting
  String? get debugTabMergeCandidate => _tabMergeCandidate;

  @override
  void initState() {
    super.initState();
    detachedWindows = DetachedWindowCoordinator(widget.windowSync);
    tabDragPreview = TabDragPreviewCoordinator(
      prepareState: (window, panel) =>
          widget.windowSync.prepareWindow(window, [panel]),
    );
    _applyDefaultLayout();
    _sourceAdditionRevision =
        widget.controller.sourceWorkspace.additionRevision;
    widget.controller.sourceWorkspaceChanges.addListener(_handleSourceAddition);
    windowSubscription = detachedWindows.changes.listen(
      (_) => _syncExternalWindows(),
    );
    detachedTabDragSubscription = widget.windowSync.detachedTabDrags.listen(
      _handleDetachedTabDrag,
    );
    if (widget.windowSync.isStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(detachedWindows.prewarm());
        unawaited(tabDragPreview.prewarm());
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_captureMainWindowOrigin());
    });
    unawaited(_restoreLayout(reportMissing: false));
  }

  @override
  void dispose() {
    widget.controller.sourceWorkspaceChanges.removeListener(
      _handleSourceAddition,
    );
    windowSubscription?.cancel();
    detachedTabDragSubscription?.cancel();
    _tabMergeTimer?.cancel();
    unawaited(tabDragPreview.dispose());
    unawaited(detachedWindows.dispose());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DockingWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.sourceWorkspaceChanges.removeListener(
        _handleSourceAddition,
      );
      widget.controller.sourceWorkspaceChanges.addListener(
        _handleSourceAddition,
      );
      _sourceAdditionRevision =
          widget.controller.sourceWorkspace.additionRevision;
    }
  }

  void _handleSourceAddition() {
    final revision = widget.controller.sourceWorkspace.additionRevision;
    if (!mounted || revision == _sourceAdditionRevision) return;
    _sourceAdditionRevision = revision;
    if (isPanelVisible(WorkspacePanelId.sourceDebug)) return;
    final plotGroup = _session.groups
        .where((group) => group.panels.contains(WorkspacePanelId.plot))
        .firstOrNull;
    if (plotGroup != null) {
      setState(() => plotGroup.panels.add(WorkspacePanelId.sourceDebug));
      widget.onPanelVisibilityChanged?.call();
    } else {
      unawaited(showPanel(WorkspacePanelId.sourceDebug));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final resized = _session.workspaceSize != size;
        _session.workspaceSize = size;
        if (resized && _automaticWorkbenchLayout) _reflowWorkbench();
        final sorted = _session.groupsByZ;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (_) => unawaited(tabDragPreview.hide()),
          onPointerCancel: (_) => unawaited(tabDragPreview.hide()),
          child: ClipRect(
            child: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: TalColors.background),
                ),
                if (_session.gridMode)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: ValueKey<String>('workspace-grid'),
                        painter: WorkspaceGridPainter(),
                      ),
                    ),
                  ),
                for (final group in sorted)
                  if ((!_expandedAnalysis || group.id != 'watch') &&
                      (!_focusedWorkbench || group == _primaryGroup))
                    _buildGroup(group, size),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGroup(WorkspaceGroup group, Size workspaceSize) {
    final expanded =
        group == _primaryGroup && (_expandedAnalysis || _focusedWorkbench);
    final effectiveRect = expanded
        ? (_focusedWorkbench
              ? const Rect.fromLTWH(0, 0, 1, 1)
              : Rect.fromLTRB(
                  group.rect.left,
                  group.rect.top,
                  1,
                  group.rect.bottom,
                ))
        : group.rect;
    final rawRect = _toPixelRect(effectiveRect, workspaceSize);
    final rect = rawRect.deflate(1.5);
    return Positioned(
      key: ValueKey('workspace-group-${group.id}'),
      left: rect.left,
      top: rect.top,
      width: math.max(1, rect.width),
      height: math.max(1, rect.height),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) {
          final y = details.localPosition.dy;
          final isTabStrip =
              group.panels.length > 1 &&
              y >= TalUiTheme.of(context).panelHeaderHeight &&
              y <
                  TalUiTheme.of(context).panelHeaderHeight +
                      TalUiTheme.of(context).panelTabStripHeight;
          if (!isTabStrip) _bringToFront(group);
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<WorkspacePanelId>(
                valueListenable: group.activePanelListenable,
                builder: (context, activePanel, _) => buildWorkspacePanel(
                  activePanel,
                  widget.controller,
                  workbench: usesWorkbenchLayout,
                  onShowSource: () => unawaited(
                    activateWorkbenchView(WorkspacePanelId.sourceDebug),
                  ),
                  onShowSymbols: () {
                    if (!resourceDocked) unawaited(toggleWorkbenchResource());
                  },
                  chrome: PanelChrome(
                    tabs: List.unmodifiable(group.panels),
                    activePanel: activePanel,
                    highlighted: _session.mergeTarget == group.id,
                    onSelect: (panel) => _selectGroupPanel(group, panel),
                    onFloat: () =>
                        _floatPanel(group, activePanel, workspaceSize),
                    onClose: () => _hidePanel(group, activePanel),
                    onSeparate: () => _separatePanel(group, activePanel),
                    onDragStart: (_) => _startDrag(group),
                    onDragUpdate: (details) =>
                        _moveGroup(group, details.delta, workspaceSize),
                    onDragEnd: (_) => _endDrag(group),
                    draggable: _session.gridMode && !expanded,
                    groupId: group.id,
                    tabsDraggable: true,
                    onTabAccept: (data, targetIndex) =>
                        _acceptTabDrop(group, data, targetIndex),
                    onTabDragStart: (data) =>
                        _startTabDrag(group, data, workspaceSize),
                    onTabDragUpdate: (data, details) =>
                        _updateTabDrag(data, details, workspaceSize),
                    onTabDragEnd: (data, details) =>
                        _finishTabDrag(group, data, details, workspaceSize),
                  ),
                ),
              ),
            ),
            WorkspaceResizeHandle(
              handleKey: ValueKey('resize-${group.id}-left'),
              alignment: Alignment.centerLeft,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              enabled: !expanded,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, left: true),
            ),
            WorkspaceResizeHandle(
              handleKey: ValueKey('resize-${group.id}-right'),
              alignment: Alignment.centerRight,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              enabled: !expanded,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, right: true),
            ),
            WorkspaceResizeHandle(
              handleKey: ValueKey('resize-${group.id}-top'),
              alignment: Alignment.topCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              enabled: !expanded,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, top: true),
            ),
            WorkspaceResizeHandle(
              handleKey: ValueKey('resize-${group.id}-bottom'),
              alignment: Alignment.bottomCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              enabled: !expanded,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, bottom: true),
            ),
            WorkspaceResizeHandle(
              handleKey: ValueKey('resize-${group.id}'),
              alignment: Alignment.bottomRight,
              cursor: SystemMouseCursors.resizeDownRight,
              width: 18,
              height: 18,
              enabled: !expanded,
              visible: true,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) => _resizeGroup(
                group,
                delta,
                workspaceSize,
                right: true,
                bottom: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _applyDefaultLayout() {
    _automaticWorkbenchLayout = true;
    _legacyLayout = false;
    _workbenchView = WorkspacePanelId.plot;
    _focusedWorkbench = false;
    _session.groups
      ..clear()
      ..addAll(
        widget.workbenchLayout
            ? [
                WorkspaceGroup(
                  id: 'plot',
                  panels: const [
                    WorkspacePanelId.plot,
                    WorkspacePanelId.sourceDebug,
                    WorkspacePanelId.analysis,
                  ],
                  activePanel: WorkspacePanelId.plot,
                  rect: const Rect.fromLTWH(0, 0, .72, 1),
                  z: 1,
                ),
                WorkspaceGroup(
                  id: 'watch',
                  panels: const [WorkspacePanelId.watch],
                  activePanel: WorkspacePanelId.watch,
                  rect: const Rect.fromLTWH(.72, 0, .28, 1),
                  z: 2,
                ),
              ]
            : [
                WorkspaceGroup(
                  id: 'header',
                  panels: const [
                    WorkspacePanelId.header,
                    WorkspacePanelId.runControl,
                    WorkspacePanelId.sampling,
                  ],
                  activePanel: WorkspacePanelId.header,
                  rect: const Rect.fromLTWH(0, 0, 0.22, 0.18),
                  z: 1,
                ),
                WorkspaceGroup(
                  id: 'symbols',
                  panels: const [
                    WorkspacePanelId.symbols,
                    WorkspacePanelId.watch,
                    WorkspacePanelId.connection,
                  ],
                  activePanel: WorkspacePanelId.symbols,
                  rect: const Rect.fromLTWH(0, 0.18, 0.22, 0.58),
                  z: 2,
                ),
                WorkspaceGroup(
                  id: 'plot',
                  panels: const [
                    WorkspacePanelId.plot,
                    WorkspacePanelId.sourceDebug,
                  ],
                  activePanel: WorkspacePanelId.plot,
                  rect: const Rect.fromLTWH(0.22, 0, 0.78, 0.76),
                  z: 3,
                ),
                WorkspaceGroup(
                  id: 'log',
                  panels: const [WorkspacePanelId.log],
                  activePanel: WorkspacePanelId.log,
                  rect: const Rect.fromLTWH(0, 0.76, 1, 0.24),
                  z: 4,
                ),
              ],
      );
    for (final panel in detachedWindows.windows.keys) {
      final group = _session.groups
          .where((candidate) => candidate.panels.contains(panel))
          .firstOrNull;
      if (group != null) _detachPanel(group, panel);
    }
    _reflowWorkbench();
    if (_session.gridMode) {
      for (final group in _session.groups) {
        group.rect = _snapRectToGrid(group.rect);
      }
    }
  }

  Future<void> saveLayout() async {
    try {
      await _layoutRepository.save(
        WorkspaceLayoutSnapshot(
          groups: _session.groups,
          uiScale: widget.controller.uiScale,
          version: widget.workbenchLayout ? 2 : 1,
          legacyPanels: _legacyLayout,
        ),
      );
      widget.controller.report('工作区布局已保存。');
    } on Object catch (error) {
      widget.controller.report('保存布局失败：$error');
    }
  }

  Future<void> restoreLayout() => _restoreLayout();

  Future<void> _restoreLayout({bool reportMissing = true}) async {
    try {
      final layout = await _layoutRepository.load();
      if (!mounted) return;
      if (layout == null) {
        if (reportMissing) widget.controller.report('尚未保存过工作区布局。');
        return;
      }
      if (widget.workbenchLayout && layout.version == 1 && !reportMissing) {
        widget.controller.report('已启用横向工作台。旧布局已保留，可在“视图”中恢复。');
        return;
      }
      final restored = <WorkspaceGroup>[];
      final seenPanels = <WorkspacePanelId>{};
      for (final group in layout.groups) {
        group.panels.removeWhere(
          (panel) =>
              detachedWindows.windows.containsKey(panel) ||
              !seenPanels.add(panel),
        );
        if (group.panels.isEmpty) continue;
        if (!group.panels.contains(group.activePanel)) {
          group.activePanel = group.panels.first;
        }
        group.rect = _session.gridMode
            ? _snapRectToGrid(group.rect)
            : _clampRect(group.rect);
        restored.add(group);
      }
      setState(() {
        _legacyLayout = layout.version == 1 || layout.legacyPanels;
        _automaticWorkbenchLayout = false;
        _session.groups
          ..clear()
          ..addAll(restored);
        final active = _primaryGroup?.activePanel;
        if (active != null) _workbenchView = active;
        _session.zCursor = _session.groups.fold(
          20,
          (value, group) => math.max(value, group.z),
        );
      });
      widget.onPanelVisibilityChanged?.call();
      widget.controller.setUiScale(layout.uiScale);
      widget.controller.report('已恢复保存的工作区布局');
    } on Object catch (error) {
      if (mounted) widget.controller.report('恢复布局失败：$error');
    }
  }

  void resetLayout() {
    setState(_applyDefaultLayout);
    widget.onPanelVisibilityChanged?.call();
    widget.controller.report('已重置为默认工作区布局。');
  }

  bool isPanelVisible(WorkspacePanelId panel) {
    return detachedWindows.windows.containsKey(panel) ||
        _session.groups.any((group) => group.panels.contains(panel));
  }

  void setGridMode(bool value) {
    if (_session.gridMode == value) return;
    setState(() {
      _session.gridMode = value;
      _session.resetDrag();
      _session.resetResize();
      if (value) {
        for (final group in _session.groups) {
          group.rect = _snapRectToGrid(group.rect);
        }
      }
    });
  }

  Future<void> togglePanelVisibility(WorkspacePanelId panel) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    final group = _session.groups
        .where((candidate) => candidate.panels.contains(panel))
        .firstOrNull;
    if (group == null) {
      await showPanel(panel);
      return;
    }
    _hidePanel(group, panel);
  }

  Future<void> showPanel(WorkspacePanelId panel) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    if (_session.groups.any((group) => group.panels.contains(panel))) return;
    final window = await detachedWindows.acquire(
      activePanel: panel,
      panels: <WorkspacePanelId>[panel],
      initialSize: panel.preferredWindowSize,
    );
    if (!mounted) return;
    widget.onPanelVisibilityChanged?.call();
    await window.show();
    if (widget.windowSync.isStarted) unawaited(detachedWindows.prewarm());
  }

  WorkspaceLayoutRepository get _layoutRepository => WorkspaceLayoutRepository(
    widget.layoutFile ?? WorkspaceLayoutRepository.defaultFile(),
  );

  void _startDrag(WorkspaceGroup group) {
    if (!_session.gridMode) return;
    _automaticWorkbenchLayout = false;
    setState(() {
      _session.dragRemainder = Offset.zero;
      _session.draggingGroup = group.id;
      _bringToFront(group, notify: false);
    });
  }

  void _moveGroup(WorkspaceGroup group, Offset delta, Size workspaceSize) {
    if (!_session.gridMode || workspaceSize.isEmpty) return;
    final totalDelta = Offset(
      _session.dragRemainder.dx + delta.dx / workspaceSize.width,
      _session.dragRemainder.dy + delta.dy / workspaceSize.height,
    );
    final snappedDelta = Offset(
      _wholeGridDelta(
        totalDelta.dx,
        _geometry.gridCellSize / workspaceSize.width,
      ),
      _wholeGridDelta(
        totalDelta.dy,
        _geometry.gridCellSize / workspaceSize.height,
      ),
    );
    if (snappedDelta == Offset.zero) {
      _session.dragRemainder = totalDelta;
      return;
    }
    setState(() {
      final previousRect = group.rect;
      group.rect = _clampRect(
        group.rect.translate(snappedDelta.dx, snappedDelta.dy),
      );
      final actualDelta = group.rect.topLeft - previousRect.topLeft;
      _session.dragRemainder = Offset(
        _near(actualDelta.dx, snappedDelta.dx)
            ? totalDelta.dx - snappedDelta.dx
            : 0,
        _near(actualDelta.dy, snappedDelta.dy)
            ? totalDelta.dy - snappedDelta.dy
            : 0,
      );
      _session.mergeTarget = _findMergeTarget(group);
    });
  }

  void _endDrag(WorkspaceGroup group) {
    if (!_session.gridMode) return;
    setState(() {
      final target = _findMergeTarget(group);
      _session.resetDrag();
      if (target != null) _mergeInto(group, target);
    });
  }

  void _resizeGroup(
    WorkspaceGroup group,
    Offset delta,
    Size workspaceSize, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    if (workspaceSize.isEmpty) return;
    if (!_session.gridMode) {
      setState(() {
        if (left || right) {
          _resizeAxis(
            group,
            delta.dx / workspaceSize.width,
            horizontal: true,
            movingEnd: right,
          );
        }
        if (top || bottom) {
          _resizeAxis(
            group,
            delta.dy / workspaceSize.height,
            horizontal: false,
            movingEnd: bottom,
          );
        }
        _session.mergeTarget = null;
        _bringToFront(group, notify: false);
      });
      return;
    }
    setState(() {
      if (left || right) {
        final total =
            _session.resizeRemainder.dx + delta.dx / workspaceSize.width;
        final requested = _wholeGridDelta(
          total,
          _geometry.gridCellSize / workspaceSize.width,
        );
        if (requested != 0) {
          final applied = _resizeAxis(
            group,
            requested,
            horizontal: true,
            movingEnd: right,
          );
          _session.resizeRemainder = Offset(
            _near(applied, requested) ? total - requested : 0,
            _session.resizeRemainder.dy,
          );
        } else {
          _session.resizeRemainder = Offset(total, _session.resizeRemainder.dy);
        }
      }
      if (top || bottom) {
        final total =
            _session.resizeRemainder.dy + delta.dy / workspaceSize.height;
        final requested = _wholeGridDelta(
          total,
          _geometry.gridCellSize / workspaceSize.height,
        );
        if (requested != 0) {
          final applied = _resizeAxis(
            group,
            requested,
            horizontal: false,
            movingEnd: bottom,
          );
          _session.resizeRemainder = Offset(
            _session.resizeRemainder.dx,
            _near(applied, requested) ? total - requested : 0,
          );
        } else {
          _session.resizeRemainder = Offset(_session.resizeRemainder.dx, total);
        }
      }
      _session.mergeTarget = null;
      _bringToFront(group, notify: false);
    });
  }

  double _resizeAxis(
    WorkspaceGroup group,
    double requestedDelta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final participants = _session.gridMode
        ? <WorkspaceGroup, bool>{group: movingEnd}
        : _geometry.resizeParticipants(
            _session.groups,
            group,
            horizontal: horizontal,
            movingEnd: movingEnd,
          );
    final delta = _geometry.constrainedBoundaryDelta(
      participants,
      requestedDelta,
      horizontal: horizontal,
    );
    if (delta == 0) return 0;

    for (final entry in participants.entries) {
      entry.key.rect = _geometry.moveBoundary(
        entry.key.rect,
        delta,
        horizontal: horizontal,
        movingEnd: entry.value,
      );
    }
    return delta;
  }

  void _startResize() {
    _automaticWorkbenchLayout = false;
    _session.resetResize();
  }

  void _endResize() => _session.resetResize();

  double _wholeGridDelta(double value, double unit) {
    return _geometry.wholeGridDelta(value, unit);
  }

  bool _near(double first, double second) => _geometry.near(first, second);

  Future<void> _floatPanel(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Size workspaceSize,
  ) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    final panels = List<WorkspacePanelId>.of(group.panels);
    final activePanel = group.activePanel;
    final window = await detachedWindows.acquire(
      activePanel: activePanel,
      panels: panels,
      initialSize: _toPixelRect(group.rect, workspaceSize).size,
    );
    if (!mounted) return;
    setState(() {
      final placement = DetachedPanelPlacement(
        groupId: group.id,
        groupRect: group.rect,
        groupZ: group.z,
        panels: panels,
        originalPanels: panels,
        activePanel: activePanel,
      );
      for (final groupPanel in panels) {
        _detachedPlacements[groupPanel] = placement;
      }
      _session.groups.remove(group);
      if (const ['resources', 'output', 'watch'].contains(group.id)) {
        _reflowWorkbench();
      }
    });
    widget.onPanelVisibilityChanged?.call();
    await window.show();
    if (widget.windowSync.isStarted) unawaited(detachedWindows.prewarm());
  }

  Future<void> _floatSinglePanel(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Size workspaceSize, {
    Offset? initialPosition,
  }) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    final originalPanels = List<WorkspacePanelId>.of(group.panels);
    final window = await detachedWindows.acquire(
      activePanel: panel,
      panels: <WorkspacePanelId>[panel],
      initialSize: _toPixelRect(group.rect, workspaceSize).size,
      initialPosition: initialPosition,
    );
    if (!mounted || !group.panels.contains(panel)) return;
    setState(() {
      _detachedPlacements[panel] = DetachedPanelPlacement(
        groupId: group.id,
        groupRect: group.rect,
        groupZ: group.z,
        panels: <WorkspacePanelId>[panel],
        originalPanels: originalPanels,
        activePanel: panel,
      );
      _detachPanel(group, panel);
      if (const ['resources', 'output', 'watch'].contains(group.id)) {
        _reflowWorkbench();
      }
    });
    widget.onPanelVisibilityChanged?.call();
    await window.show();
    if (widget.windowSync.isStarted) unawaited(detachedWindows.prewarm());
  }

  void _detachPanel(WorkspaceGroup group, WorkspacePanelId panel) {
    group.panels.remove(panel);
    if (group.panels.isEmpty) {
      _session.groups.remove(group);
    } else if (group.activePanel == panel) {
      group.activePanel = group.panels.first;
    }
  }

  void _hidePanel(WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() {
      _detachPanel(group, panel);
      if (const ['resources', 'output', 'watch'].contains(group.id)) {
        _reflowWorkbench();
      }
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void _separatePanel(WorkspaceGroup group, WorkspacePanelId panel) {
    if (group.panels.length < 2) return;
    _separatePanelToRect(
      group,
      panel,
      _clampRect(group.rect.translate(0.025, 0.025)),
    );
  }

  void _separatePanelToRect(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Rect rect,
  ) {
    if (_session.gridMode) rect = _snapRectToGrid(rect);
    setState(() {
      _detachPanel(group, panel);
      _session.groups.add(
        WorkspaceGroup(
          id: _session.nextGroupId('separated'),
          panels: [panel],
          activePanel: panel,
          rect: rect,
          z: _nextZ(),
        ),
      );
    });
  }

  void _acceptTabDrop(
    WorkspaceGroup target,
    PanelTabDragData data,
    int insertionIndex,
  ) {
    final source = _session.groups
        .where((group) => group.id == data.sourceGroupId)
        .firstOrNull;
    if (source == null || !source.panels.contains(data.panel)) return;
    if (source == target) {
      final sourceIndex = target.panels.indexOf(data.panel);
      var adjustedIndex = insertionIndex.clamp(0, target.panels.length);
      if (sourceIndex < adjustedIndex) adjustedIndex -= 1;
      setState(() {
        target.panels.removeAt(sourceIndex);
        target.panels.insert(adjustedIndex, data.panel);
        target.activePanel = data.panel;
      });
      return;
    }
    setState(() {
      _detachPanel(source, data.panel);
      if (!target.panels.contains(data.panel)) {
        target.panels.insert(
          insertionIndex.clamp(0, target.panels.length),
          data.panel,
        );
      }
      target.activePanel = data.panel;
      target.z = _nextZ();
    });
  }

  void _finishTabDrag(
    WorkspaceGroup source,
    PanelTabDragData data,
    DraggableDetails details,
    Size workspaceSize,
  ) {
    final mergeTargetId = _armedTabMergeTarget;
    final previewPosition = _lastTabDragPreviewPosition;
    _resetTabDragState();
    if (details.wasAccepted || !source.panels.contains(data.panel)) {
      unawaited(tabDragPreview.hide());
      return;
    }
    if (mergeTargetId != null) {
      final target = _session.groups
          .where((group) => group.id == mergeTargetId)
          .firstOrNull;
      if (target != null && target != source) {
        unawaited(tabDragPreview.hide());
        _acceptTabDrop(target, data, target.panels.length);
        return;
      }
    }
    unawaited(
      _detachTabAfterPreview(
        source,
        data.panel,
        workspaceSize,
        previewPosition,
      ),
    );
  }

  Future<void> _detachTabAfterPreview(
    WorkspaceGroup source,
    WorkspacePanelId panel,
    Size workspaceSize,
    Offset? previewPosition,
  ) async {
    await tabDragPreview.hide().timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );
    await _floatSinglePanel(
      source,
      panel,
      workspaceSize,
      initialPosition: previewPosition,
    );
  }

  void _startTabDrag(
    WorkspaceGroup source,
    PanelTabDragData data,
    Size workspaceSize,
  ) {
    _automaticWorkbenchLayout = false;
    _resetTabDragState(notify: false);
    setState(() {
      _draggedTabSource = source.id;
      if (source.activePanel == data.panel && source.panels.length > 1) {
        final draggedIndex = source.panels.indexOf(data.panel);
        final fallbackIndex = draggedIndex > 0 ? draggedIndex - 1 : 1;
        source.activePanel = source.panels[fallbackIndex];
      }
    });
    final sourceSize = _toPixelRect(source.rect, workspaceSize).size;
    final previewSize = Size(
      sourceSize.width,
      math.max(
        TalUiTheme.of(context).panelTabStripHeight + 1,
        sourceSize.height - TalUiTheme.of(context).panelHeaderHeight,
      ),
    );
    final tabWidth = talPanelTabWidth(
      data.panel,
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    );
    _tabDragPreviewAnchor = Offset(
      math.min(tabWidth / 2, previewSize.width / 2),
      TalUiTheme.of(context).panelTabStripHeight / 2,
    );
    _lastTabDragPreviewPosition = null;
    unawaited(_captureMainWindowOrigin());
    unawaited(tabDragPreview.prepare(panel: data.panel, size: previewSize));
  }

  Future<void> _captureMainWindowOrigin() async {
    try {
      _mainWindowOrigin = await windowManager.getPosition();
    } on Object {
      _mainWindowOrigin = Offset.zero;
    }
  }

  void _updateTabDrag(
    PanelTabDragData data,
    DragUpdateDetails details,
    Size workspaceSize,
  ) {
    if (_draggedTabSource != data.sourceGroupId || workspaceSize.isEmpty) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    unawaited(_moveTabDragPreview(details.globalPosition));
    final insideWorkspace = (Offset.zero & workspaceSize).contains(
      localPosition,
    );
    if (!insideWorkspace) {
      _clearTabMergeCandidate();
      return;
    }
    final normalizedPosition = Offset(
      localPosition.dx / workspaceSize.width,
      localPosition.dy / workspaceSize.height,
    );
    WorkspaceGroup? hoveredGroup;
    for (final group in _session.groupsByZ.reversed) {
      if (group.rect.contains(normalizedPosition)) {
        hoveredGroup = group;
        break;
      }
    }
    final targetId =
        hoveredGroup == null || hoveredGroup.id == data.sourceGroupId
        ? null
        : hoveredGroup.id;
    _setTabMergeCandidate(targetId);
  }

  Future<void> _moveTabDragPreview(Offset globalPosition) async {
    if (_draggedTabSource == null) return;
    final position = _mainWindowOrigin + globalPosition - _tabDragPreviewAnchor;
    _lastTabDragPreviewPosition = position;
    await tabDragPreview.showAt(position);
  }

  void _setTabMergeCandidate(String? targetId) {
    // Count time inside the target, including pointer movement and mouse jitter.
    // Only leaving or switching targets should restart the merge delay.
    if (_tabMergeCandidate == targetId) return;
    _tabMergeTimer?.cancel();
    _tabMergeCandidate = targetId;
    if (_armedTabMergeTarget != null || _session.mergeTarget != null) {
      setState(() {
        _armedTabMergeTarget = null;
        _session.mergeTarget = null;
      });
    }
    if (targetId == null) return;
    _tabMergeTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _tabMergeCandidate != targetId) return;
      setState(() {
        _armedTabMergeTarget = targetId;
        _session.mergeTarget = targetId;
      });
    });
  }

  void _clearTabMergeCandidate() => _setTabMergeCandidate(null);

  void _resetTabDragState({bool notify = true}) {
    _tabMergeTimer?.cancel();
    _tabMergeTimer = null;
    _tabMergeCandidate = null;
    _armedTabMergeTarget = null;
    _draggedTabSource = null;
    if (_session.mergeTarget == null) return;
    if (notify && mounted) {
      setState(() => _session.mergeTarget = null);
    } else {
      _session.mergeTarget = null;
    }
  }

  Future<void> _syncExternalWindows() async {
    final closed = await detachedWindows.reconcile();
    if (!mounted || closed.isEmpty) return;
    setState(() {
      final restoredPlacements = <DetachedPanelPlacement>{};
      for (final panel in closed) {
        final placement = _detachedPlacements.remove(panel);
        if (placement != null && restoredPlacements.add(placement)) {
          _restoreDetachedGroup(placement);
        }
      }
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void _handleDetachedTabDrag(DetachedTabDragEvent event) {
    switch (event.phase) {
      case DetachedTabDragPhase.start:
        _detachedDragSourceWindowId = event.sourceWindowId;
        _detachedDraggedPanel = event.panel;
        unawaited(_captureMainWindowOrigin());
        unawaited(
          tabDragPreview.prepare(
            panel: event.panel,
            size: event.previewSize ?? event.panel.preferredWindowSize,
          ),
        );
      case DetachedTabDragPhase.update:
        if (_detachedDragSourceWindowId != event.sourceWindowId ||
            _detachedDraggedPanel != event.panel) {
          return;
        }
        final position = event.screenPosition;
        if (position == null) return;
        unawaited(tabDragPreview.showAt(position - const Offset(56, 15)));
        final target = _mainGroupAtScreenPosition(position);
        final targetId = target?.id;
        if (_session.mergeTarget != targetId && mounted) {
          setState(() => _session.mergeTarget = targetId);
        }
      case DetachedTabDragPhase.end:
        if (_detachedDragSourceWindowId != event.sourceWindowId ||
            _detachedDraggedPanel != event.panel) {
          return;
        }
        _detachedDragSourceWindowId = null;
        _detachedDraggedPanel = null;
        if (_session.mergeTarget != null && mounted) {
          setState(() => _session.mergeTarget = null);
        }
        unawaited(_finishDetachedTabDrag(event));
    }
  }

  Future<void> _finishDetachedTabDrag(DetachedTabDragEvent event) async {
    await tabDragPreview.hide().timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );
    final screenPosition = event.screenPosition;
    if (!mounted || screenPosition == null) return;
    await _captureMainWindowOrigin();
    if (!mounted) return;

    final targetWindowId = await detachedWindows.windowAt(screenPosition);
    if (targetWindowId == event.sourceWindowId) return;
    if (targetWindowId != null) {
      final merged = await detachedWindows.mergePanelIntoWindow(
        sourceWindowId: event.sourceWindowId,
        panel: event.panel,
        targetWindowId: targetWindowId,
      );
      if (merged) widget.onPanelVisibilityChanged?.call();
      return;
    }

    final targetGroup = _mainGroupAtScreenPosition(screenPosition);
    if (targetGroup != null) {
      final removed = await detachedWindows.removePanelFromWindow(
        sourceWindowId: event.sourceWindowId,
        panel: event.panel,
      );
      if (!mounted || !removed) return;
      setState(() {
        _detachedPlacements.remove(event.panel);
        if (!targetGroup.panels.contains(event.panel)) {
          targetGroup.panels.add(event.panel);
        }
        targetGroup.activePanel = event.panel;
        targetGroup.z = _nextZ();
      });
      widget.onPanelVisibilityChanged?.call();
    }
  }

  WorkspaceGroup? _mainGroupAtScreenPosition(Offset screenPosition) {
    if (_session.workspaceSize.isEmpty) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return null;
    final mainWindowPosition = screenPosition - _mainWindowOrigin;
    final localPosition = renderObject.globalToLocal(mainWindowPosition);
    if (!(Offset.zero & _session.workspaceSize).contains(localPosition)) {
      return null;
    }
    final normalized = Offset(
      localPosition.dx / _session.workspaceSize.width,
      localPosition.dy / _session.workspaceSize.height,
    );
    for (final group in _session.groupsByZ.reversed) {
      if (group.rect.contains(normalized)) return group;
    }
    return null;
  }

  void _restoreDetachedGroup(DetachedPanelPlacement placement) {
    _session.zCursor = math.max(_session.zCursor, placement.groupZ);
    final panels = placement.panels
        .where(
          (panel) =>
              !_session.groups.any((group) => group.panels.contains(panel)),
        )
        .toList();
    if (panels.isEmpty) return;

    final originalGroup = _session.groups
        .where((group) => group.id == placement.groupId)
        .firstOrNull;
    if (originalGroup != null) {
      final availablePanels = <WorkspacePanelId>{
        ...originalGroup.panels,
        ...panels,
      };
      final orderedPanels = <WorkspacePanelId>[
        for (final panel in placement.originalPanels)
          if (availablePanels.contains(panel)) panel,
        for (final panel in originalGroup.panels)
          if (!placement.originalPanels.contains(panel)) panel,
      ];
      originalGroup.panels
        ..clear()
        ..addAll(orderedPanels);
      if (originalGroup.panels.contains(placement.activePanel)) {
        originalGroup.activePanel = placement.activePanel;
      }
      originalGroup.z = _nextZ();
      return;
    }

    _session.groups.add(
      WorkspaceGroup(
        id: placement.groupId,
        panels: panels,
        activePanel: panels.contains(placement.activePanel)
            ? placement.activePanel
            : panels.first,
        rect: _session.gridMode
            ? _snapRectToGrid(placement.groupRect)
            : _clampRect(placement.groupRect),
        z: _nextZ(),
      ),
    );
  }

  Rect _snapRectToGrid(Rect rect) {
    return _geometry.snapRectToGrid(rect, _session.workspaceSize);
  }

  void _mergeInto(WorkspaceGroup source, String targetId) {
    final target = _session.groups
        .where((group) => group.id == targetId)
        .firstOrNull;
    if (target == null || target == source) return;
    for (final panel in source.panels) {
      if (!target.panels.contains(panel)) target.panels.add(panel);
    }
    target.activePanel = source.activePanel;
    target.z = _nextZ();
    _session.groups.remove(source);
  }

  String? _findMergeTarget(WorkspaceGroup source) {
    if (_session.draggingGroup == null) return null;
    final center = source.rect.center;
    final sorted = _session.groupsByZ.reversed;
    for (final group in sorted) {
      if (group == source) continue;
      if (group.rect.inflate(0.012).contains(center)) return group.id;
    }
    return null;
  }

  Rect _clampRect(Rect rect) {
    return _geometry.clampRect(rect);
  }

  Rect _toPixelRect(Rect rect, Size size) {
    return _geometry.toPixelRect(rect, size);
  }

  void _bringToFront(WorkspaceGroup group, {bool notify = true}) {
    group.z = _nextZ();
    if (notify) setState(() {});
  }

  int _nextZ() => _session.nextZ();
}
