import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/workspace_tab_drag_session.dart';

void main() {
  testWidgets('movement within one merge target retains its dwell deadline', (
    tester,
  ) async {
    final drag = WorkspaceTabDragSession(onChanged: () {});
    addTearDown(drag.dispose);
    drag.beginLocal('plot');
    drag.setMergeCandidate('watch');
    await tester.pump(const Duration(milliseconds: 200));
    drag.setMergeCandidate('watch');
    await tester.pump(const Duration(milliseconds: 99));
    expect(drag.armedMergeTarget, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(drag.armedMergeTarget, 'watch');
    expect(drag.highlightedGroupId, 'watch');
  });

  testWidgets('switching targets cancels the previous deadline', (
    tester,
  ) async {
    final drag = WorkspaceTabDragSession(onChanged: () {});
    addTearDown(drag.dispose);
    drag.beginLocal('plot');
    drag.setMergeCandidate('watch');
    await tester.pump(const Duration(milliseconds: 250));
    drag.setMergeCandidate('resources');
    await tester.pump(const Duration(milliseconds: 50));
    expect(drag.armedMergeTarget, isNull);
    await tester.pump(const Duration(milliseconds: 250));
    expect(drag.armedMergeTarget, 'resources');
  });

  testWidgets('edge dwell replaces merge dwell and survives pointer jitter', (
    tester,
  ) async {
    final drag = WorkspaceTabDragSession(onChanged: () {});
    addTearDown(drag.dispose);
    drag.beginLocal('plot');
    drag.setMergeCandidate('watch');
    await tester.pump(const Duration(milliseconds: 250));
    drag.setDockCandidate(WorkspaceDockEdge.bottom);
    await tester.pump(const Duration(milliseconds: 200));
    drag.setDockCandidate(WorkspaceDockEdge.bottom);
    expect(drag.armedMergeTarget, isNull);
    expect(drag.dockArmed, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(drag.dockArmed, isTrue);
    expect(drag.mergeCandidate, isNull);
  });

  testWidgets('cancel and disposal cannot resurrect a pending target', (
    tester,
  ) async {
    var notifications = 0;
    final drag = WorkspaceTabDragSession(onChanged: () => notifications++);
    drag.beginLocal('plot');
    drag.setDockCandidate(WorkspaceDockEdge.left);
    drag.cancel();
    drag.setMergeCandidate('watch');
    await tester.pump(const Duration(seconds: 1));
    expect(drag.cancelled, isTrue);
    expect(drag.dockCandidate, isNull);
    expect(drag.armedMergeTarget, isNull);

    drag.beginDetached('window-2', WorkspacePanelId.analysis);
    expect(drag.cancelled, isFalse);
    expect(
      drag.matchesDetached('window-1', WorkspacePanelId.analysis),
      isFalse,
    );
    expect(drag.matchesDetached('window-2', WorkspacePanelId.analysis), isTrue);
    drag.setMergeCandidate('plot');
    drag.dispose();
    final settled = notifications;
    await tester.pump(const Duration(seconds: 1));
    expect(notifications, settled);
    expect(drag.armedMergeTarget, isNull);
  });
}
