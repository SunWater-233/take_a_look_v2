import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'panel_types.dart';
import 'panels.dart';
import 'theme.dart';
import 'window_sync.dart';

class DockingWorkspace extends StatefulWidget {
  const DockingWorkspace({
    required this.controller,
    required this.windowSync,
    this.layoutFile,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;
  final File? layoutFile;

  @override
  DockingWorkspaceState createState() => DockingWorkspaceState();
}

class DockingWorkspaceState extends State<DockingWorkspace> {
  static const minWidth = 0.14;
  static const minHeight = 0.10;
  // A saved layout can accumulate small floating point errors at shared edges.
  static const adjacencyTolerance = 0.012;
  static const overlapTolerance = 0.001;

  final List<_WorkspaceGroup> _groups = <_WorkspaceGroup>[];
  final Map<WorkspacePanelId, WindowController> externalWindows =
      <WorkspacePanelId, WindowController>{};
  final Map<WorkspacePanelId, _DetachedPanelPlacement> _detachedPlacements =
      <WorkspacePanelId, _DetachedPanelPlacement>{};
  StreamSubscription<void>? windowSubscription;
  int zCursor = 20;
  int idCursor = 100;
  String? draggingGroup;
  String? mergeTarget;
  bool gridMode = true;

  @override
  void initState() {
    super.initState();
    _applyDefaultLayout();
    windowSubscription = onWindowsChanged.listen((_) => _syncExternalWindows());
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
                    child: CustomPaint(painter: _WorkspaceGridPainter()),
                  ),
                ),
              for (final group in sorted) _buildGroup(group, size),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGroup(_WorkspaceGroup group, Size workspaceSize) {
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
                ),
              ),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-left'),
              alignment: Alignment.centerLeft,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, left: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-right'),
              alignment: Alignment.centerRight,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
              height: rect.height - 28,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, right: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-top'),
              alignment: Alignment.topCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, top: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}-bottom'),
              alignment: Alignment.bottomCenter,
              cursor: SystemMouseCursors.resizeUpDown,
              width: rect.width - 28,
              height: 7,
              onDrag: (delta) =>
                  _resizeGroup(group, delta, workspaceSize, bottom: true),
            ),
            _ResizeHandle(
              handleKey: ValueKey('resize-${group.id}'),
              alignment: Alignment.bottomRight,
              cursor: SystemMouseCursors.resizeDownRight,
              width: 18,
              height: 18,
              visible: true,
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
        _WorkspaceGroup(
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
        _WorkspaceGroup(
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
        _WorkspaceGroup(
          id: 'plot',
          panels: const [WorkspacePanelId.plot],
          activePanel: WorkspacePanelId.plot,
          rect: const Rect.fromLTWH(0.22, 0, 0.78, 0.76),
          z: 3,
        ),
        _WorkspaceGroup(
          id: 'log',
          panels: const [WorkspacePanelId.log],
          activePanel: WorkspacePanelId.log,
          rect: const Rect.fromLTWH(0, 0.76, 1, 0.24),
          z: 4,
        ),
      ]);
    for (final panel in externalWindows.keys) {
      final group = _groups
          .where((candidate) => candidate.panels.contains(panel))
          .firstOrNull;
      if (group != null) _detachPanel(group, panel);
    }
  }

  Future<void> saveLayout() async {
    try {
      final payload = <String, dynamic>{
        'version': 1,
        'groups': [for (final group in _groups) group.toJson()],
      };
      final file = _layoutFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
      widget.controller.report('工作区布局已保存。');
    } on Object catch (error) {
      widget.controller.report('保存布局失败：$error');
    }
  }

  Future<void> restoreLayout() async {
    try {
      final file = _layoutFile();
      if (!await file.exists()) {
        widget.controller.report('尚未保存过工作区布局。');
        return;
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['groups'] is! List) {
        throw const FormatException('布局文件格式无效');
      }
      final restored = <_WorkspaceGroup>[];
      final seenPanels = <WorkspacePanelId>{};
      for (final entry in raw['groups'] as List) {
        final group = _WorkspaceGroup.fromJson(
          Map<String, dynamic>.from(entry as Map),
        );
        group.panels.removeWhere(
          (panel) =>
              externalWindows.containsKey(panel) || !seenPanels.add(panel),
        );
        if (group.panels.isEmpty) continue;
        if (!group.panels.contains(group.activePanel)) {
          group.activePanel = group.panels.first;
        }
        group.rect = _clampRect(group.rect);
        restored.add(group);
      }
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(restored);
        zCursor = _groups.fold(20, (value, group) => math.max(value, group.z));
      });
      widget.controller.report('已恢复保存的工作区布局。');
    } on Object catch (error) {
      widget.controller.report('恢复布局失败：$error');
    }
  }

  void resetLayout() {
    setState(_applyDefaultLayout);
    widget.controller.report('已重置为默认工作区布局。');
  }

  bool isPanelVisible(WorkspacePanelId panel) {
    return externalWindows.containsKey(panel) ||
        _groups.any((group) => group.panels.contains(panel));
  }

  void setGridMode(bool value) {
    if (gridMode == value) return;
    setState(() => gridMode = value);
  }

  Future<void> togglePanelVisibility(WorkspacePanelId panel) async {
    final external = externalWindows[panel];
    if (external != null) {
      await external.show();
      return;
    }
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
    final external = externalWindows[panel];
    if (external != null) {
      await external.show();
      return;
    }
    if (_groups.any((group) => group.panels.contains(panel))) return;
    setState(() => _restorePanel(panel));
    widget.controller.report('已恢复面板：${panel.title}。');
  }

  File _layoutFile() {
    final override = widget.layoutFile;
    if (override != null) return override;
    final environment = Platform.environment;
    late final String basePath;
    if (Platform.isWindows) {
      basePath = environment['APPDATA'] ?? Directory.current.path;
    } else if (Platform.isMacOS) {
      final home = environment['HOME'] ?? Directory.current.path;
      basePath =
          '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support';
    } else {
      final home = environment['HOME'] ?? Directory.current.path;
      basePath =
          environment['XDG_CONFIG_HOME'] ??
          '$home${Platform.pathSeparator}.config';
    }
    final directory = Directory('$basePath${Platform.pathSeparator}TakeALook');
    return File('${directory.path}${Platform.pathSeparator}layout.json');
  }

  void _startDrag(_WorkspaceGroup group) {
    setState(() {
      draggingGroup = group.id;
      _bringToFront(group, notify: false);
    });
  }

  void _moveGroup(_WorkspaceGroup group, Offset delta, Size workspaceSize) {
    if (workspaceSize.isEmpty) return;
    setState(() {
      group.rect = _clampRect(
        group.rect.translate(
          delta.dx / workspaceSize.width,
          delta.dy / workspaceSize.height,
        ),
      );
      mergeTarget = _findMergeTarget(group);
    });
  }

  void _endDrag(_WorkspaceGroup group) {
    setState(() {
      final target = _findMergeTarget(group);
      draggingGroup = null;
      mergeTarget = null;
      if (target != null) _mergeInto(group, target);
    });
  }

  void _resizeGroup(
    _WorkspaceGroup group,
    Offset delta,
    Size workspaceSize, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    if (workspaceSize.isEmpty) return;
    setState(() {
      if (left || right) {
        final requested = delta.dx / workspaceSize.width;
        _resizeAxis(group, requested, horizontal: true, movingEnd: right);
      }
      if (top || bottom) {
        final requested = delta.dy / workspaceSize.height;
        _resizeAxis(group, requested, horizontal: false, movingEnd: bottom);
      }
      mergeTarget = null;
      _bringToFront(group, notify: false);
    });
  }

  void _resizeAxis(
    _WorkspaceGroup group,
    double requestedDelta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final participants = _resizeParticipants(
      group,
      horizontal: horizontal,
      movingEnd: movingEnd,
    );
    final delta = _constrainedBoundaryDelta(
      participants,
      requestedDelta,
      horizontal: horizontal,
    );
    if (delta == 0) return;

    for (final entry in participants.entries) {
      entry.key.rect = _moveBoundary(
        entry.key.rect,
        delta,
        horizontal: horizontal,
        movingEnd: entry.value,
      );
    }
  }

  Map<_WorkspaceGroup, bool> _resizeParticipants(
    _WorkspaceGroup source, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final boundary = _edge(source.rect, horizontal: horizontal, end: movingEnd);
    final participants = <_WorkspaceGroup, bool>{source: movingEnd};
    var changed = true;
    while (changed) {
      changed = false;
      final current = participants.entries.toList();
      for (final entry in current) {
        final group = entry.key;
        final role = entry.value;
        for (final candidate in _groups) {
          if (candidate == group || participants.containsKey(candidate)) {
            continue;
          }
          final candidateRole = role;
          final candidateEdge = _edge(
            candidate.rect,
            horizontal: horizontal,
            end: candidateRole,
          );
          if (!_near(candidateEdge, boundary) ||
              !_touchesPerpendicular(group.rect, candidate.rect, horizontal)) {
            continue;
          }
          // Components on the same side of the split line form one resize
          // segment, even when they are stacked vertically or horizontally.
          participants[candidate] = candidateRole;
          changed = true;
        }

        final oppositeRole = !role;
        for (final candidate in _groups) {
          if (candidate == group || participants.containsKey(candidate)) {
            continue;
          }
          final candidateEdge = _edge(
            candidate.rect,
            horizontal: horizontal,
            end: oppositeRole,
          );
          final overlap = _perpendicularOverlap(
            group.rect,
            candidate.rect,
            horizontal,
          );
          if (_near(candidateEdge, boundary) && overlap > overlapTolerance) {
            participants[candidate] = oppositeRole;
            changed = true;
          }
        }
      }
    }
    return participants;
  }

  double _constrainedBoundaryDelta(
    Map<_WorkspaceGroup, bool> participants,
    double requestedDelta, {
    required bool horizontal,
  }) {
    final minSize = horizontal ? minWidth : minHeight;
    var lower = -double.infinity;
    var upper = double.infinity;

    for (final entry in participants.entries) {
      final rect = entry.key.rect;
      final movingEnd = entry.value;
      final start = horizontal ? rect.left : rect.top;
      final end = horizontal ? rect.right : rect.bottom;
      final size = end - start;
      if (movingEnd) {
        lower = math.max(lower, minSize - size);
        upper = math.min(upper, 1.0 - end);
      } else {
        lower = math.max(lower, -start);
        upper = math.min(upper, size - minSize);
      }
    }
    return requestedDelta.clamp(lower, upper).toDouble();
  }

  double _edge(Rect rect, {required bool horizontal, required bool end}) {
    if (horizontal) return end ? rect.right : rect.left;
    return end ? rect.bottom : rect.top;
  }

  bool _near(double first, double second) =>
      (first - second).abs() <= adjacencyTolerance;

  double _perpendicularOverlap(Rect first, Rect second, bool horizontal) {
    return horizontal
        ? math.min(first.bottom, second.bottom) -
              math.max(first.top, second.top)
        : math.min(first.right, second.right) -
              math.max(first.left, second.left);
  }

  bool _touchesPerpendicular(Rect first, Rect second, bool horizontal) {
    final overlap = _perpendicularOverlap(first, second, horizontal);
    if (overlap > overlapTolerance) return true;
    final gap = -overlap;
    return gap <= adjacencyTolerance;
  }

  Rect _moveBoundary(
    Rect rect,
    double delta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    if (horizontal) {
      return movingEnd
          ? Rect.fromLTRB(rect.left, rect.top, rect.right + delta, rect.bottom)
          : Rect.fromLTRB(rect.left + delta, rect.top, rect.right, rect.bottom);
    }
    return movingEnd
        ? Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom + delta)
        : Rect.fromLTRB(rect.left, rect.top + delta, rect.right, rect.bottom);
  }

  Future<void> _floatPanel(
    _WorkspaceGroup group,
    WorkspacePanelId panel,
    Size workspaceSize,
  ) async {
    final existing = externalWindows[panel];
    if (existing != null) {
      await existing.show();
      return;
    }
    final panels = List<WorkspacePanelId>.of(group.panels);
    final activePanel = group.activePanel;
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: encodePanelArguments(
          activePanel,
          _toPixelRect(group.rect, workspaceSize).size,
          panels: panels,
        ),
        hiddenAtLaunch: true,
      ),
    );
    for (final groupPanel in panels) {
      externalWindows[groupPanel] = window;
    }
    widget.windowSync.registerWindow(activePanel, window);
    if (!mounted) return;
    setState(() {
      final placement = _DetachedPanelPlacement(
        groupId: group.id,
        groupRect: group.rect,
        groupZ: group.z,
        panels: panels,
        activePanel: activePanel,
      );
      for (final groupPanel in panels) {
        _detachedPlacements[groupPanel] = placement;
      }
      _groups.remove(group);
    });
    widget.controller.addLog(
      panels.length > 1
          ? '${activePanel.title} 组合已弹出为独立窗口。'
          : '${activePanel.title} 已弹出为独立窗口。',
    );
    await window.show();
  }

  void _detachPanel(_WorkspaceGroup group, WorkspacePanelId panel) {
    group.panels.remove(panel);
    if (group.panels.isEmpty) {
      _groups.remove(group);
    } else if (group.activePanel == panel) {
      group.activePanel = group.panels.first;
    }
  }

  void _hidePanel(_WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() => _detachPanel(group, panel));
    widget.controller.report('已隐藏面板：${panel.title}，可从“视图”菜单恢复。');
  }

  void _separatePanel(_WorkspaceGroup group, WorkspacePanelId panel) {
    if (group.panels.length < 2) return;
    setState(() {
      _detachPanel(group, panel);
      _groups.add(
        _WorkspaceGroup(
          id: 'separated_${idCursor++}',
          panels: [panel],
          activePanel: panel,
          rect: _clampRect(group.rect.translate(0.025, 0.025)),
          z: _nextZ(),
        ),
      );
    });
    widget.controller.report('已从组合中拆分面板：${panel.title}。');
  }

  Future<void> _syncExternalWindows() async {
    final windows = await WindowController.getAll();
    final livePanels = <WorkspacePanelId>{};
    for (final window in windows) {
      final panels = _panelsFromWindowArguments(window.arguments);
      for (final panel in panels) {
        livePanels.add(panel);
        externalWindows[panel] = window;
      }
    }
    final closed = externalWindows.keys
        .where((panel) => !livePanels.contains(panel))
        .toList();
    if (!mounted || closed.isEmpty) return;
    setState(() {
      final restoredPlacements = <_DetachedPanelPlacement>{};
      for (final panel in closed) {
        externalWindows.remove(panel);
        widget.windowSync.unregisterWindow(panel);
        final placement = _detachedPlacements.remove(panel);
        if (placement == null) {
          _restorePanel(panel);
        } else if (restoredPlacements.add(placement)) {
          _restoreDetachedGroup(placement);
        }
        widget.controller.addLog('${panel.title} 独立窗口已关闭，面板已恢复。');
      }
    });
  }

  List<WorkspacePanelId> _panelsFromWindowArguments(String arguments) {
    return detachedPanelLaunchFromEntrypointArguments([
          'multi_window',
          '0',
          arguments,
        ])?.groupPanels ??
        const <WorkspacePanelId>[];
  }

  void _restorePanel(WorkspacePanelId panel) {
    if (_groups.any((group) => group.panels.contains(panel))) return;
    _groups.add(
      _WorkspaceGroup(
        id: 'restored_${idCursor++}',
        panels: [panel],
        activePanel: panel,
        rect: _defaultRect(panel),
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
      for (final panel in panels) {
        if (!originalGroup.panels.contains(panel)) {
          originalGroup.panels.add(panel);
        }
      }
      originalGroup.activePanel = placement.activePanel;
      originalGroup.z = _nextZ();
      return;
    }

    _groups.add(
      _WorkspaceGroup(
        id: placement.groupId,
        panels: panels,
        activePanel: panels.contains(placement.activePanel)
            ? placement.activePanel
            : panels.first,
        rect: _clampRect(placement.groupRect),
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

  void _mergeInto(_WorkspaceGroup source, String targetId) {
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

  String? _findMergeTarget(_WorkspaceGroup source) {
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
    final width = rect.width.clamp(minWidth, 1.0);
    final height = rect.height.clamp(minHeight, 1.0);
    final left = rect.left.clamp(0.0, 1.0 - width);
    final top = rect.top.clamp(0.0, 1.0 - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  Rect _toPixelRect(Rect rect, Size size) {
    return Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
  }

  void _bringToFront(_WorkspaceGroup group, {bool notify = true}) {
    group.z = _nextZ();
    if (notify) setState(() {});
  }

  int _nextZ() => ++zCursor;
}

class _WorkspaceGroup {
  _WorkspaceGroup({
    required this.id,
    required List<WorkspacePanelId> panels,
    required this.activePanel,
    required this.rect,
    required this.z,
  }) : panels = List.of(panels);

  final String id;
  final List<WorkspacePanelId> panels;
  WorkspacePanelId activePanel;
  Rect rect;
  int z;

  Map<String, dynamic> toJson() => {
    'id': id,
    'panels': [for (final panel in panels) panel.name],
    'activePanel': activePanel.name,
    'rect': [rect.left, rect.top, rect.width, rect.height],
    'z': z,
  };

  factory _WorkspaceGroup.fromJson(Map<String, dynamic> json) {
    final panels = (json['panels'] as List)
        .map((value) => WorkspacePanelId.values.byName(value as String))
        .toList();
    if (panels.isEmpty) throw const FormatException('面板组不能为空');
    final values = (json['rect'] as List)
        .map((value) => (value as num).toDouble())
        .toList();
    if (values.length != 4) throw const FormatException('面板位置无效');
    return _WorkspaceGroup(
      id: json['id'] as String,
      panels: panels,
      activePanel: WorkspacePanelId.values.byName(
        json['activePanel'] as String,
      ),
      rect: Rect.fromLTWH(values[0], values[1], values[2], values[3]),
      z: json['z'] as int,
    );
  }
}

class _DetachedPanelPlacement {
  const _DetachedPanelPlacement({
    required this.groupId,
    required this.groupRect,
    required this.groupZ,
    required this.panels,
    required this.activePanel,
  });

  final String groupId;
  final Rect groupRect;
  final int groupZ;
  final List<WorkspacePanelId> panels;
  final WorkspacePanelId activePanel;
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.alignment,
    required this.cursor,
    required this.width,
    required this.height,
    required this.onDrag,
    this.visible = false,
    this.handleKey,
  });

  final Alignment alignment;
  final MouseCursor cursor;
  final double width;
  final double height;
  final ValueChanged<Offset> onDrag;
  final bool visible;
  final Key? handleKey;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          key: handleKey,
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) => onDrag(details.delta),
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
    final paint = Paint()..color = const Color(0x10494446);
    for (var i = 1; i < 32; i += 1) {
      final x = size.width * i / 32;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var i = 1; i < 20; i += 1) {
      final y = size.height * i / 20;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
