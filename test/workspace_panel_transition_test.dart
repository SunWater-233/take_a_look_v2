import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout_controller.dart';

void main() {
  test('tab insertion preserves order and unique ownership across groups', () {
    final layout = WorkspaceLayoutController(workbenchLayout: true)..reset();
    final primary = layout.primaryGroup!;
    final sidebar = layout.sidebarGroup(WorkspaceSidebarSide.right)!;
    layout.movePanelToGroup(WorkspacePanelId.plot, primary, 3);
    expect(primary.panels, [
      WorkspacePanelId.sourceDebug,
      WorkspacePanelId.analysis,
      WorkspacePanelId.plot,
    ]);
    layout.movePanelToGroup(WorkspacePanelId.analysis, sidebar, 0);
    expect(sidebar.panels, [WorkspacePanelId.analysis, WorkspacePanelId.watch]);
    expect(primary.panels, [
      WorkspacePanelId.sourceDebug,
      WorkspacePanelId.plot,
    ]);
    expect(sidebar.activePanel, WorkspacePanelId.analysis);
    final panels = layout.session.groups
        .expand((group) => group.panels)
        .toList();
    expect(panels.length, panels.toSet().length);
  });

  test(
    'external tab insertion opens a collapsed destination without duplication',
    () {
      final layout = WorkspaceLayoutController(workbenchLayout: true)..reset();
      final primary = layout.primaryGroup!;
      layout.detachPanel(primary, WorkspacePanelId.analysis);
      final sidebar = layout.sidebarGroup(WorkspaceSidebarSide.right)!;
      sidebar.sidebarCollapsed = true;
      layout.movePanelToGroup(WorkspacePanelId.analysis, sidebar, 200);
      expect(sidebar.panels, [
        WorkspacePanelId.watch,
        WorkspacePanelId.analysis,
      ]);
      expect(sidebar.sidebarCollapsed, isFalse);
      expect(layout.overlaySidebar, WorkspaceSidebarSide.right);
      layout.movePanelToGroup(WorkspacePanelId.analysis, sidebar, -1);
      expect(sidebar.panels, [
        WorkspacePanelId.analysis,
        WorkspacePanelId.watch,
      ]);
    },
  );
}
