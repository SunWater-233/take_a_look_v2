import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'panel_types.dart';
import 'workspace_geometry.dart';
import 'workspace_layout.dart';
import 'workspace_session.dart';

/// Owns layout transitions without widget, filesystem, or native-window work.
class WorkspaceLayoutController {
  WorkspaceLayoutController({required this.workbenchLayout});

  final WorkspaceSession session = WorkspaceSession();
  final WorkspaceGeometry geometry = const WorkspaceGeometry();
  bool workbenchLayout;
  bool legacyPanels = false;
  bool focused = false;
  bool automatic = true;
  WorkspaceSidebarSide? overlaySidebar;

  bool get usesWorkbenchLayout => workbenchLayout && !legacyPanels;
  WorkspaceGroup? get outputGroup => session.groups
      .where((group) => group.id == 'output' && group.sidebar == null)
      .firstOrNull;
  WorkspaceGroup? get primaryGroup =>
      session.groups.where((group) => group.id == 'plot').firstOrNull;
  bool get narrowWorkspace =>
      session.workspaceSize.width > 0 && session.workspaceSize.width < 900;
  bool get outputDocked => usesWorkbenchLayout
      ? outputGroup != null && !outputGroup!.outputCollapsed
      : session.groups.any(
          (group) => group.panels.contains(WorkspacePanelId.log),
        );

  WorkspaceGroup? sidebarGroup(WorkspaceSidebarSide side) =>
      session.groups.where((group) => group.sidebar == side).firstOrNull;

  bool sidebarHidden(WorkspaceGroup group) =>
      usesWorkbenchLayout &&
      group.sidebar != null &&
      (group.sidebarCollapsed ||
          focused ||
          (narrowWorkspace && overlaySidebar != group.sidebar));

  double sidebarPixels(WorkspaceGroup group, Size size) {
    if (narrowWorkspace) {
      return group.sidebarWidth.clamp(180, math.max(180, size.width - 44));
    }
    final requested = session.groups
        .where((g) => g.sidebar != null && !sidebarHidden(g))
        .fold(0.0, (sum, g) => sum + g.sidebarWidth);
    final scale = requested == 0
        ? 1.0
        : math.min(1.0, math.max(280, size.width - 380) / requested);
    return group.sidebarWidth * scale;
  }

  Rect groupPixelRect(WorkspaceGroup group, Size size) {
    if (usesWorkbenchLayout && group == outputGroup && group.outputCollapsed) {
      return geometry.toPixelRect(group.rect, size).translate(0, size.height);
    }
    if (usesWorkbenchLayout && group.sidebar != null && !session.gridMode) {
      final width = sidebarPixels(group, size);
      final hidden = sidebarHidden(group);
      final left = group.sidebar == WorkspaceSidebarSide.left
          ? (hidden ? -width : 0.0)
          : (hidden ? size.width : size.width - width);
      return Rect.fromLTWH(left, 0, width, group.rect.height * size.height);
    }
    if (usesWorkbenchLayout && group == primaryGroup && focused) {
      return Offset.zero & size;
    }
    if (usesWorkbenchLayout && focused && group != primaryGroup) {
      return geometry.toPixelRect(group.rect, size).translate(0, size.height);
    }
    return geometry.toPixelRect(group.rect, size);
  }

  void selectPanel(
    WorkspaceGroup group,
    WorkspacePanelId panel, {
    bool toggleSidebar = false,
  }) {
    if (panel.isWorkbenchOutput) {
      focused = false;
      group.outputCollapsed = false;
    }
    if (usesWorkbenchLayout && group.sidebar != null) {
      final close =
          toggleSidebar && group.activePanel == panel && !sidebarHidden(group);
      group.sidebarCollapsed = close;
      overlaySidebar = close ? null : group.sidebar;
      if (!close) focused = false;
    }
    group.activePanel = panel;
    reflow();
  }

