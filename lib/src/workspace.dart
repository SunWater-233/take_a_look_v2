import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'detached_window_coordinator.dart';
import 'panel_types.dart';
import 'panels.dart';
import 'theme.dart';
import 'window_sync.dart';
import 'workspace_geometry.dart';
import 'workspace_layout.dart';

const _geometry = WorkspaceGeometry();

class DockingWorkspace extends StatefulWidget {
  const DockingWorkspace({
    required this.controller,
    required this.windowSync,
    this.layoutFile,
    this.onPanelVisibilityChanged,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;
  final File? layoutFile;
  final VoidCallback? onPanelVisibilityChanged;

  @override
  DockingWorkspaceState createState() => DockingWorkspaceState();
}

class DockingWorkspaceState extends State<DockingWorkspace> {
  final List<WorkspaceGroup> _groups = <WorkspaceGroup>[];
  late final DetachedWindowCoordinator detachedWindows;
  final Map<WorkspacePanelId, _DetachedPanelPlacement> _detachedPlacements =
      <WorkspacePanelId, _DetachedPanelPlacement>{};
  StreamSubscription<void>? windowSubscription;
  int zCursor = 20;
  int idCursor = 100;
  String? draggingGroup;
  String? mergeTarget;
  Offset dragRemainder = Offset.zero;
  Offset resizeRemainder = Offset.zero;
  Size workspaceSize = Size.zero;
  bool gridMode = false;

  @override
  void initState() {
    super.initState();
    detachedWindows = DetachedWindowCoordinator(widget.windowSync);
    _applyDefaultLayout();
    windowSubscription = detachedWindows.changes.listen(
      (_) => _syncExternalWindows(),
    );
  }

  @override
  void dispose() {
    windowSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        workspaceSize = size;
        final sorted = [..._groups]..sort((a, b) => a.z.compareTo(b.z));
        return ClipRect(
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: TalColors.background),
              ),
              if (gridMode)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: ValueKey<String>('workspace-grid'),
                      painter: _WorkspaceGridPainter(),
                    ),
                  ),
                ),
              for (final group in sorted) _buildGroup(group, size),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGroup(WorkspaceGroup group, Size workspaceSize) {
    final rawRect = _toPixelRect(group.rect, workspaceSize);
    final rect = rawRect.deflate(1.5);
    return Positioned(
      key: ValueKey('workspace-group-${group.id}'),
      left: rect.left,
      top: rect.top,
      width: math.max(1, rect.width),
      height: math.max(1, rect.height),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _bringToFront(group),
        child: Stack(
          children: [
            Positioned.fill(
              child: buildWorkspacePanel(
                group.activePanel,
                widget.controller,
                chrome: PanelChrome(
                  tabs: List.unmodifiable(group.panels),
                  activePanel: group.activePanel,
                  highlighted: mergeTarget == group.id,
                  onSelect: (panel) => setState(() {
                    group.activePanel = panel;
                    _bringToFront(group, notify: false);
                  }),
                  onFloat: () =>
                      _floatPanel(group, group.activePanel, workspaceSize),
                  onClose: () => _hidePanel(group, group.activePanel),
                  onSeparate: () => _separatePanel(group, group.activePanel),
                  onDragStart: (_) => _startDrag(group),
                  onDragUpdate: (details) =>
                      _moveGroup(group, details.delta, workspaceSize),
                  onDragEnd: (_) => _endDrag(group),
                  draggable: gridMode,
                  groupId: group.id,
                  tabsDraggable: true,
                  onTabAccept: (data) => _acceptTabDrop(group, data),
                  onTabDragEnd: (data, details) =>
                      _finishTabDrag(group, data, details, workspaceSize),
                ),
              ),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-left'),
              alignment: Alignment.centerLeft,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              enabled: true,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, left: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-right'),
              alignment: Alignment.centerRight,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              enabled: true,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, right: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-top'),
              alignment: Alignment.topCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              enabled: true,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, top: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-bottom'),
              alignment: Alignment.bottomCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              enabled: true,
              onDragStart: _startResize,
              onDragEnd: _endResize,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, bottom: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}'),
              alignment: Alignment.bottomRight,
              cursor: SystemMouseCursors.resizeDownRight,
              width: 18,
              height: 18,
              enabled: true,
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
    _groups
      ..clear()
      ..addAll([
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
          panels: const [WorkspacePanelId.plot],
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
      ]);
    for (final panel in detachedWindows.windows.keys) {
      final group = _groups
          .where((candidate) => candidate.panels.contains(panel))
          .firstOrNull;
      if (group != null) _detachPanel(group, panel);
    }
    if (gridMode) {
      for (final group in _groups) {
        group.rect = _snapRectToGrid(group.rect);
      }
    }
  }

  Future<void> saveLayout() async {
    try {
      await _layoutRepository.save(
        WorkspaceLayoutSnapshot(
          groups: _groups,
          uiScale: widget.controller.uiScale,
        ),
      );
      widget.controller.report('工作区布局已保存。');
    } on Object catch (error) {
      widget.controller.report('保存布局失败：$error');
    }
  }

  Future<void> restoreLayout() async {
    try {
      final layout = await _layoutRepository.load();
      if (layout == null) {
        widget.controller.report('尚未保存过工作区布局。');
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
        group.rect = gridMode
            ? _snapRectToGrid(group.rect)
            : _clampRect(group.rect);
        restored.add(group);
      }
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(restored);
        zCursor = _groups.fold(20, (value, group) => math.max(value, group.z));
      });
      widget.onPanelVisibilityChanged?.call();
      widget.controller.setUiScale(layout.uiScale);
      widget.controller.report('已恢复保存的工作区布局。');
    } on Object catch (error) {
      widget.controller.report('恢复布局失败：$error');
    }
  }

  void resetLayout() {
    setState(_applyDefaultLayout);
    widget.onPanelVisibilityChanged?.call();
    widget.controller.report('已重置为默认工作区布局。');
  }

  bool isPanelVisible(WorkspacePanelId panel) {
    return detachedWindows.windows.containsKey(panel) ||
        _groups.any((group) => group.panels.contains(panel));
  }

  void setGridMode(bool value) {
    if (gridMode == value) return;
    setState(() {
      gridMode = value;
      dragRemainder = Offset.zero;
      resizeRemainder = Offset.zero;
      if (value) {
        for (final group in _groups) {
          group.rect = _snapRectToGrid(group.rect);
        }
      }
      if (!value) {
        draggingGroup = null;
        mergeTarget = null;
      }
    });
  }

  Future<void> togglePanelVisibility(WorkspacePanelId panel) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    final group = _groups
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
    if (_groups.any((group) => group.panels.contains(panel))) return;
    setState(() => _restorePanel(panel));
    widget.onPanelVisibilityChanged?.call();
    widget.controller.report('已恢复面板：${panel.title}。');
  }

  WorkspaceLayoutRepository get _layoutRepository => WorkspaceLayoutRepository(
    widget.layoutFile ?? WorkspaceLayoutRepository.defaultFile(),
  );

  void _startDrag(WorkspaceGroup group) {
    if (!gridMode) return;
    setState(() {
      dragRemainder = Offset.zero;
      draggingGroup = group.id;
      _bringToFront(group, notify: false);
    });
  }

  void _moveGroup(WorkspaceGroup group, Offset delta, Size workspaceSize) {
    if (!gridMode || workspaceSize.isEmpty) return;
    final totalDelta = Offset(
      dragRemainder.dx + delta.dx / workspaceSize.width,
      dragRemainder.dy + delta.dy / workspaceSize.height,
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
      dragRemainder = totalDelta;
      return;
    }
    setState(() {
      final previousRect = group.rect;
      group.rect = _clampRect(
        group.rect.translate(snappedDelta.dx, snappedDelta.dy),
      );
      final actualDelta = group.rect.topLeft - previousRect.topLeft;
      dragRemainder = Offset(
        _near(actualDelta.dx, snappedDelta.dx)
            ? totalDelta.dx - snappedDelta.dx
            : 0,
        _near(actualDelta.dy, snappedDelta.dy)
            ? totalDelta.dy - snappedDelta.dy
            : 0,
      );
      mergeTarget = _findMergeTarget(group);
    });
  }

  void _endDrag(WorkspaceGroup group) {
    if (!gridMode) return;
    setState(() {
      final target = _findMergeTarget(group);
      dragRemainder = Offset.zero;
      draggingGroup = null;
      mergeTarget = null;
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
    if (!gridMode) {
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
        mergeTarget = null;
        _bringToFront(group, notify: false);
      });
      return;
    }
    setState(() {
      if (left || right) {
        final total = resizeRemainder.dx + delta.dx / workspaceSize.width;
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
          resizeRemainder = Offset(
            _near(applied, requested) ? total - requested : 0,
            resizeRemainder.dy,
          );
        } else {
          resizeRemainder = Offset(total, resizeRemainder.dy);
        }
      }
      if (top || bottom) {
        final total = resizeRemainder.dy + delta.dy / workspaceSize.height;
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
          resizeRemainder = Offset(
            resizeRemainder.dx,
            _near(applied, requested) ? total - requested : 0,
          );
        } else {
          resizeRemainder = Offset(resizeRemainder.dx, total);
        }
      }
      mergeTarget = null;
      _bringToFront(group, notify: false);
    });
  }

  double _resizeAxis(
    WorkspaceGroup group,
    double requestedDelta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final participants = gridMode
        ? <WorkspaceGroup, bool>{group: movingEnd}
        : _geometry.resizeParticipants(
            _groups,
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

  void _startResize() => resizeRemainder = Offset.zero;

  void _endResize() => resizeRemainder = Offset.zero;

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
    final window = await detachedWindows.create(
      activePanel: activePanel,
      panels: panels,
      initialSize: _toPixelRect(group.rect, workspaceSize).size,
    );
    if (!mounted) return;
    setState(() {
      final placement = _DetachedPanelPlacement(
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
      _groups.remove(group);
    });
    widget.onPanelVisibilityChanged?.call();
    widget.controller.addLog(
      panels.length > 1
          ? '${activePanel.title} 组合已弹出为独立窗口。'
          : '${activePanel.title} 已弹出为独立窗口。',
    );
    await window.show();
  }

  Future<void> _floatSinglePanel(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Size workspaceSize,
  ) async {
    if (await detachedWindows.showIfOpen(panel)) return;
    final originalPanels = List<WorkspacePanelId>.of(group.panels);
    final window = await detachedWindows.create(
      activePanel: panel,
      panels: <WorkspacePanelId>[panel],
      initialSize: _toPixelRect(group.rect, workspaceSize).size,
    );
    if (!mounted || !group.panels.contains(panel)) return;
    setState(() {
      _detachedPlacements[panel] = _DetachedPanelPlacement(
        groupId: group.id,
        groupRect: group.rect,
        groupZ: group.z,
        panels: <WorkspacePanelId>[panel],
        originalPanels: originalPanels,
        activePanel: panel,
      );
      _detachPanel(group, panel);
    });
    widget.onPanelVisibilityChanged?.call();
    widget.controller.addLog('${panel.title} 已弹出为独立窗口。');
    await window.show();
  }

  void _detachPanel(WorkspaceGroup group, WorkspacePanelId panel) {
    group.panels.remove(panel);
    if (group.panels.isEmpty) {
      _groups.remove(group);
    } else if (group.activePanel == panel) {
      group.activePanel = group.panels.first;
    }
  }

  void _hidePanel(WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() => _detachPanel(group, panel));
    widget.onPanelVisibilityChanged?.call();
    widget.controller.report('已隐藏面板：${panel.title}，可从“视图”菜单恢复。');
  }

  void _separatePanel(WorkspaceGroup group, WorkspacePanelId panel) {
    if (group.panels.length < 2) return;
    _separatePanelToRect(
      group,
      panel,
      _clampRect(group.rect.translate(0.025, 0.025)),
    );
  }

  void _separatePanelAt(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Offset globalPosition,
    Size workspaceSize,
  ) {
    if (group.panels.length < 2 || workspaceSize.isEmpty) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(globalPosition);
    final center = Offset(
      localPosition.dx / workspaceSize.width,
      localPosition.dy / workspaceSize.height,
    );
    _separatePanelToRect(
      group,
      panel,
      _clampRect(
        Rect.fromCenter(
          center: center,
          width: group.rect.width,
          height: group.rect.height,
        ),
      ),
    );
  }

  void _separatePanelToRect(
    WorkspaceGroup group,
    WorkspacePanelId panel,
    Rect rect,
  ) {
    if (gridMode) rect = _snapRectToGrid(rect);
    setState(() {
      _detachPanel(group, panel);
      _groups.add(
        WorkspaceGroup(
          id: 'separated_${idCursor++}',
          panels: [panel],
          activePanel: panel,
          rect: rect,
          z: _nextZ(),
        ),
      );
    });
    widget.controller.report('已从组合中拆分面板：${panel.title}。');
  }

  void _acceptTabDrop(WorkspaceGroup target, PanelTabDragData data) {
    final source = _groups
        .where((group) => group.id == data.sourceGroupId)
        .firstOrNull;
    if (source == null || !source.panels.contains(data.panel)) return;
    if (source == target) {
      setState(() => target.activePanel = data.panel);
      return;
    }
    setState(() {
      _detachPanel(source, data.panel);
      if (!target.panels.contains(data.panel)) {
        target.panels.add(data.panel);
      }
      target.activePanel = data.panel;
      target.z = _nextZ();
    });
    widget.controller.report('${data.panel.title} 已加入组件组合。');
  }

  void _finishTabDrag(
    WorkspaceGroup source,
    PanelTabDragData data,
    DraggableDetails details,
    Size workspaceSize,
  ) {
    if (details.wasAccepted || !source.panels.contains(data.panel)) return;
    if (gridMode) {
      _separatePanelAt(source, data.panel, details.offset, workspaceSize);
      return;
    }
    unawaited(_floatSinglePanel(source, data.panel, workspaceSize));
  }

  Future<void> _syncExternalWindows() async {
    final closed = await detachedWindows.reconcile();
    if (!mounted || closed.isEmpty) return;
    setState(() {
      final restoredPlacements = <_DetachedPanelPlacement>{};
      for (final panel in closed) {
        final placement = _detachedPlacements.remove(panel);
        if (placement == null) {
          _restorePanel(panel);
        } else if (restoredPlacements.add(placement)) {
          _restoreDetachedGroup(placement);
        }
        widget.controller.addLog('${panel.title} 独立窗口已关闭，面板已恢复。');
      }
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void _restorePanel(WorkspacePanelId panel) {
    if (_groups.any((group) => group.panels.contains(panel))) return;
    _groups.add(
      WorkspaceGroup(
        id: 'restored_${idCursor++}',
        panels: [panel],
        activePanel: panel,
        rect: gridMode
            ? _snapRectToGrid(_defaultRect(panel))
            : _defaultRect(panel),
        z: _nextZ(),
      ),
    );
  }

  void _restoreDetachedGroup(_DetachedPanelPlacement placement) {
    zCursor = math.max(zCursor, placement.groupZ);
    final panels = placement.panels
        .where((panel) => !_groups.any((group) => group.panels.contains(panel)))
        .toList();
    if (panels.isEmpty) return;

    final originalGroup = _groups
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

    _groups.add(
      WorkspaceGroup(
        id: placement.groupId,
        panels: panels,
        activePanel: panels.contains(placement.activePanel)
            ? placement.activePanel
            : panels.first,
        rect: gridMode
            ? _snapRectToGrid(placement.groupRect)
            : _clampRect(placement.groupRect),
        z: _nextZ(),
      ),
    );
  }

  Rect _defaultRect(WorkspacePanelId panel) => switch (panel) {
    WorkspacePanelId.header ||
    WorkspacePanelId.runControl ||
    WorkspacePanelId.sampling => const Rect.fromLTWH(0.03, 0.05, 0.34, 0.27),
    WorkspacePanelId.symbols ||
    WorkspacePanelId.watch ||
    WorkspacePanelId.connection => const Rect.fromLTWH(0.04, 0.26, 0.36, 0.58),
    WorkspacePanelId.plot => const Rect.fromLTWH(0.22, 0.05, 0.72, 0.67),
    WorkspacePanelId.log => const Rect.fromLTWH(0.08, 0.68, 0.84, 0.26),
  };

  Rect _snapRectToGrid(Rect rect) {
    return _geometry.snapRectToGrid(rect, workspaceSize);
  }

  void _mergeInto(WorkspaceGroup source, String targetId) {
    final target = _groups.where((group) => group.id == targetId).firstOrNull;
    if (target == null || target == source) return;
    for (final panel in source.panels) {
      if (!target.panels.contains(panel)) target.panels.add(panel);
    }
    target.activePanel = source.activePanel;
    target.z = _nextZ();
    _groups.remove(source);
    widget.controller.addLog(
      '${source.activePanel.title} 已合并到 ${target.id} 组合。',
    );
  }

  String? _findMergeTarget(WorkspaceGroup source) {
    if (draggingGroup == null) return null;
    final center = source.rect.center;
    final sorted = [..._groups]..sort((a, b) => b.z.compareTo(a.z));
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

  int _nextZ() => ++zCursor;
}

class _DetachedPanelPlacement {
  const _DetachedPanelPlacement({
    required this.groupId,
    required this.groupRect,
    required this.groupZ,
    required this.panels,
    required this.originalPanels,
    required this.activePanel,
  });

  final String groupId;
  final Rect groupRect;
  final int groupZ;
  final List<WorkspacePanelId> panels;
  final List<WorkspacePanelId> originalPanels;
  final WorkspacePanelId activePanel;
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.alignment,
    required this.cursor,
    required this.width,
    required this.height,
    required this.onDrag,
    required this.onDragStart,
    required this.onDragEnd,
    this.enabled = true,
    this.visible = false,
    this.handleKey,
  });

  final Alignment alignment;
  final MouseCursor cursor;
  final double width;
  final double height;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final bool enabled;
  final bool visible;
  final Key? handleKey;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: MouseRegion(
        cursor: enabled ? cursor : MouseCursor.defer,
        child: GestureDetector(
          key: handleKey,
          behavior: HitTestBehavior.opaque,
          onPanStart: enabled ? (_) => onDragStart() : null,
          onPanUpdate: enabled ? (details) => onDrag(details.delta) : null,
          onPanEnd: enabled ? (_) => onDragEnd() : null,
          child: SizedBox(
            width: math.max(1, width),
            height: math.max(1, height),
            child: visible
                ? const Align(
                    alignment: Alignment.bottomRight,
                    child: Icon(
                      Icons.drag_handle,
                      size: 15,
                      color: TalColors.muted,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _WorkspaceGridPainter extends CustomPainter {
  const _WorkspaceGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final minorPaint = Paint()..color = const Color(0xFF242123);
    final majorPaint = Paint()..color = const Color(0xFF3A3638);
    for (
      var index = 1, x = _geometry.gridCellSize;
      x < size.width;
      index += 1, x += _geometry.gridCellSize
    ) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        index % 4 == 0 ? majorPaint : minorPaint,
      );
    }
    for (
      var index = 1, y = _geometry.gridCellSize;
      y < size.height;
      index += 1, y += _geometry.gridCellSize
    ) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        index % 4 == 0 ? majorPaint : minorPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
