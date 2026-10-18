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
  bool _focusedWorkbench = false;
  bool _automaticWorkbenchLayout = true;
  final Map<WorkspacePanelId, GlobalKey> _panelBodyKeys = {};
  WorkspaceSidebarSide? _overlaySidebar;
  WorkspaceDockEdge? _dockDropCandidate;
  Timer? _dockDropTimer;
  bool _dockDropArmed = false;
  bool _tabDragCancelled = false;
  bool _resizing = false;
  Offset? _tabDragLocalPosition;
  Timer? _layoutSaveTimer;
  Future<void> _layoutWrite = Future<void>.value();
  String? _projectPath;
  bool _projectBusy = false;
  double? _outputDragHeight;
  int _layoutRestoreRevision = 0;

  String? get projectPath => _projectPath;

  bool get usesWorkbenchLayout => widget.workbenchLayout && !_legacyLayout;
  bool get resourceDocked => _session.groups.any(
    (group) =>
        group.panels.contains(WorkspacePanelId.symbols) &&
        !_sidebarHidden(group),
  );
  WorkspaceGroup? get _outputGroup => _session.groups
      .where((group) => group.id == 'output' && group.sidebar == null)
      .firstOrNull;
  bool get outputDocked => usesWorkbenchLayout
      ? _outputGroup != null && !_outputGroup!.outputCollapsed
      : _session.groups.any(
          (group) => group.panels.contains(WorkspacePanelId.log),
        );
  bool get focusedWorkbench => _focusedWorkbench;
  bool get gridMode => _session.gridMode;
  WorkspaceGroup? get _primaryGroup =>
      _session.groups.where((group) => group.id == 'plot').firstOrNull;
  bool get _narrowWorkspace =>
      _session.workspaceSize.width > 0 && _session.workspaceSize.width < 900;

  Duration get _layoutAnimationDuration =>
      usesWorkbenchLayout &&
          !_resizing &&
          _draggedTabSource == null &&
          !MediaQuery.disableAnimationsOf(context)
      ? const Duration(milliseconds: 220)
      : Duration.zero;

  WorkspaceGroup? _sidebarGroup(WorkspaceSidebarSide side) =>
      _session.groups.where((group) => group.sidebar == side).firstOrNull;

  bool _sidebarHidden(WorkspaceGroup group) =>
      usesWorkbenchLayout &&
      group.sidebar != null &&
      (group.sidebarCollapsed ||
          _focusedWorkbench ||
          (_narrowWorkspace && _overlaySidebar != group.sidebar));

  double _sidebarPixels(WorkspaceGroup group, Size size) {
    if (_narrowWorkspace) {
      return group.sidebarWidth.clamp(180, math.max(180, size.width - 44));
    }
    final requested = _session.groups
        .where((g) => g.sidebar != null && !_sidebarHidden(g))
        .fold(0.0, (sum, g) => sum + g.sidebarWidth);
    final scale = requested == 0
        ? 1.0
        : math.min(1.0, math.max(280, size.width - 380) / requested);
    return group.sidebarWidth * scale;
  }

  Rect _groupPixelRect(WorkspaceGroup group, Size size) {
    if (usesWorkbenchLayout && group == _outputGroup && group.outputCollapsed) {
      return _toPixelRect(group.rect, size).translate(0, size.height);
    }
    if (usesWorkbenchLayout && group.sidebar != null && !_session.gridMode) {
      final width = _sidebarPixels(group, size);
      final hidden = _sidebarHidden(group);
      final left = group.sidebar == WorkspaceSidebarSide.left
          ? (hidden ? -width : 0.0)
          : (hidden ? size.width : size.width - width);
      return Rect.fromLTWH(left, 0, width, group.rect.height * size.height);
    }
    if (usesWorkbenchLayout && group == _primaryGroup && _focusedWorkbench) {
      return Offset.zero & size;
    }
    if (usesWorkbenchLayout && _focusedWorkbench && group != _primaryGroup) {
      return _toPixelRect(group.rect, size).translate(0, size.height);
    }
    return _toPixelRect(group.rect, size);
  }

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
    setState(() {
      if (panel.isWorkbenchOutput) {
        _focusedWorkbench = false;
        group.outputCollapsed = false;
      }
      if (usesWorkbenchLayout && group.sidebar != null) {
        final close =
            toggleSidebar &&
            group.activePanel == panel &&
            !_sidebarHidden(group);
        group.sidebarCollapsed = close;
        _overlaySidebar = close ? null : group.sidebar;
        if (!close) _focusedWorkbench = false;
      }
      group.activePanel = panel;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void toggleWorkbenchFocus() {
    setState(() {
      _focusedWorkbench = !_focusedWorkbench;
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
        _focusedWorkbench = false;
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
      _focusedWorkbench = false;
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

  void _reflowWorkbench() {
    if (!usesWorkbenchLayout || _session.gridMode) return;
    final size = _session.workspaceSize.isEmpty
        ? const Size(1280, 800)
        : _session.workspaceSize;
    final output = _outputGroup;
    final height = outputDocked ? output!.rect.top.clamp(.2, .9) : 1.0;
    final leftGroup = _sidebarGroup(WorkspaceSidebarSide.left);
    final rightGroup = _sidebarGroup(WorkspaceSidebarSide.right);
    final left =
        leftGroup == null || _sidebarHidden(leftGroup) || _narrowWorkspace
        ? 0.0
        : _sidebarPixels(leftGroup, size) / size.width;
    final right =
        rightGroup == null || _sidebarHidden(rightGroup) || _narrowWorkspace
        ? 1.0
        : 1 - _sidebarPixels(rightGroup, size) / size.width;
    for (final group in _session.groups) {
      if (group == _primaryGroup && group.sidebar == null) {
        group.rect = Rect.fromLTWH(left, 0, right - left, height);
      }
      if (group.sidebar != null) {
        final width = _sidebarPixels(group, size) / size.width;
        group.rect = Rect.fromLTWH(
          group.sidebar == WorkspaceSidebarSide.left ? 0 : 1 - width,
          0,
          width,
          height,
        );
      }
    }
  }

  void _dockPanel(WorkspacePanelId panel, WorkspaceSidebarSide side) {
    final source = _session.groups
        .where((g) => g.panels.contains(panel))
        .firstOrNull;
    var target = _sidebarGroup(side);
    if (target == source && target != null) {
      _selectGroupPanel(target, panel);
      return;
    }
    setState(() {
      if (source != null) _detachPanel(source, panel);
      target ??= WorkspaceGroup(
        id: _session.nextGroupId('sidebar_${side.name}'),
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, 0, .25, 1),
        z: _nextZ(),
        sidebar: side,
        sidebarWidth: side == WorkspaceSidebarSide.left ? 240 : 320,
      );
      if (!_session.groups.contains(target)) _session.groups.add(target!);
      if (!target!.panels.contains(panel)) target!.panels.add(panel);
      target!.activePanel = panel;
      target!.sidebarCollapsed = false;
      target!.z = _nextZ();
      _overlaySidebar = side;
      _focusedWorkbench = false;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _dockPanelAtEdge(WorkspacePanelId panel, WorkspaceDockEdge edge) {
    if (edge.sidebar case final side?) {
      _dockPanel(panel, side);
      return;
    }
    final source = _session.groups
        .where((group) => group.panels.contains(panel))
        .firstOrNull;
    var target = _outputGroup;
    if (source == target && target != null) {
      _selectGroupPanel(target, panel);
      return;
    }
    setState(() {
      if (source != null) _detachPanel(source, panel);
      target ??= WorkspaceGroup(
        id: 'output',
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, .76, 1, .24),
        z: _nextZ(),
      );
      if (!_session.groups.contains(target)) _session.groups.add(target!);
      if (!target!.panels.contains(panel)) target!.panels.add(panel);
      target!.activePanel = panel;
      target!.outputCollapsed = false;
      target!.z = _nextZ();
      _overlaySidebar = null;
      _focusedWorkbench = false;
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _movePanelToWorkspace(WorkspacePanelId panel) {
    final source = _session.groups
        .where((g) => g.panels.contains(panel))
        .firstOrNull;
    var target = _primaryGroup;
    if (target == source && target != null) {
      _selectGroupPanel(target, panel);
      return;
    }
    setState(() {
      if (source != null) _detachPanel(source, panel);
      target ??= WorkspaceGroup(
        id: 'plot',
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, 0, 1, 1),
        z: _nextZ(),
      );
      if (!_session.groups.contains(target)) _session.groups.add(target!);
      if (!target!.panels.contains(panel)) target!.panels.add(panel);
      target!.activePanel = panel;
      _overlaySidebar = null;
      _reflowWorkbench();
    });
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
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_persistLayout(report: false)),
    );
  }

  bool _handleDragKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _draggedTabSource == null) {
      return false;
    }
    _tabDragCancelled = true;
    _setDockDropCandidate(null);
    _clearTabMergeCandidate();
    unawaited(tabDragPreview.hide());
    return true;
  }

  @visibleForTesting
  String? get debugTabMergeCandidate => _tabMergeCandidate;

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
    if (_layoutSaveTimer?.isActive == true) {
      unawaited(_persistLayout(report: false));
    }
    _layoutSaveTimer?.cancel();
    _dockDropTimer?.cancel();
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
        if (usesWorkbenchLayout || (resized && _automaticWorkbenchLayout)) {
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
            _tabDragCancelled = true;
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
    final expanded = group == _primaryGroup && _focusedWorkbench;
    final hidden =
        _sidebarHidden(group) || (_focusedWorkbench && group != _primaryGroup);
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
    if (_draggedTabSource == null && _detachedDraggedPanel == null) {
      return widgets;
    }
    if (_tabDragCancelled) return widgets;
    final candidate = _dockDropCandidate;
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
              armed: _dockDropArmed,
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
            onWillAcceptWithDetails: (_) => !_tabDragCancelled,
            onMove: (_) => _setDockDropCandidate(edge),
            onAcceptWithDetails: (details) {
              if (!_tabDragCancelled) {
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
      _outputGroup != null && _draggedTabSource == _outputGroup!.id;

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

  void _setDockDropCandidate(WorkspaceDockEdge? edge) {
    if (_dockDropCandidate == edge) return;
    _dockDropTimer?.cancel();
    setState(() {
      _dockDropCandidate = edge;
      _dockDropArmed = false;
    });
    if (edge == null) return;
    _clearTabMergeCandidate();
    _dockDropTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _dockDropCandidate == edge) {
        setState(() => _dockDropArmed = true);
      }
    });
  }

  void _applyDefaultLayout() {
    _automaticWorkbenchLayout = true;
    _legacyLayout = false;
    _focusedWorkbench = false;
    _overlaySidebar = null;
    _session.groups
      ..clear()
      ..addAll(
        widget.workbenchLayout
            ? [
                WorkspaceGroup(
                  id: 'resources',
                  panels: const [WorkspacePanelId.symbols],
                  activePanel: WorkspacePanelId.symbols,
                  rect: const Rect.fromLTWH(0, 0, .2, 1),
                  z: 2,
                  sidebar: WorkspaceSidebarSide.left,
                  sidebarWidth: 240,
                ),
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
                  sidebar: WorkspaceSidebarSide.right,
                  sidebarWidth: 320,
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

  Future<void> saveLayout() => _persistLayout(report: true);

  WorkspaceLayoutSnapshot projectLayout() {
    final groups = [
      for (final group in _session.groups)
        WorkspaceGroup.fromJson(group.toJson()),
    ];
    // Floating panels return to their saved dock positions when a project opens.
    for (final entry in _detachedPlacements.entries) {
      if (groups.any((group) => group.panels.contains(entry.key))) continue;
      final placement = entry.value;
      var group = groups.where((g) => g.id == placement.groupId).firstOrNull;
      if (group == null) {
        group = WorkspaceGroup(
          id: placement.groupId,
          panels: [entry.key],
          activePanel: entry.key,
          rect: placement.groupRect,
          z: placement.groupZ,
          sidebar: placement.sidebar,
          sidebarWidth: placement.sidebarWidth,
          sidebarCollapsed: placement.sidebarCollapsed,
        );
        groups.add(group);
      } else {
        group.panels.add(entry.key);
      }
    }
    return WorkspaceLayoutSnapshot(
      groups: groups,
      uiScale: widget.controller.uiScale,
      version: widget.workbenchLayout ? 4 : 1,
      legacyPanels: _legacyLayout,
    );
  }

  Future<void> saveProject({bool saveAs = false}) async {
    if (_projectBusy) return;
    _projectBusy = true;
    try {
      var path = saveAs ? null : _projectPath;
      path ??= await (widget.projectSavePathPicker ?? pickProjectSavePath)();
      if (path == null || path.isEmpty || !mounted) return;
      if (!path.toLowerCase().endsWith('.talproj')) path = '$path.talproj';
      final document = ProjectDocument(
        settings: widget.controller.projectSettings(),
        layout: projectLayout(),
        gridMode: _session.gridMode,
        focused: _focusedWorkbench,
      );
      await document.write(File(path));
      if (!mounted) return;
      _projectPath = path;
      widget.controller.report('项目已保存：$path');
      widget.onPanelVisibilityChanged?.call();
    } catch (error) {
      if (mounted) {
        widget.controller.applyBackendEvent(BackendEventType.error, {
          'code': 'project_save_failed',
          'message': '保存项目失败：$error',
        });
      }
    } finally {
      _projectBusy = false;
    }
  }

  Future<void> openProject() async {
    if (_projectBusy) return;
    _projectBusy = true;
    try {
      final path =
          await (widget.projectOpenPathPicker ?? pickProjectOpenPath)();
      if (path == null || path.isEmpty || !mounted) return;
      final document = await ProjectDocument.read(File(path));
      if (!mounted) return;
      _layoutRestoreRevision++;
      await widget.controller.restoreProjectSettings(document.settings);
      if (!mounted) return;
      await detachedWindows.returnAllPanels();
      if (!mounted) return;
      _detachedPlacements.clear();
      _layoutSaveTimer?.cancel();
      _session.gridMode = document.gridMode;
      _focusedWorkbench = document.focused;
      applyProjectLayout(document.layout);
      _projectPath = path;
      _scheduleLayoutSave();
      widget.controller.report('已打开项目：$path');
    } catch (error) {
      if (mounted) {
        widget.controller.applyBackendEvent(BackendEventType.error, {
          'code': 'project_open_failed',
          'message': '打开项目失败：$error',
        });
      }
    } finally {
      _projectBusy = false;
    }
  }

  Future<void> _persistLayout({required bool report}) async {
    _layoutSaveTimer?.cancel();
    final snapshot = WorkspaceLayoutSnapshot.fromJson(
      WorkspaceLayoutSnapshot(
        groups: _session.groups,
        uiScale: widget.controller.uiScale,
        version: widget.workbenchLayout ? 4 : 1,
        legacyPanels: _legacyLayout,
      ).toJson(),
    );
    try {
      final repository = _layoutRepository;
      _layoutWrite = _layoutWrite
          .catchError((Object _) {})
          .then((_) => repository.save(snapshot));
      await _layoutWrite;
      if (report && mounted) widget.controller.report('工作区布局已保存。');
    } on Object catch (error) {
      if (mounted) widget.controller.report('保存布局失败：$error');
    }
  }

  Future<void> restoreLayout() => _restoreLayout();

  Future<void> _restoreLayout({bool reportMissing = true}) async {
    final revision = ++_layoutRestoreRevision;
    try {
      final layout = await _layoutRepository.load();
      if (!mounted || revision != _layoutRestoreRevision) return;
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
    } on Object catch (error) {
      if (mounted) widget.controller.report('恢复布局失败：$error');
    }
  }

  void applyProjectLayout(WorkspaceLayoutSnapshot snapshot) {
    final layout = WorkspaceLayoutSnapshot.fromJson(snapshot.toJson());
    final restored = <WorkspaceGroup>[];
    final seenPanels = <WorkspacePanelId>{};
    // Versions 2 and 3 nested build output and registers inside the log tab.
    // Expand that tab in its saved group, preserving its position and peers.
    if (widget.workbenchLayout &&
        const [2, 3].contains(layout.version) &&
        !layout.legacyPanels) {
      final logGroup = layout.groups
          .where((group) => group.panels.contains(WorkspacePanelId.log))
          .firstOrNull;
      if (logGroup != null) {
        final existingPanels = layout.groups
            .expand((group) => group.panels)
            .toSet();
        logGroup.panels.insertAll(
          logGroup.panels.indexOf(WorkspacePanelId.log) + 1,
          workspaceOutputPanels
              .skip(1)
              .where((panel) => !existingPanels.contains(panel)),
        );
      }
    }
    for (final group in layout.groups) {
      if (widget.workbenchLayout &&
          layout.version == 2 &&
          !layout.legacyPanels) {
        if (group.id == 'resources') {
          group.sidebar = WorkspaceSidebarSide.left;
        }
        if (group.id == 'watch') group.sidebar = WorkspaceSidebarSide.right;
        if (group.sidebar != null) {
          group.sidebarWidth = group.sidebar == WorkspaceSidebarSide.left
              ? 240
              : 320;
        }
      }
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
      _session.zCursor = _session.groups.fold(
        20,
        (value, group) => math.max(value, group.z),
      );
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    widget.controller.setUiScale(layout.uiScale);
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
    _automaticWorkbenchLayout = false;
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
    if (_tabDragCancelled) return;
    if (usesWorkbenchLayout && _dockDropCandidate != null) {
      _dockPanelAtEdge(data.panel, _dockDropCandidate!);
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
      if (target.sidebar != null) _overlaySidebar = target.sidebar;
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
    final mergeTargetId = _armedTabMergeTarget;
    final previewPosition = _lastTabDragPreviewPosition;
    final sidebar = _dockDropCandidate;
    final cancelled = _tabDragCancelled;
    final local = _tabDragLocalPosition;
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
    _automaticWorkbenchLayout = false;
    _resetTabDragState(notify: false);
    setState(() {
      _draggedTabSource = source.id;
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
    if (_draggedTabSource != data.sourceGroupId || workspaceSize.isEmpty) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    _tabDragLocalPosition = localPosition;
    if (_tabDragCancelled) return;
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
    final changed =
        _session.mergeTarget != null ||
        _draggedTabSource != null ||
        _dockDropCandidate != null;
    _dockDropTimer?.cancel();
    _dockDropCandidate = null;
    _dockDropArmed = false;
    _tabDragCancelled = false;
    _tabDragLocalPosition = null;
    _tabMergeTimer?.cancel();
    _tabMergeTimer = null;
    _tabMergeCandidate = null;
    _armedTabMergeTarget = null;
    _draggedTabSource = null;
    if (!changed) return;
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
      _reflowWorkbench();
    });
    widget.onPanelVisibilityChanged?.call();
    _scheduleLayoutSave();
  }

  void _handleDetachedTabDrag(DetachedTabDragEvent event) {
    switch (event.phase) {
      case DetachedTabDragPhase.start:
        setState(() {
          _detachedDragSourceWindowId = event.sourceWindowId;
          _detachedDraggedPanel = event.panel;
          _tabDragCancelled = false;
        });
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
        final local = _workspacePositionAtScreen(position);
        final sidebar = local == null ? null : _dockEdgeAt(local);
        _setDockDropCandidate(sidebar);
        final target = sidebar != null
            ? null
            : _mainGroupAtScreenPosition(position);
        final targetId = target?.id;
        if (_session.mergeTarget != targetId && mounted) {
          setState(() => _session.mergeTarget = targetId);
        }
      case DetachedTabDragPhase.end:
        if (_detachedDragSourceWindowId != event.sourceWindowId ||
            _detachedDraggedPanel != event.panel) {
          return;
        }
        _dockDropTimer?.cancel();
        setState(() {
          _detachedDragSourceWindowId = null;
          _detachedDraggedPanel = null;
          _dockDropCandidate = null;
          _dockDropArmed = false;
          _session.mergeTarget = null;
        });
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
        _overlaySidebar = targetGroup.sidebar;
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

  void _restoreDetachedGroup(DetachedPanelPlacement placement) {
    _session.zCursor = math.max(_session.zCursor, placement.groupZ);
    final panels = placement.panels
        .where(
          (panel) =>
              !_session.groups.any((group) => group.panels.contains(panel)),
        )
        .toList();
    if (panels.isEmpty) return;

    final originalGroup =
        _session.groups
            .where((group) => group.id == placement.groupId)
            .firstOrNull ??
        (placement.sidebar == null ? null : _sidebarGroup(placement.sidebar!));
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
      originalGroup.sidebarCollapsed = false;
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
        sidebar: placement.sidebar,
        sidebarWidth: placement.sidebarWidth,
        sidebarCollapsed: placement.sidebarCollapsed,
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
