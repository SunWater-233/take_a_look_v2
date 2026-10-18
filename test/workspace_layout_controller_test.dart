import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout_controller.dart';
import 'package:take_a_look_v2/src/workspace/workspace_session.dart';

void main() {
  test('side, bottom and center transitions retain one owner per panel', () {
    final layout = WorkspaceLayoutController(workbenchLayout: true);
    layout.session.workspaceSize = const Size(1280, 800);
    layout.reset();
    final original = layout.session.groups.expand((g) => g.panels).toSet();

    layout.dockPanel(WorkspacePanelId.analysis, WorkspaceSidebarSide.right);
    layout.dockPanelAtEdge(WorkspacePanelId.analysis, WorkspaceDockEdge.bottom);
    layout.movePanelToWorkspace(WorkspacePanelId.analysis);
    final panels = layout.session.groups
        .expand((group) => group.panels)
        .toList();
    expect(panels.toSet(), original);
    expect(panels.length, original.length);
    expect(layout.outputGroup, isNull);
    expect(layout.primaryGroup!.activePanel, WorkspacePanelId.analysis);
    expect(layout.primaryGroup!.rect, const Rect.fromLTWH(.1875, 0, .5625, 1));
  });

  test('selecting a sidebar tab preserves width and keeps it expanded', () {
    final layout = WorkspaceLayoutController(workbenchLayout: true)..reset();
    final sidebar = layout.sidebarGroup(WorkspaceSidebarSide.right)!;
    sidebar.sidebarWidth = 385;
    layout.dockPanel(WorkspacePanelId.analysis, WorkspaceSidebarSide.right);
    layout.selectPanel(sidebar, WorkspacePanelId.watch);
    layout.selectPanel(sidebar, WorkspacePanelId.watch);
    expect(sidebar.sidebarCollapsed, isFalse);
    expect(sidebar.sidebarWidth, 385);
    layout.selectPanel(sidebar, WorkspacePanelId.watch, toggleSidebar: true);
    expect(sidebar.sidebarCollapsed, isTrue);
  });

  test('legacy migration and detached filtering do not mutate the input', () {
    final source = WorkspaceLayoutSnapshot(
      version: 2,
      uiScale: 1,
      groups: [
        WorkspaceGroup(
          id: 'resources',
          panels: [WorkspacePanelId.symbols, WorkspacePanelId.log],
          activePanel: WorkspacePanelId.log,
          rect: const Rect.fromLTWH(0, 0, .3, 1),
          z: 4,
        ),
        WorkspaceGroup(
          id: 'plot',
          panels: [WorkspacePanelId.plot, WorkspacePanelId.registers],
          activePanel: WorkspacePanelId.registers,
          rect: const Rect.fromLTWH(.3, 0, .7, 1),
          z: 5,
        ),
      ],
    );
    final before = source.toJson();
    final layout = WorkspaceLayoutController(workbenchLayout: true);
    layout.applyLayout(source, detachedPanels: [WorkspacePanelId.registers]);
    final sidebar = layout.sidebarGroup(WorkspaceSidebarSide.left)!;
    expect(sidebar.panels, [
      WorkspacePanelId.symbols,
      WorkspacePanelId.log,
      WorkspacePanelId.buildOutput,
    ]);
    expect(layout.primaryGroup!.panels, [WorkspacePanelId.plot]);
    expect(layout.primaryGroup!.activePanel, WorkspacePanelId.plot);
    expect(source.toJson(), before);
    expect(source.groups.first.sidebar, isNull);
  });

  test(
    'project capture restores floating placement without changing live tabs',
    () {
      final layout = WorkspaceLayoutController(workbenchLayout: true)..reset();
      final primary = layout.primaryGroup!;
      final placement = DetachedPanelPlacement(
        groupId: primary.id,
        groupRect: primary.rect,
        groupZ: primary.z,
        panels: [WorkspacePanelId.analysis],
        originalPanels: List.of(primary.panels),
        activePanel: WorkspacePanelId.analysis,
      );
      layout.detachPanel(primary, WorkspacePanelId.analysis);
      final captured = layout.projectLayout(
        uiScale: 1.25,
        detachedPlacements: {WorkspacePanelId.analysis: placement},
      );
      expect(primary.panels, isNot(contains(WorkspacePanelId.analysis)));
      expect(
        captured.groups.singleWhere((g) => g.id == 'plot').panels,
        contains(WorkspacePanelId.analysis),
      );
      layout.restoreDetachedGroup(placement);
      expect(primary.panels, placement.originalPanels);
      expect(primary.activePanel, WorkspacePanelId.analysis);
      expect(captured.uiScale, 1.25);
    },
  );
}
