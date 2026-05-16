part of '../take_a_look_app.dart';

enum WorkspacePanelId { connection, symbols, plot, watch, sampling, log }

const _panelWindowBusinessId = 'workspace_panel';

WorkspacePanelId? _panelIdFromEntrypointArgs(List<String> args) {
  if (args.length < 3 || args.first != 'multi_window') {
    return null;
  }
  return _panelIdFromWindowArguments(args[2]);
}

WorkspacePanelId? _panelIdFromWindowArguments(String arguments) {
  if (arguments.isEmpty) {
    return null;
  }
  try {
    final data = jsonDecode(arguments) as Map<String, dynamic>;
    if (data['businessId'] != _panelWindowBusinessId) {
      return null;
    }
    return _panelIdFromWireName(data['panelId'] as String? ?? '');
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

String _encodePanelWindowPayload(WorkspacePanelId panel) {
  return jsonEncode({
    'businessId': _panelWindowBusinessId,
    'panelId': _panelWireName(panel),
  });
}

WorkspacePanelId? _panelIdFromWireName(String name) {
  for (final panel in WorkspacePanelId.values) {
    if (_panelWireName(panel) == name) {
      return panel;
    }
  }
  return null;
}

String _panelWireName(WorkspacePanelId panel) {
  switch (panel) {
    case WorkspacePanelId.connection:
      return 'connection';
    case WorkspacePanelId.symbols:
      return 'symbols';
    case WorkspacePanelId.plot:
      return 'plot';
    case WorkspacePanelId.watch:
      return 'watch';
    case WorkspacePanelId.sampling:
      return 'sampling';
    case WorkspacePanelId.log:
      return 'log';
  }
}

String _panelTitle(WorkspacePanelId panel) {
  switch (panel) {
    case WorkspacePanelId.connection:
      return '连接设置';
    case WorkspacePanelId.symbols:
      return '符号变量';
    case WorkspacePanelId.plot:
      return '实时曲线';
    case WorkspacePanelId.watch:
      return '实时调参';
    case WorkspacePanelId.sampling:
      return '采样与显示';
    case WorkspacePanelId.log:
      return '事件日志';
  }
}

IconData _panelIcon(WorkspacePanelId panel) {
  switch (panel) {
    case WorkspacePanelId.connection:
      return Icons.settings_input_component;
    case WorkspacePanelId.symbols:
      return Icons.account_tree_outlined;
    case WorkspacePanelId.plot:
      return Icons.show_chart;
    case WorkspacePanelId.watch:
      return Icons.table_chart_outlined;
    case WorkspacePanelId.sampling:
      return Icons.av_timer;
    case WorkspacePanelId.log:
      return Icons.terminal;
  }
}

Rect _defaultRectFor(WorkspacePanelId panel) {
  switch (panel) {
    case WorkspacePanelId.connection:
      return const Rect.fromLTWH(0.00, 0.00, 0.22, 0.34);
    case WorkspacePanelId.symbols:
      return const Rect.fromLTWH(0.00, 0.36, 0.22, 0.64);
    case WorkspacePanelId.plot:
      return const Rect.fromLTWH(0.23, 0.00, 0.48, 0.76);
    case WorkspacePanelId.log:
      return const Rect.fromLTWH(0.23, 0.78, 0.48, 0.22);
    case WorkspacePanelId.watch:
      return const Rect.fromLTWH(0.72, 0.00, 0.28, 0.60);
    case WorkspacePanelId.sampling:
      return const Rect.fromLTWH(0.72, 0.62, 0.28, 0.38);
  }
}

class PanelTabData {
  const PanelTabData({
    required this.id,
    required this.title,
    required this.icon,
  });

  final WorkspacePanelId id;
  final String title;
  final IconData icon;
}

class PanelChromeConfig {
  const PanelChromeConfig({
    required this.tabs,
    required this.activePanel,
    required this.gridMode,
    required this.mergeHighlighted,
    required this.onSelectTab,
    required this.onToggleFloat,
    required this.onHeaderPanStart,
    required this.onHeaderPanUpdate,
    required this.onHeaderPanEnd,
  });

  final List<PanelTabData> tabs;
  final WorkspacePanelId activePanel;
  final bool gridMode;
  final bool mergeHighlighted;
  final ValueChanged<WorkspacePanelId> onSelectTab;
  final VoidCallback onToggleFloat;
  final GestureDragStartCallback onHeaderPanStart;
  final GestureDragUpdateCallback onHeaderPanUpdate;
  final GestureDragEndCallback onHeaderPanEnd;
}

class _WorkspacePanelMeta {
  const _WorkspacePanelMeta({
    required this.id,
    required this.title,
    required this.icon,
  });

  final WorkspacePanelId id;
  final String title;
  final IconData icon;
}

class _WorkspaceGroup {
  _WorkspaceGroup({
    required this.id,
    required this.panels,
    required this.activePanel,
    required this.rect,
    required this.z,
  });

  final String id;
  final List<WorkspacePanelId> panels;
  WorkspacePanelId activePanel;
  Rect rect;
  int z;
}

class DockableWorkspace extends StatefulWidget {
  const DockableWorkspace({
    required this.controller,
    required this.gridMode,
    required this.resetVersion,
    super.key,
  });

  final TakeALookController controller;
  final bool gridMode;
  final int resetVersion;

  @override
  State<DockableWorkspace> createState() => _DockableWorkspaceState();
}

class _DockableWorkspaceState extends State<DockableWorkspace> {
  static const gridColumns = 24;
  static const gridRows = 16;
  static const minWidth = 0.16;
  static const minHeight = 0.14;

  final List<_WorkspaceGroup> _groups = <_WorkspaceGroup>[];
  final Map<WorkspacePanelId, WindowController> _externalWindows =
      <WorkspacePanelId, WindowController>{};
  StreamSubscription<void>? _windowSubscription;
  var _zCursor = 10;
  var _idCursor = 100;
  String? _draggingGroupId;
  String? _mergeTargetId;

  @override
  void initState() {
    super.initState();
    _resetGroups();
    _windowSubscription = onWindowsChanged.listen((_) {
      _syncExternalWindows();
    });
  }

  @override
  void dispose() {
    _windowSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DockableWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetVersion != widget.resetVersion) {
      _resetGroups();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final sortedGroups = [..._groups]..sort((a, b) => a.z.compareTo(b.z));
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: TalColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: TalColors.border),
                    ),
                  ),
                ),
                if (widget.gridMode)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WorkspaceGridPainter(
                        columns: gridColumns,
                        rows: gridRows,
                      ),
                    ),
                  ),
                for (final group in sortedGroups)
                  _buildPositionedGroup(group, size),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: _WorkspaceHint(gridMode: widget.gridMode),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPositionedGroup(_WorkspaceGroup group, Size workspaceSize) {
    final rect = _toPixelRect(group.rect, workspaceSize);
    final mergeHighlighted = _mergeTargetId == group.id;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _bringToFront(group),
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(9)),
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildActivePanel(
                  group,
                  PanelChromeConfig(
                    tabs: [for (final panel in group.panels) _tabFor(panel)],
                    activePanel: group.activePanel,
                    gridMode: widget.gridMode,
                    mergeHighlighted: mergeHighlighted,
                    onSelectTab: (panel) => _selectTab(group, panel),
                    onToggleFloat: () => _openExternalWindow(group),
                    onHeaderPanStart: (_) => _startDrag(group),
                    onHeaderPanUpdate: (details) =>
                        _moveGroup(group, details.delta, workspaceSize),
                    onHeaderPanEnd: (_) => _endDrag(group),
                  ),
                ),
              ),
              Positioned(
                right: 3,
                bottom: 3,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _bringToFront(group),
                    onPanUpdate: (details) =>
                        _resizeGroup(group, details.delta, workspaceSize),
                    onPanEnd: (_) => _endDrag(group),
                    child: Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.bottomRight,
                      child: const Icon(
                        Icons.drag_handle,
                        color: TalColors.textMuted,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActivePanel(_WorkspaceGroup group, PanelChromeConfig chrome) {
    switch (group.activePanel) {
      case WorkspacePanelId.connection:
        return ConnectionPanel(controller: widget.controller, chrome: chrome);
      case WorkspacePanelId.symbols:
        return SymbolBrowserPanel(
          controller: widget.controller,
          chrome: chrome,
        );
      case WorkspacePanelId.plot:
        return LivePlotPanel(controller: widget.controller, chrome: chrome);
      case WorkspacePanelId.watch:
        return WatchTablePanel(controller: widget.controller, chrome: chrome);
      case WorkspacePanelId.sampling:
        return SamplingPanel(controller: widget.controller, chrome: chrome);
      case WorkspacePanelId.log:
        return EventLogPanel(controller: widget.controller, chrome: chrome);
    }
  }

  void _resetGroups() {
    _groups
      ..clear()
      ..addAll([
        _WorkspaceGroup(
          id: 'connection',
          panels: [WorkspacePanelId.connection],
          activePanel: WorkspacePanelId.connection,
          rect: const Rect.fromLTWH(0.00, 0.00, 0.22, 0.34),
          z: 1,
        ),
        _WorkspaceGroup(
          id: 'symbols',
          panels: [WorkspacePanelId.symbols],
          activePanel: WorkspacePanelId.symbols,
          rect: const Rect.fromLTWH(0.00, 0.36, 0.22, 0.64),
          z: 2,
        ),
        _WorkspaceGroup(
          id: 'plot',
          panels: [WorkspacePanelId.plot],
          activePanel: WorkspacePanelId.plot,
          rect: const Rect.fromLTWH(0.23, 0.00, 0.48, 0.76),
          z: 3,
        ),
        _WorkspaceGroup(
          id: 'log',
          panels: [WorkspacePanelId.log],
          activePanel: WorkspacePanelId.log,
          rect: const Rect.fromLTWH(0.23, 0.78, 0.48, 0.22),
          z: 4,
        ),
        _WorkspaceGroup(
          id: 'watch',
          panels: [WorkspacePanelId.watch],
          activePanel: WorkspacePanelId.watch,
          rect: const Rect.fromLTWH(0.72, 0.00, 0.28, 0.60),
          z: 5,
        ),
        _WorkspaceGroup(
          id: 'sampling',
          panels: [WorkspacePanelId.sampling],
          activePanel: WorkspacePanelId.sampling,
          rect: const Rect.fromLTWH(0.72, 0.62, 0.28, 0.38),
          z: 6,
        ),
      ]);
    _mergeTargetId = null;
    _draggingGroupId = null;
    _zCursor = 10;
    if (mounted) {
      setState(() {});
    }
  }

  void _startDrag(_WorkspaceGroup group) {
    setState(() {
      _draggingGroupId = group.id;
      _bringToFront(group, notify: false);
    });
  }

  void _moveGroup(_WorkspaceGroup group, Offset delta, Size workspaceSize) {
    setState(() {
      final dx = delta.dx / workspaceSize.width;
      final dy = delta.dy / workspaceSize.height;
      group.rect = _clampRect(group.rect.translate(dx, dy));
      _mergeTargetId = _findMergeTarget(group);
    });
  }

  void _resizeGroup(_WorkspaceGroup group, Offset delta, Size workspaceSize) {
    setState(() {
      final dx = delta.dx / workspaceSize.width;
      final dy = delta.dy / workspaceSize.height;
      group.rect = _clampRect(
        Rect.fromLTWH(
          group.rect.left,
          group.rect.top,
          group.rect.width + dx,
          group.rect.height + dy,
        ),
      );
      _mergeTargetId = null;
    });
  }

  void _endDrag(_WorkspaceGroup group) {
    setState(() {
      if (widget.gridMode) {
        group.rect = _snapRect(group.rect);
      }
      final targetId = _findMergeTarget(group);
      _mergeTargetId = null;
      _draggingGroupId = null;
      if (targetId != null) {
        _mergeGroupInto(group, targetId);
      }
    });
  }

  void _selectTab(_WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() {
      group.activePanel = panel;
      _bringToFront(group, notify: false);
    });
  }

  Future<void> _openExternalWindow(_WorkspaceGroup group) async {
    final panel = group.activePanel;
    final existing = _externalWindows[panel];
    if (existing != null) {
      await existing.show();
      widget.controller.addLog('${_titleFor(panel)} 独立窗口已唤起');
      return;
    }

    final window = await WindowController.create(
      WindowConfiguration(
        arguments: _encodePanelWindowPayload(panel),
        hiddenAtLaunch: true,
      ),
    );
    _externalWindows[panel] = window;

    if (mounted) {
      setState(() {
        _detachPanelFromGroup(group, panel);
      });
      widget.controller.addLog('${_titleFor(panel)} 已弹出为系统独立窗口');
    }
    await window.show();
  }

  void _detachPanelFromGroup(_WorkspaceGroup group, WorkspacePanelId panel) {
    group.panels.remove(panel);
    if (group.panels.isEmpty) {
      _groups.removeWhere((item) => item.id == group.id);
      return;
    }
    if (group.activePanel == panel) {
      group.activePanel = group.panels.first;
    }
  }

  Future<void> _syncExternalWindows() async {
    final windows = await WindowController.getAll();
    final livePanels = <WorkspacePanelId>{};
    for (final window in windows) {
      final panel = _panelIdFromWindowArguments(window.arguments);
      if (panel != null) {
        livePanels.add(panel);
        _externalWindows[panel] = window;
      }
    }

    final closedPanels = _externalWindows.keys
        .where((panel) => !livePanels.contains(panel))
        .toList(growable: false);
    if (closedPanels.isEmpty || !mounted) {
      return;
    }
    setState(() {
      for (final panel in closedPanels) {
        _externalWindows.remove(panel);
        _restorePanel(panel);
        widget.controller.addLog('${_panelTitle(panel)} 独立窗口已关闭，面板已恢复');
      }
    });
  }

  void _restorePanel(WorkspacePanelId panel) {
    if (_groups.any((group) => group.panels.contains(panel))) {
      return;
    }
    _groups.add(
      _WorkspaceGroup(
        id: 'restored_${_idCursor++}',
        panels: [panel],
        activePanel: panel,
        rect: _defaultRectFor(panel),
        z: _nextZ(),
      ),
    );
  }

  void _mergeGroupInto(_WorkspaceGroup source, String targetId) {
    final target = _groupById(targetId);
    if (target == null || target.id == source.id) {
      return;
    }
    for (final panel in source.panels) {
      if (!target.panels.contains(panel)) {
        target.panels.add(panel);
      }
    }
    target.activePanel = source.activePanel;
    target.rect = _snapRect(target.rect);
    target.z = _nextZ();
    _groups.removeWhere((group) => group.id == source.id);
    widget.controller.addLog(
      '${_titleFor(source.activePanel)} 已合并到 ${_titleFor(target.activePanel)} 组',
      level: LogLevel.success,
    );
  }

  String? _findMergeTarget(_WorkspaceGroup source) {
    if (_draggingGroupId == null) {
      return null;
    }
    final center = source.rect.center;
    for (final group in _groups.reversed) {
      if (group.id == source.id) {
        continue;
      }
      final targetRect = group.rect.inflate(0.018);
      if (targetRect.contains(center)) {
        return group.id;
      }
    }
    return null;
  }

  Rect _snapRect(Rect rect) {
    final cellW = 1 / gridColumns;
    final cellH = 1 / gridRows;
    final left = (rect.left / cellW).round() * cellW;
    final top = (rect.top / cellH).round() * cellH;
    final width = math.max(4 * cellW, (rect.width / cellW).round() * cellW);
    final height = math.max(3 * cellH, (rect.height / cellH).round() * cellH);
    return _clampRect(Rect.fromLTWH(left, top, width, height));
  }

  Rect _clampRect(Rect rect) {
    final width = _clampDouble(rect.width, minWidth, 1);
    final height = _clampDouble(rect.height, minHeight, 1);
    final left = _clampDouble(rect.left, 0, 1 - width);
    final top = _clampDouble(rect.top, 0, 1 - height);
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
    if (notify) {
      setState(() {});
    }
  }

  int _nextZ() {
    _zCursor += 1;
    return _zCursor;
  }

  _WorkspaceGroup? _groupById(String id) {
    for (final group in _groups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  PanelTabData _tabFor(WorkspacePanelId panel) {
    final meta = _metaFor(panel);
    return PanelTabData(id: meta.id, title: meta.title, icon: meta.icon);
  }

  String _titleFor(WorkspacePanelId panel) => _metaFor(panel).title;

  _WorkspacePanelMeta _metaFor(WorkspacePanelId panel) {
    return _WorkspacePanelMeta(
      id: panel,
      title: _panelTitle(panel),
      icon: _panelIcon(panel),
    );
  }

  double _clampDouble(double value, double lower, double upper) {
    return math.min(math.max(value, lower), upper);
  }
}

class _WorkspaceGridPainter extends CustomPainter {
  const _WorkspaceGridPainter({required this.columns, required this.rows});

  final int columns;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = TalColors.grid.withAlpha(150)
      ..strokeWidth = 1;
    for (var i = 1; i < columns; i += 1) {
      final x = size.width * i / columns;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var i = 1; i < rows; i += 1) {
      final y = size.height * i / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspaceGridPainter oldDelegate) {
    return oldDelegate.columns != columns || oldDelegate.rows != rows;
  }
}

class _WorkspaceHint extends StatelessWidget {
  const _WorkspaceHint({required this.gridMode});

  final bool gridMode;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: TalColors.surface.withAlpha(210),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: TalColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                gridMode ? Icons.grid_on : Icons.grid_off,
                size: 14,
                color: TalColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                gridMode ? '网格吸附 · 拖到面板上合并' : '自由拖动 · 拖到面板上合并',
                style: TalText.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
