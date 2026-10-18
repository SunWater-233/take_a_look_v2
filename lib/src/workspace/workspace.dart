import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/controller.dart';
import '../protocol/events.dart';
import '../app/file_pickers.dart';
import 'project_document.dart';
import 'detached_window_coordinator.dart';
import 'panel_types.dart';
import '../panels/panels.dart';
import 'tab_drag_preview_coordinator.dart';
import '../theme/theme.dart';
import 'window_sync.dart';
import 'workspace_geometry.dart';
import 'workspace_layout.dart';
import 'workspace_layout_controller.dart';
import 'workspace_persistence.dart';
import 'workspace_session.dart';
import 'workspace_tab_drag_session.dart';
import 'workspace_widgets.dart';

const _geometry = WorkspaceGeometry();

class DockingWorkspace extends StatefulWidget {
  const DockingWorkspace({
    required this.controller,
    required this.windowSync,
    this.layoutFile,
    this.onPanelVisibilityChanged,
    this.workbenchLayout = false,
    this.projectOpenPathPicker,
    this.projectSavePathPicker,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;
  final File? layoutFile;
  final VoidCallback? onPanelVisibilityChanged;
  final bool workbenchLayout;
  final PathPicker? projectOpenPathPicker;
  final PathPicker? projectSavePathPicker;

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
  late final WorkspaceLayoutController _layout = WorkspaceLayoutController(
    workbenchLayout: widget.workbenchLayout,
  );
  WorkspaceSession get _session => _layout.session;
  late final WorkspaceTabDragSession _tabDrag = WorkspaceTabDragSession(
    onChanged: _handleTabDragChanged,
  );
  Offset _mainWindowOrigin = Offset.zero;
  Offset _tabDragPreviewAnchor = Offset.zero;
  Offset? _lastTabDragPreviewPosition;
  int _sourceAdditionRevision = 0;
  final Map<WorkspacePanelId, GlobalKey> _panelBodyKeys = {};
  bool _resizing = false;
  double? _outputDragHeight;

  late final WorkspacePersistence _persistence = WorkspacePersistence(
    layoutRepository: () => WorkspaceLayoutRepository(
      widget.layoutFile ?? WorkspaceLayoutRepository.defaultFile(),
    ),
  );

  String? get projectPath => _persistence.projectPath;

  bool get usesWorkbenchLayout => _layout.usesWorkbenchLayout;
  bool get resourceDocked => _session.groups.any(
    (group) =>
        group.panels.contains(WorkspacePanelId.symbols) &&
        !_sidebarHidden(group),
  );
  WorkspaceGroup? get _outputGroup => _layout.outputGroup;
  bool get outputDocked => _layout.outputDocked;
  bool get focusedWorkbench => _layout.focused;
  bool get gridMode => _session.gridMode;
  WorkspaceGroup? get _primaryGroup => _layout.primaryGroup;
  bool get _narrowWorkspace => _layout.narrowWorkspace;

  Duration get _layoutAnimationDuration =>
      usesWorkbenchLayout &&
          !_resizing &&
          _tabDrag.sourceGroupId == null &&
          !MediaQuery.disableAnimationsOf(context)
      ? const Duration(milliseconds: 220)
      : Duration.zero;

  WorkspaceGroup? _sidebarGroup(WorkspaceSidebarSide side) =>
      _layout.sidebarGroup(side);
  bool _sidebarHidden(WorkspaceGroup group) => _layout.sidebarHidden(group);
  double _sidebarPixels(WorkspaceGroup group, Size size) =>
      _layout.sidebarPixels(group, size);
  Rect _groupPixelRect(WorkspaceGroup group, Size size) =>
      _layout.groupPixelRect(group, size);

  Future<void> activateWorkbenchView(WorkspacePanelId panel) async {
    if (usesWorkbenchLayout && panel.isWorkbenchOutput) {
      await showPanel(panel);
      return;
    }
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

  void _selectGroupPanel(
    WorkspaceGroup group,
    WorkspacePanelId panel, {
    bool toggleSidebar = false,
  }) {
    setState(
      () => _layout.selectPanel(group, panel, toggleSidebar: toggleSidebar),
    );
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void toggleWorkbenchFocus() {
    setState(() {
      _layout.focused = !_layout.focused;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  Future<void> toggleWorkbenchResource() async {
    if (await detachedWindows.showIfOpen(WorkspacePanelId.symbols)) return;
    final existing = _session.groups
        .where((group) => group.panels.contains(WorkspacePanelId.symbols))
        .firstOrNull;
    if (usesWorkbenchLayout) {
      if (existing != null) {
        _selectGroupPanel(
          existing,
          WorkspacePanelId.symbols,
          toggleSidebar: true,
        );
      } else {
        _dockPanel(WorkspacePanelId.symbols, WorkspaceSidebarSide.left);
      }
      return;
    }
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
    if (usesWorkbenchLayout) {
      final output = _outputGroup;
      if (output == null || output.outputCollapsed) {
        if (output != null) {
          _showWorkbenchOutput(output.activePanel);
          return;
        }
        final available = workspaceOutputPanels
            .where((panel) => !isPanelVisible(panel))
            .toList();
        if (available.isEmpty) {
          await showPanel(WorkspacePanelId.log);
        } else {
          _showWorkbenchOutput(available.first);
        }
      } else {
        setState(() {
          output.outputCollapsed = true;
          _reflowWorkbench();
        });
        widget.onPanelVisibilityChanged?.call();
        _scheduleLayoutSave();
      }
      return;
    }
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

  void startOutputDrag() {
    if (!usesWorkbenchLayout) return;
    _startResize();
    _outputDragHeight = outputDocked
        ? (1 - _outputGroup!.rect.top) * _session.workspaceSize.height
        : 0;
  }

  void updateOutputDrag(double deltaY) {
    if (!usesWorkbenchLayout || _session.workspaceSize.isEmpty) return;
    if (_outputDragHeight == null) startOutputDrag();
    final height = _session.workspaceSize.height;
    _outputDragHeight = (_outputDragHeight! - deltaY).clamp(0, height * .8);
    var output = _outputGroup;
    if (output == null && _outputDragHeight! >= 90) {
      final available = workspaceOutputPanels
          .where((p) => !isPanelVisible(p))
          .toList();
      if (available.isEmpty) return;
      _showWorkbenchOutput(available.first);
      output = _outputGroup;
    }
    if (output == null) return;
    setState(() {
      // Hysteresis makes the closed/open boundary feel deliberate.
      output!.outputCollapsed = output.outputCollapsed
          ? _outputDragHeight! < 90
          : _outputDragHeight! < 56;
      if (!output.outputCollapsed) {
        final pixels = _outputDragHeight!.clamp(130, height * .8);
        output.rect = Rect.fromLTWH(0, 1 - pixels / height, 1, pixels / height);
        _layout.focused = false;
      }
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
  }

  void endOutputDrag() {
    if (_outputDragHeight == null) return;
    final output = _outputGroup;
    final height = _session.workspaceSize.height;
    if (output != null && !output.outputCollapsed && height > 0) {
      final pixels = (1 - output.rect.top) * height;
      final stops = [180.0, 300.0, height * .5]
        ..sort((a, b) => (a - pixels).abs().compareTo((b - pixels).abs()));
      if ((stops.first - pixels).abs() <= 18) {
        setState(() {
          final snapped = stops.first.clamp(130, height * .8);
          output.rect = Rect.fromLTWH(
            0,
            1 - snapped / height,
            1,
            snapped / height,
          );
          _reflowWorkbench();
        });
      }
    }
    _outputDragHeight = null;
    _endResize();
  }

  void _showWorkbenchOutput(WorkspacePanelId panel) {
    setState(() {
      var output = _outputGroup;
      if (output == null) {
        output = WorkspaceGroup(
          id: 'output',
          panels: workspaceOutputPanels
              .where((item) => !isPanelVisible(item))
              .toList(),
          activePanel: panel,
          rect: const Rect.fromLTWH(0, .76, 1, .24),
          z: _nextZ(),
        );
        _session.groups.add(output);
      } else if (!output.panels.contains(panel)) {
        output.panels.add(panel);
      }
      output.activePanel = panel;
      output.outputCollapsed = false;
      _layout.focused = false;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  bool _tabsAtBottom(WorkspaceGroup group) =>
      usesWorkbenchLayout &&
      group.sidebar == null &&
      (group.id == 'output' ||
          group.panels.every((panel) => panel.isWorkbenchOutput));

  void _reflowWorkbench() => _layout.reflow();

  void _dockPanel(WorkspacePanelId panel, WorkspaceSidebarSide side) {
    setState(() => _layout.dockPanel(panel, side));
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _dockPanelAtEdge(WorkspacePanelId panel, WorkspaceDockEdge edge) {
    setState(() => _layout.dockPanelAtEdge(panel, edge));
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _movePanelToWorkspace(WorkspacePanelId panel) {
    setState(() => _layout.movePanelToWorkspace(panel));
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _panelAction(WorkspaceGroup group, WorkspacePanelAction action) {
    switch (action) {
      case WorkspacePanelAction.dockLeft:
        _dockPanel(group.activePanel, WorkspaceSidebarSide.left);
      case WorkspacePanelAction.dockRight:
        _dockPanel(group.activePanel, WorkspaceSidebarSide.right);
      case WorkspacePanelAction.dockBottom:
        _dockPanelAtEdge(group.activePanel, WorkspaceDockEdge.bottom);
      case WorkspacePanelAction.moveToWorkspace:
        _movePanelToWorkspace(group.activePanel);
      case WorkspacePanelAction.collapse:
        _selectGroupPanel(group, group.activePanel, toggleSidebar: true);
    }
  }

  void _scheduleLayoutSave() {
    if (!usesWorkbenchLayout || !widget.windowSync.isStarted) return;
    _persistence.scheduleLayoutSave(() => _persistLayout(report: false));
  }

  bool _handleDragKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _tabDrag.sourceGroupId == null) {
      return false;
    }
    _tabDrag.cancel();
    unawaited(tabDragPreview.hide());
    return true;
  }

  @visibleForTesting
  String? get debugTabMergeCandidate => _tabDrag.mergeCandidate;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleDragKey);
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
    HardwareKeyboard.instance.removeHandler(_handleDragKey);
    if (_persistence.hasPendingSave) {
      unawaited(_persistLayout(report: false));
    }
    _persistence.dispose();
    widget.controller.sourceWorkspaceChanges.removeListener(
      _handleSourceAddition,
    );
    windowSubscription?.cancel();
    detachedTabDragSubscription?.cancel();
    _tabDrag.dispose();
    unawaited(tabDragPreview.dispose());
    unawaited(detachedWindows.dispose());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DockingWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _layout.workbenchLayout = widget.workbenchLayout;
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
        if (usesWorkbenchLayout || (resized && _layout.automatic)) {
          _reflowWorkbench();
        }
        final sorted = _session.groupsByZ;
        final ordered = _narrowWorkspace && usesWorkbenchLayout
            ? [
                ...sorted.where((g) => g.sidebar == null),
                ...sorted.where((g) => g.sidebar != null),
              ]
            : sorted;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (_) => unawaited(tabDragPreview.hide()),
          onPointerCancel: (_) {
            _tabDrag.cancel();
            unawaited(tabDragPreview.hide());
          },
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
                if (usesWorkbenchLayout && _primaryGroup == null)
                  Positioned.fill(
                    child: Center(
                      child: Text('将标签拖回这里，或通过标签菜单移回工作区', style: talMuted),
                    ),
                  ),
                for (final group in ordered)
                  if (!(usesWorkbenchLayout &&
                      group == _outputGroup &&
                      group.outputCollapsed &&
                      _outputDragHeight == null))
                    _buildGroup(group, size),
                if (usesWorkbenchLayout) ..._dockOverlays(size),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGroup(WorkspaceGroup group, Size workspaceSize) {
    final expanded = group == _primaryGroup && _layout.focused;
    final hidden =
        _sidebarHidden(group) || (_layout.focused && group != _primaryGroup);
    final rawRect = _groupPixelRect(group, workspaceSize);
    final rect = rawRect.deflate(1.5);
    final ui = TalUiTheme.of(context);
    final tabsAtBottom = _tabsAtBottom(group);
    final tabStripTop = tabsAtBottom
        ? rect.height - ui.panelHeaderHeight
        : usesWorkbenchLayout
        ? 0.0
        : ui.panelHeaderHeight;
    final tabStripBottom =
        tabStripTop +
        (usesWorkbenchLayout ? ui.panelHeaderHeight : ui.panelTabStripHeight);
    return AnimatedPositioned(
      key: ValueKey('workspace-group-${group.id}'),
      duration: _layoutAnimationDuration,
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: math.max(1, rect.width),
      height: math.max(1, rect.height),
      child: IgnorePointer(
        ignoring: hidden,
        child: ExcludeFocus(
          excluding: hidden,
          child: ExcludeSemantics(
            excluding: hidden,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (details) {
                if (!mounted) return;
                final y = details.localPosition.dy;
                final isTabStrip =
                    (usesWorkbenchLayout || group.panels.length > 1) &&
                    y >= tabStripTop &&
                    y < tabStripBottom;
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
                        body: usesWorkbenchLayout
                            ? _keptPanelBodies(
                                group,
                                activePanel,
                                visible: !hidden,
                              )
                            : null,
                        onShowSource: () => unawaited(
                          activateWorkbenchView(WorkspacePanelId.sourceDebug),
                        ),
                        onShowSymbols: () {
                          if (!resourceDocked) {
                            unawaited(toggleWorkbenchResource());
                          }
                        },
                        chrome: PanelChrome(
                          tabs: List.unmodifiable(group.panels),
                          activePanel: activePanel,
                          highlighted: _session.mergeTarget == group.id,
                          onSelect: (panel) => _selectGroupPanel(group, panel),
                          onFloat: () =>
                              usesWorkbenchLayout &&
                                  activePanel.isWorkbenchOutput
                              ? _floatSinglePanel(
                                  group,
                                  activePanel,
                                  workspaceSize,
                                )
                              : _floatPanel(group, activePanel, workspaceSize),
                          onClose: () => _hidePanel(group, activePanel),
                          onSeparate: () => _separatePanel(group, activePanel),
                          onDragStart: (_) => _startDrag(group),
                          onDragUpdate: (details) =>
                              _moveGroup(group, details.delta, workspaceSize),
                          onDragEnd: (_) => _endDrag(group),
                          draggable: _session.gridMode && !expanded,
                          groupId: group.id,
                          tabsDraggable: true,
                          tabsAtBottom: tabsAtBottom,
                          sidebar: usesWorkbenchLayout ? group.sidebar : null,
                          onWorkspaceAction: usesWorkbenchLayout
                              ? (action) => _panelAction(group, action)
                              : null,
                          onTabAccept: (data, targetIndex) =>
                              _acceptTabDrop(group, data, targetIndex),
                          onTabDragStart: (data) =>
                              _startTabDrag(group, data, workspaceSize),
                          onTabDragUpdate: (data, details) =>
                              _updateTabDrag(data, details, workspaceSize),
                          onTabDragEnd: (data, details) => _finishTabDrag(
                            group,
                            data,
                            details,
                            workspaceSize,
                          ),
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
                    onDragStart: group == _outputGroup && usesWorkbenchLayout
                        ? startOutputDrag
                        : _startResize,
                    onDragEnd: group == _outputGroup && usesWorkbenchLayout
                        ? endOutputDrag
                        : _endResize,
                    onDrag: (delta) {
                      if (group == _outputGroup && usesWorkbenchLayout) {
                        updateOutputDrag(delta.dy);
                      } else {
                        _resizeGroup(group, delta, workspaceSize, top: true);
                      }
                    },
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
                  if (!tabsAtBottom)
                    WorkspaceResizeHandle(
                      handleKey: ValueKey('resize-${group.id}'),
                      alignment: Alignment.bottomRight,
                      cursor: SystemMouseCursors.resizeDownRight,
                      width: 18,
                      height: 18,
                      enabled: !expanded,
                      visible: !usesWorkbenchLayout,
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
          ),
        ),
      ),
    );
  }

  Widget _keptPanelBodies(
    WorkspaceGroup group,
    WorkspacePanelId activePanel, {
    required bool visible,
  }) {
    _panelBodyKeys.putIfAbsent(
      activePanel,
      () => GlobalKey(debugLabel: 'panel-body-${activePanel.name}'),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final panel in group.panels)
          if (_panelBodyKeys.containsKey(panel))
            Offstage(
              offstage: panel != activePanel,
              child: ExcludeFocus(
                excluding: !visible || panel != activePanel,
                child: TickerMode(
                  enabled: visible && panel == activePanel,
                  child: WorkspacePanelVisibility(
                    visible: visible && panel == activePanel,
                    child: KeyedSubtree(
                      key: _panelBodyKeys[panel],
                      child: buildWorkspacePanelBody(
                        panel,
                        widget.controller,
                        workbench: true,
                        adaptiveWorkbench: true,
                        visible: visible && panel == activePanel,
                        onShowSource: () => unawaited(
                          activateWorkbenchView(WorkspacePanelId.sourceDebug),
                        ),
                        onShowSymbols: () {
                          if (!resourceDocked) {
                            unawaited(toggleWorkbenchResource());
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  List<Widget> _dockOverlays(Size size) {
    final widgets = <Widget>[];
    for (final side in WorkspaceSidebarSide.values) {
      final group = _sidebarGroup(side);
      if (group != null) {
        final expanded = !_sidebarHidden(group);
        final rect = _groupPixelRect(group, size);
        widgets.add(
          AnimatedPositioned(
            key: ValueKey('sidebar-handle-${side.name}'),
            duration: _layoutAnimationDuration,
            curve: Curves.easeOutCubic,
            left: side == WorkspaceSidebarSide.left ? rect.right : null,
            right: side == WorkspaceSidebarSide.right
                ? size.width - rect.left
                : null,
            top: math.max(0, size.height * .43 - 36),
            width: TalUiTheme.of(context).touchOptimized ? 44 : 18,
            height: 72,
            child: WorkspaceSidebarHandle(
              side: side,
              expanded: expanded,
              label:
                  '${expanded ? '收起' : '打开'}${side == WorkspaceSidebarSide.left ? '左' : '右'}侧栏：${group.panels.map((p) => p == WorkspacePanelId.watch ? '变量监视' : p.title).join('、')}',
              onPressed: () => _selectGroupPanel(
                group,
                group.activePanel,
                toggleSidebar: true,
              ),
              onDragStart: _startResize,
              onDrag: (delta) => _resizeGroup(
                group,
                delta,
                size,
                left: side == WorkspaceSidebarSide.right,
                right: side == WorkspaceSidebarSide.left,
              ),
              onDragEnd: _endResize,
            ),
          ),
        );
      }
    }
    if (_tabDrag.sourceGroupId == null && _tabDrag.detachedPanel == null) {
      return widgets;
    }
    if (_tabDrag.cancelled) return widgets;
    final candidate = _tabDrag.dockCandidate;
    if (candidate != null) {
      final Rect previewRect;
      if (candidate == WorkspaceDockEdge.bottom) {
        final top = (_outputGroup?.rect.top.clamp(.2, .9) ?? .76) * size.height;
        previewRect = Rect.fromLTRB(0, top, size.width, size.height);
      } else {
        final side = candidate.sidebar!;
        final group = _sidebarGroup(side);
        final width = group == null
            ? math.min(
                size.width * .4,
                side == WorkspaceSidebarSide.left ? 240.0 : 320.0,
              )
            : _sidebarPixels(group, size);
        previewRect = Rect.fromLTWH(
          side == WorkspaceSidebarSide.left ? 0 : size.width - width,
          0,
          width,
          size.height,
        );
      }
      widgets.add(
        Positioned.fromRect(
          rect: previewRect,
          child: IgnorePointer(
            child: WorkspaceDockPreview(
              key: ValueKey('dock-preview-${candidate.name}'),
              edge: candidate,
              armed: _tabDrag.dockArmed,
            ),
          ),
        ),
      );
    }
    for (final edge in WorkspaceDockEdge.values) {
      // Keep the existing bottom tab strip available for reordering its tabs.
      if (edge == WorkspaceDockEdge.bottom && _draggingFromBottom) continue;
      final bottom = edge == WorkspaceDockEdge.bottom;
      widgets.add(
        Positioned(
          left: edge != WorkspaceDockEdge.right ? 0 : null,
          right: edge != WorkspaceDockEdge.left ? 0 : null,
          top: bottom ? null : 0,
          // The bottom edge owns the corners, matching _dockEdgeAt.
          bottom: bottom ? 0 : 32,
          width: bottom ? null : 32,
          height: bottom ? 32 : null,
          child: DragTarget<PanelTabDragData>(
            key: ValueKey('dock-drop-${edge.name}'),
            onWillAcceptWithDetails: (_) => !_tabDrag.cancelled,
            onMove: (_) => _setDockDropCandidate(edge),
            onAcceptWithDetails: (details) {
              if (!_tabDrag.cancelled) {
                _dockPanelAtEdge(details.data.panel, edge);
              }
            },
            builder: (_, _, _) => IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: TalColors.accent.withValues(
                      alpha: candidate == edge ? .9 : .25,
                    ),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  bool get _draggingFromBottom =>
      _outputGroup != null && _tabDrag.sourceGroupId == _outputGroup!.id;

  WorkspaceDockEdge? _dockEdgeAt(Offset local) {
    final size = _session.workspaceSize;
    if (!usesWorkbenchLayout || !(Offset.zero & size).contains(local)) {
      return null;
    }
    if (local.dy >= size.height - 32) {
      return _draggingFromBottom ? null : WorkspaceDockEdge.bottom;
    }
    if (local.dx <= 32) return WorkspaceDockEdge.left;
    if (local.dx >= size.width - 32) return WorkspaceDockEdge.right;
    return null;
  }

  void _setDockDropCandidate(WorkspaceDockEdge? edge) =>
      _tabDrag.setDockCandidate(edge);

  void _applyDefaultLayout() =>
      _layout.reset(detachedPanels: detachedWindows.windows.keys);

  Future<void> saveLayout() => _persistLayout(report: true);

  WorkspaceLayoutSnapshot projectLayout() => _layout.projectLayout(
    uiScale: widget.controller.uiScale,
    detachedPlacements: _detachedPlacements,
  );

  Future<void> saveProject({bool saveAs = false}) async {
    try {
      final path = await _persistence.saveProject(
        saveAs: saveAs,
        pickPath: widget.projectSavePathPicker ?? pickProjectSavePath,
        isActive: () => mounted,
        capture: () => ProjectDocument(
          settings: widget.controller.projectSettings(),
          layout: projectLayout(),
          gridMode: _session.gridMode,
          focused: _layout.focused,
        ),
      );
      if (!mounted || path == null) return;
      widget.controller.report('项目已保存：$path');
      widget.onPanelVisibilityChanged?.call();
    } catch (error) {
      if (mounted) {
        widget.controller.applyBackendEvent(BackendEventType.error, {
          'code': 'project_save_failed',
          'message': '保存项目失败：$error',
        });
      }
    }
  }

  Future<void> openProject() async {
    try {
      final path = await _persistence.openProject(
        pickPath: widget.projectOpenPathPicker ?? pickProjectOpenPath,
        isActive: () => mounted,
        apply: (document) async {
          await widget.controller.restoreProjectSettings(document.settings);
          if (!mounted) return false;
          await detachedWindows.returnAllPanels();
          if (!mounted) return false;
          _detachedPlacements.clear();
          _persistence.cancelPendingSave();
          _session.gridMode = document.gridMode;
          _layout.focused = document.focused;
          applyProjectLayout(document.layout);
          return true;
        },
      );
      if (!mounted || path == null) return;
      _scheduleLayoutSave();
      widget.controller.report('已打开项目：$path');
    } catch (error) {
      if (mounted) {
        widget.controller.applyBackendEvent(BackendEventType.error, {
          'code': 'project_open_failed',
          'message': '打开项目失败：$error',
        });
      }
    }
  }

  Future<void> _persistLayout({required bool report}) async {
    try {
      await _persistence.saveLayout(
        WorkspaceLayoutSnapshot(
          groups: _session.groups,
          uiScale: widget.controller.uiScale,
          version: widget.workbenchLayout ? 4 : 1,
          legacyPanels: _layout.legacyPanels,
        ),
      );
      if (report && mounted) widget.controller.report('工作区布局已保存。');
    } on Object catch (error) {
      if (mounted) widget.controller.report('保存布局失败：$error');
    }
  }

  Future<void> restoreLayout() => _restoreLayout();

  Future<void> _restoreLayout({bool reportMissing = true}) async {
    try {
      await _persistence.restoreLayout((layout) {
        if (!mounted) return;
        if (layout == null) {
          if (reportMissing) widget.controller.report('尚未保存过工作区布局。');
          return;
        }
        if (widget.workbenchLayout && layout.version == 1 && !reportMissing) {
          widget.controller.report('已启用横向工作台。旧布局已保留，可在“视图”中恢复。');
          return;
        }
        applyProjectLayout(layout);
        widget.controller.report('已恢复保存的工作区布局');
      });
    } on Object catch (error) {
      if (mounted) widget.controller.report('恢复布局失败：$error');
    }
  }

  void applyProjectLayout(WorkspaceLayoutSnapshot snapshot) {
    setState(
      () => _layout.applyLayout(
        snapshot,
        detachedPanels: detachedWindows.windows.keys,
      ),
    );
    widget.onPanelVisibilityChanged?.call();
    widget.controller.setUiScale(snapshot.uiScale);
  }

  void resetLayout() {
    setState(_applyDefaultLayout);
    widget.onPanelVisibilityChanged?.call();
    widget.controller.report('已重置为默认工作区布局。');
    _scheduleLayoutSave();
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
    final existing = _session.groups
        .where((group) => group.panels.contains(panel))
        .firstOrNull;
    if (existing != null) {
      _selectGroupPanel(existing, panel);
      return;
    }
    if (usesWorkbenchLayout) {
      if (panel.isWorkbenchOutput) {
        _showWorkbenchOutput(panel);
      } else if (panel == WorkspacePanelId.symbols ||
          panel == WorkspacePanelId.watch) {
        _dockPanel(
          panel,
          panel == WorkspacePanelId.symbols
              ? WorkspaceSidebarSide.left
              : WorkspaceSidebarSide.right,
        );
      } else {
        _movePanelToWorkspace(panel);
      }
      return;
    }
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

  void _startDrag(WorkspaceGroup group) {
    if (!_session.gridMode) return;
    _layout.automatic = false;
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
    if (usesWorkbenchLayout && !_session.gridMode && (left || right)) {
      final sidebar = group.sidebar != null
          ? group
          : group == _primaryGroup
          ? _sidebarGroup(
              left ? WorkspaceSidebarSide.left : WorkspaceSidebarSide.right,
            )
          : null;
      if (sidebar != null) {
        if (_sidebarHidden(sidebar)) return;
        setState(() {
          final change = sidebar.sidebar == WorkspaceSidebarSide.left
              ? delta.dx
              : -delta.dx;
          sidebar.sidebarWidth = (sidebar.sidebarWidth + change).clamp(
            220,
            math.max(220, workspaceSize.width * .6),
          );
          _reflowWorkbench();
        });
        return;
      }
    }
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
    _layout.automatic = false;
    _session.resetResize();
    setState(() => _resizing = true);
  }

  void _endResize() {
    _session.resetResize();
    setState(() => _resizing = false);
    _scheduleLayoutSave();
  }

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
        sidebar: group.sidebar,
        sidebarWidth: group.sidebarWidth,
        sidebarCollapsed: group.sidebarCollapsed,
      );
      for (final groupPanel in panels) {
        _detachedPlacements[groupPanel] = placement;
      }
      _session.groups.remove(group);
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    await window.show();
    _scheduleLayoutSave();
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
        sidebar: group.sidebar,
        sidebarWidth: group.sidebarWidth,
        sidebarCollapsed: group.sidebarCollapsed,
      );
      _detachPanel(group, panel);
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    await window.show();
    _scheduleLayoutSave();
    if (widget.windowSync.isStarted) unawaited(detachedWindows.prewarm());
  }

  void _detachPanel(WorkspaceGroup group, WorkspacePanelId panel) =>
      _layout.detachPanel(group, panel);

  void _hidePanel(WorkspaceGroup group, WorkspacePanelId panel) {
    setState(() {
      _detachPanel(group, panel);
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
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
    if (_tabDrag.cancelled) return;
    if (usesWorkbenchLayout && _tabDrag.dockCandidate != null) {
      _dockPanelAtEdge(data.panel, _tabDrag.dockCandidate!);
      return;
    }
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
      _scheduleLayoutSave();
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
      target.sidebarCollapsed = false;
      if (target.sidebar != null) _layout.overlaySidebar = target.sidebar;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _finishTabDrag(
    WorkspaceGroup source,
    PanelTabDragData data,
    DraggableDetails details,
    Size workspaceSize,
  ) {
    final mergeTargetId = _tabDrag.armedMergeTarget;
    final previewPosition = _lastTabDragPreviewPosition;
    final sidebar = _tabDrag.dockCandidate;
    final cancelled = _tabDrag.cancelled;
    final local = _tabDrag.localPosition;
    _resetTabDragState();
    if (cancelled || !source.panels.contains(data.panel)) {
      unawaited(tabDragPreview.hide());
      return;
    }
    if (sidebar != null && usesWorkbenchLayout) {
      unawaited(tabDragPreview.hide());
      _dockPanelAtEdge(data.panel, sidebar);
      return;
    }
    // A tab strip can report acceptance after its insertion geometry has gone
    // away. The explicit workspace edge remains authoritative in that case.
    if (details.wasAccepted) {
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
    if (usesWorkbenchLayout &&
        local != null &&
        (Offset.zero & workspaceSize).contains(local)) {
      unawaited(tabDragPreview.hide());
      if (_primaryGroup == null) _movePanelToWorkspace(data.panel);
      return;
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
    _layout.automatic = false;
    _tabDrag.beginLocal(source.id);
    setState(() {
      if (!usesWorkbenchLayout &&
          source.activePanel == data.panel &&
          source.panels.length > 1) {
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
    if (_tabDrag.sourceGroupId != data.sourceGroupId || workspaceSize.isEmpty) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    _tabDrag.localPosition = localPosition;
    if (_tabDrag.cancelled) return;
    unawaited(_moveTabDragPreview(details.globalPosition));
    final insideWorkspace = (Offset.zero & workspaceSize).contains(
      localPosition,
    );
    if (!insideWorkspace) {
      _setDockDropCandidate(null);
      _clearTabMergeCandidate();
      return;
    }
    final sidebar = _dockEdgeAt(localPosition);
    _setDockDropCandidate(sidebar);
    if (sidebar != null) return;
    final normalizedPosition = Offset(
      localPosition.dx / workspaceSize.width,
      localPosition.dy / workspaceSize.height,
    );
    WorkspaceGroup? hoveredGroup;
    for (final group in _session.groupsByZ.reversed) {
      if (_sidebarHidden(group)) continue;
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
    if (_tabDrag.sourceGroupId == null) return;
    final position = _mainWindowOrigin + globalPosition - _tabDragPreviewAnchor;
    _lastTabDragPreviewPosition = position;
    await tabDragPreview.showAt(position);
  }

  void _handleTabDragChanged() {
    if (mounted) {
      setState(() => _session.mergeTarget = _tabDrag.highlightedGroupId);
    }
  }

  void _setTabMergeCandidate(String? targetId) =>
      _tabDrag.setMergeCandidate(targetId);
  void _clearTabMergeCandidate() => _tabDrag.setMergeCandidate(null);

  void _resetTabDragState({bool notify = true}) {
    _tabDrag.reset(notify: notify);
    if (!notify) _session.mergeTarget = null;
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
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _handleDetachedTabDrag(DetachedTabDragEvent event) {
    switch (event.phase) {
      case DetachedTabDragPhase.start:
        _tabDrag.beginDetached(event.sourceWindowId, event.panel);
        unawaited(_captureMainWindowOrigin());
        unawaited(
          tabDragPreview.prepare(
            panel: event.panel,
            size: event.previewSize ?? event.panel.preferredWindowSize,
          ),
        );
      case DetachedTabDragPhase.update:
        if (!_tabDrag.matchesDetached(event.sourceWindowId, event.panel)) {
          return;
        }
        final position = event.screenPosition;
        if (position == null) return;
        unawaited(tabDragPreview.showAt(position - const Offset(56, 15)));
        final local = _workspacePositionAtScreen(position);
        final sidebar = local == null ? null : _dockEdgeAt(local);
        _setDockDropCandidate(sidebar);
        final target = sidebar != null
            ? null
            : _mainGroupAtScreenPosition(position);
        final targetId = target?.id;
        _tabDrag.highlightDetachedGroup(targetId);
      case DetachedTabDragPhase.end:
        if (!_tabDrag.matchesDetached(event.sourceWindowId, event.panel)) {
          return;
        }
        _tabDrag.reset();
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
    final local = _workspacePositionAtScreen(screenPosition);
    final sidebar = local == null ? null : _dockEdgeAt(local);
    if (targetGroup != null ||
        sidebar != null ||
        (usesWorkbenchLayout && local != null && _primaryGroup == null)) {
      final removed = await detachedWindows.removePanelFromWindow(
        sourceWindowId: event.sourceWindowId,
        panel: event.panel,
      );
      if (!mounted || !removed) return;
      _detachedPlacements.remove(event.panel);
      if (sidebar != null) {
        _dockPanelAtEdge(event.panel, sidebar);
        return;
      }
      if (targetGroup == null) {
        _movePanelToWorkspace(event.panel);
        return;
      }
      setState(() {
        if (!targetGroup.panels.contains(event.panel)) {
          targetGroup.panels.add(event.panel);
        }
        targetGroup.activePanel = event.panel;
        targetGroup.z = _nextZ();
        targetGroup.sidebarCollapsed = false;
        _layout.overlaySidebar = targetGroup.sidebar;
        _reflowWorkbench();
      });
      widget.onPanelVisibilityChanged?.call();
      _scheduleLayoutSave();
    }
  }

  Offset? _workspacePositionAtScreen(Offset screenPosition) {
    if (_session.workspaceSize.isEmpty) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return null;
    final mainWindowPosition = screenPosition - _mainWindowOrigin;
    final localPosition = renderObject.globalToLocal(mainWindowPosition);
    if (!(Offset.zero & _session.workspaceSize).contains(localPosition)) {
      return null;
    }
    return localPosition;
  }

  WorkspaceGroup? _mainGroupAtScreenPosition(Offset screenPosition) {
    final local = _workspacePositionAtScreen(screenPosition);
    if (local == null) return null;
    for (final group in _session.groupsByZ.reversed) {
      if (!_sidebarHidden(group) &&
          _groupPixelRect(group, _session.workspaceSize).contains(local)) {
        return group;
      }
    }
    return null;
  }

  void _restoreDetachedGroup(DetachedPanelPlacement placement) =>
      _layout.restoreDetachedGroup(placement);

  Rect _snapRectToGrid(Rect rect) {
    return _geometry.snapRectToGrid(rect, _session.workspaceSize);
  }

  void _mergeInto(WorkspaceGroup source, String targetId) =>
      _layout.mergeInto(source, targetId);

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