  void dockPanel(WorkspacePanelId panel, WorkspaceSidebarSide side) {
    final source = groupForPanel(panel);
    final target = sidebarGroup(side);
    if (target != null && target == source) {
      selectPanel(target, panel);
      return;
    }
    final destination = _transferPanel(
      panel,
      target,
      () => WorkspaceGroup(
        id: session.nextGroupId('sidebar_${side.name}'),
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, 0, .25, 1),
        z: session.nextZ(),
        sidebar: side,
        sidebarWidth: side == WorkspaceSidebarSide.left ? 240 : 320,
      ),
    );
    destination.sidebarCollapsed = false;
    destination.z = session.nextZ();
    overlaySidebar = side;
    focused = false;
    reflow();
  }

  void dockPanelAtEdge(WorkspacePanelId panel, WorkspaceDockEdge edge) {
    if (edge.sidebar case final side?) {
      dockPanel(panel, side);
      return;
    }
    final source = groupForPanel(panel);
    final target = outputGroup;
    if (target != null && target == source) {
      selectPanel(target, panel);
      return;
    }
    final destination = _transferPanel(
      panel,
      target,
      () => WorkspaceGroup(
        id: 'output',
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, .76, 1, .24),
        z: session.nextZ(),
      ),
    );
    destination.outputCollapsed = false;
    destination.z = session.nextZ();
    overlaySidebar = null;
    focused = false;
    reflow();
  }

  void movePanelToWorkspace(WorkspacePanelId panel) {
    final source = groupForPanel(panel);
    final target = primaryGroup;
    if (target != null && target == source) {
      selectPanel(target, panel);
      return;
    }
    _transferPanel(
      panel,
      target,
      () => WorkspaceGroup(
        id: 'plot',
        panels: [panel],
        activePanel: panel,
        rect: const Rect.fromLTWH(0, 0, 1, 1),
        z: session.nextZ(),
      ),
    );
    overlaySidebar = null;
    reflow();
  }

  WorkspaceGroup? groupForPanel(WorkspacePanelId panel) =>
      session.groups.where((group) => group.panels.contains(panel)).firstOrNull;

  /// Inserts an external panel, moves it between groups, or reorders its tab.
  /// The insertion index uses the tab strip's positions before removal.
  void movePanelToGroup(
    WorkspacePanelId panel,
    WorkspaceGroup target,
    int insertionIndex,
  ) {
    final source = groupForPanel(panel);
    if (source == target) {
      final sourceIndex = target.panels.indexOf(panel);
      var index = insertionIndex.clamp(0, target.panels.length);
      if (sourceIndex < index) index--;
      target.panels.removeAt(sourceIndex);
      target.panels.insert(index, panel);
      target.activePanel = panel;
      return;
    }
    if (source != null) detachPanel(source, panel);
    if (!target.panels.contains(panel)) {
      target.panels.insert(
        insertionIndex.clamp(0, target.panels.length),
        panel,
      );
    }
    target.activePanel = panel;
    target.z = session.nextZ();
    target.sidebarCollapsed = false;
    if (target.sidebar != null) overlaySidebar = target.sidebar;
    reflow();
  }

  void separatePanel(WorkspaceGroup source, WorkspacePanelId panel, Rect rect) {
    detachPanel(source, panel);
    session.groups.add(
      WorkspaceGroup(
        id: session.nextGroupId('separated'),
        panels: [panel],
        activePanel: panel,
        rect: session.gridMode ? snapRectToGrid(rect) : rect,
        z: session.nextZ(),
      ),
    );
  }

  WorkspaceGroup _transferPanel(
    WorkspacePanelId panel,
    WorkspaceGroup? target,
    WorkspaceGroup Function() create,
  ) {
    final source = groupForPanel(panel);
    if (source != null) detachPanel(source, panel);
    final destination = target ?? create();
    if (!session.groups.contains(destination)) session.groups.add(destination);
    if (!destination.panels.contains(panel)) destination.panels.add(panel);
    destination.activePanel = panel;
    return destination;
  }

  void reflow() {
    if (!usesWorkbenchLayout || session.gridMode) return;
    final size = session.workspaceSize.isEmpty
        ? const Size(1280, 800)
        : session.workspaceSize;
    final output = outputGroup;
    final height = outputDocked ? output!.rect.top.clamp(.2, .9) : 1.0;
    final leftGroup = sidebarGroup(WorkspaceSidebarSide.left);
    final rightGroup = sidebarGroup(WorkspaceSidebarSide.right);
    final left =
        leftGroup == null || sidebarHidden(leftGroup) || narrowWorkspace
        ? 0.0
        : sidebarPixels(leftGroup, size) / size.width;
    final right =
        rightGroup == null || sidebarHidden(rightGroup) || narrowWorkspace
        ? 1.0
        : 1 - sidebarPixels(rightGroup, size) / size.width;
    for (final group in session.groups) {
      if (group == primaryGroup && group.sidebar == null) {
        group.rect = Rect.fromLTWH(left, 0, right - left, height);
      }
      if (group.sidebar != null) {
        final width = sidebarPixels(group, size) / size.width;
        group.rect = Rect.fromLTWH(
          group.sidebar == WorkspaceSidebarSide.left ? 0 : 1 - width,
          0,
          width,
          height,
        );
      }
    }
  }

  void reset({Iterable<WorkspacePanelId> detachedPanels = const []}) {
    automatic = true;
    legacyPanels = false;
    focused = false;
    overlaySidebar = null;
    session.groups
      ..clear()
      ..addAll(
        workbenchLayout
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
                    WorkspacePanelId.freeRtos,
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
    for (final panel in detachedPanels) {
      final group = session.groups
          .where((candidate) => candidate.panels.contains(panel))
          .firstOrNull;
      if (group != null) detachPanel(group, panel);
    }
    reflow();
    if (session.gridMode) {
      for (final group in session.groups) {
        group.rect = snapRectToGrid(group.rect);
      }
    }
  }

  WorkspaceLayoutSnapshot projectLayout({
    required double uiScale,
    required Map<WorkspacePanelId, DetachedPanelPlacement> detachedPlacements,
  }) {
    final groups = [
      for (final group in session.groups)
        WorkspaceGroup.fromJson(group.toJson()),
    ];
    // Floating panels return to their saved dock positions when a project opens.
    for (final entry in detachedPlacements.entries) {
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
      uiScale: uiScale,
      version: workbenchLayout ? 4 : 1,
      legacyPanels: legacyPanels,
    );
  }

  void applyLayout(
    WorkspaceLayoutSnapshot snapshot, {
    Iterable<WorkspacePanelId> detachedPanels = const [],
  }) {
    final layout = WorkspaceLayoutSnapshot.fromJson(snapshot.toJson());
    final restored = <WorkspaceGroup>[];
    final seenPanels = <WorkspacePanelId>{};
    // Versions 2 and 3 nested build output and registers inside the log tab.
    // Expand that tab in its saved group, preserving its position and peers.
    if (workbenchLayout &&
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
      if (workbenchLayout && layout.version == 2 && !layout.legacyPanels) {
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
        (panel) => detachedPanels.contains(panel) || !seenPanels.add(panel),
      );
      if (group.panels.isEmpty) continue;
      if (!group.panels.contains(group.activePanel)) {
        group.activePanel = group.panels.first;
      }
      group.rect = session.gridMode
          ? snapRectToGrid(group.rect)
          : geometry.clampRect(group.rect);
      restored.add(group);
    }
    legacyPanels = layout.version == 1 || layout.legacyPanels;
    automatic = false;
    session.groups
      ..clear()
      ..addAll(restored);
    session.zCursor = session.groups.fold(
      20,
      (value, group) => math.max(value, group.z),
    );
    reflow();
  }

  void detachPanel(WorkspaceGroup group, WorkspacePanelId panel) {
    group.panels.remove(panel);
    if (group.panels.isEmpty) {
      session.groups.remove(group);
    } else if (group.activePanel == panel) {
      group.activePanel = group.panels.first;
    }
  }

  void restoreDetachedGroup(DetachedPanelPlacement placement) {
    session.zCursor = math.max(session.zCursor, placement.groupZ);
    final panels = placement.panels
        .where(
          (panel) =>
              !session.groups.any((group) => group.panels.contains(panel)),
        )
        .toList();
    if (panels.isEmpty) return;

    final originalGroup =
        session.groups
            .where((group) => group.id == placement.groupId)
            .firstOrNull ??
        (placement.sidebar == null ? null : sidebarGroup(placement.sidebar!));
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
      originalGroup.z = session.nextZ();
      originalGroup.sidebarCollapsed = false;
      return;
    }

    session.groups.add(
      WorkspaceGroup(
        id: placement.groupId,
        panels: panels,
        activePanel: panels.contains(placement.activePanel)
            ? placement.activePanel
            : panels.first,
        rect: session.gridMode
            ? snapRectToGrid(placement.groupRect)
            : geometry.clampRect(placement.groupRect),
        z: session.nextZ(),
        sidebar: placement.sidebar,
        sidebarWidth: placement.sidebarWidth,
        sidebarCollapsed: placement.sidebarCollapsed,
      ),
    );
  }

  void mergeInto(WorkspaceGroup source, String targetId) {
    final target = session.groups
        .where((group) => group.id == targetId)
        .firstOrNull;
    if (target == null || target == source) return;
    for (final panel in source.panels) {
      if (!target.panels.contains(panel)) target.panels.add(panel);
    }
    target.activePanel = source.activePanel;
    target.z = session.nextZ();
    session.groups.remove(source);
  }

  Rect snapRectToGrid(Rect rect) =>
      geometry.snapRectToGrid(rect, session.workspaceSize);

  void bringToFront(WorkspaceGroup group) => group.z = session.nextZ();

  void beginGroupDrag(WorkspaceGroup group) {
    if (!session.gridMode) return;
    automatic = false;
    session.dragRemainder = Offset.zero;
    session.draggingGroup = group.id;
    bringToFront(group);
  }

  void moveGroup(WorkspaceGroup group, Offset delta, Size workspaceSize) {
    if (!session.gridMode || workspaceSize.isEmpty) return;
    final totalDelta = Offset(
      session.dragRemainder.dx + delta.dx / workspaceSize.width,
      session.dragRemainder.dy + delta.dy / workspaceSize.height,
    );
    final snappedDelta = Offset(
      geometry.wholeGridDelta(
        totalDelta.dx,
        geometry.gridCellSize / workspaceSize.width,
      ),
      geometry.wholeGridDelta(
        totalDelta.dy,
        geometry.gridCellSize / workspaceSize.height,
      ),
    );
    if (snappedDelta == Offset.zero) {
      session.dragRemainder = totalDelta;
      return;
    }
    final previousRect = group.rect;
    group.rect = geometry.clampRect(
      group.rect.translate(snappedDelta.dx, snappedDelta.dy),
    );
    final actualDelta = group.rect.topLeft - previousRect.topLeft;
    session.dragRemainder = Offset(
      geometry.near(actualDelta.dx, snappedDelta.dx)
          ? totalDelta.dx - snappedDelta.dx
          : 0,
      geometry.near(actualDelta.dy, snappedDelta.dy)
          ? totalDelta.dy - snappedDelta.dy
          : 0,
    );
    session.mergeTarget = findMergeTarget(group);
  }

  void endGroupDrag(WorkspaceGroup group) {
    if (!session.gridMode) return;
    final target = findMergeTarget(group);
    session.resetDrag();
    if (target != null) mergeInto(group, target);
  }

  void resizeGroup(
    WorkspaceGroup group,
    Offset delta,
    Size workspaceSize, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    if (workspaceSize.isEmpty) return;
    if (usesWorkbenchLayout && !session.gridMode && (left || right)) {
      final sidebar = group.sidebar != null
          ? group
          : group == primaryGroup
          ? sidebarGroup(
              left ? WorkspaceSidebarSide.left : WorkspaceSidebarSide.right,
            )
          : null;
      if (sidebar != null) {
        if (sidebarHidden(sidebar)) return;
        final change = sidebar.sidebar == WorkspaceSidebarSide.left
            ? delta.dx
            : -delta.dx;
        sidebar.sidebarWidth = (sidebar.sidebarWidth + change).clamp(
          220,
          math.max(220, workspaceSize.width * .6),
        );
        reflow();
        return;
      }
    }
    if (!session.gridMode) {
      if (left || right) {
        resizeAxis(
          group,
          delta.dx / workspaceSize.width,
          horizontal: true,
          movingEnd: right,
        );
      }
      if (top || bottom) {
        resizeAxis(
          group,
          delta.dy / workspaceSize.height,
          horizontal: false,
          movingEnd: bottom,
        );
      }
      session.mergeTarget = null;
      bringToFront(group);
      return;
    }
    if (left || right) {
      final total = session.resizeRemainder.dx + delta.dx / workspaceSize.width;
      final requested = geometry.wholeGridDelta(
        total,
        geometry.gridCellSize / workspaceSize.width,
      );
      if (requested != 0) {
        final applied = resizeAxis(
          group,
          requested,
          horizontal: true,
          movingEnd: right,
        );
        session.resizeRemainder = Offset(
          geometry.near(applied, requested) ? total - requested : 0,
          session.resizeRemainder.dy,
        );
      } else {
        session.resizeRemainder = Offset(total, session.resizeRemainder.dy);
      }
    }
    if (top || bottom) {
      final total =
          session.resizeRemainder.dy + delta.dy / workspaceSize.height;
      final requested = geometry.wholeGridDelta(
        total,
        geometry.gridCellSize / workspaceSize.height,
      );
      if (requested != 0) {
        final applied = resizeAxis(
          group,
          requested,
          horizontal: false,
          movingEnd: bottom,
        );
        session.resizeRemainder = Offset(
          session.resizeRemainder.dx,
          geometry.near(applied, requested) ? total - requested : 0,
        );
      } else {
        session.resizeRemainder = Offset(session.resizeRemainder.dx, total);
      }
    }
    session.mergeTarget = null;
    bringToFront(group);
  }

  double resizeAxis(
    WorkspaceGroup group,
    double requestedDelta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final participants = session.gridMode
        ? <WorkspaceGroup, bool>{group: movingEnd}
        : geometry.resizeParticipants(
            session.groups,
            group,
            horizontal: horizontal,
            movingEnd: movingEnd,
          );
    final delta = geometry.constrainedBoundaryDelta(
      participants,
      requestedDelta,
      horizontal: horizontal,
    );
    if (delta == 0) return 0;

    for (final entry in participants.entries) {
      entry.key.rect = geometry.moveBoundary(
        entry.key.rect,
        delta,
        horizontal: horizontal,
        movingEnd: entry.value,
      );
    }
    return delta;
  }

  String? findMergeTarget(WorkspaceGroup source) {
    if (session.draggingGroup == null) return null;
    final center = source.rect.center;
    final sorted = session.groupsByZ.reversed;
    for (final group in sorted) {
      if (group == source) continue;
      if (group.rect.inflate(0.012).contains(center)) return group.id;
    }
    return null;
  }
}
