import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/theme.dart';
import 'package:take_a_look_v2/src/window_sync.dart';
import 'package:take_a_look_v2/src/workspace.dart';

void main() {
  testWidgets('resizing a shared boundary keeps connected panels aligned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: MainWindowSync(controller),
          ),
        ),
      ),
    );

    final header = find.byKey(const ValueKey('workspace-group-header'));
    final symbols = find.byKey(const ValueKey('workspace-group-symbols'));
    final plot = find.byKey(const ValueKey('workspace-group-plot'));
    final headerBefore = tester.getRect(header);
    final symbolsBefore = tester.getRect(symbols);
    final plotBefore = tester.getRect(plot);

    await tester.drag(
      find.byKey(const ValueKey('resize-header-right')),
      const Offset(100, 0),
    );
    await tester.pump();

    final headerAfter = tester.getRect(header);
    final symbolsAfter = tester.getRect(symbols);
    final plotAfter = tester.getRect(plot);
    final boundaryDelta = headerAfter.right - headerBefore.right;
    expect(boundaryDelta, greaterThan(0));
    expect(symbolsAfter.right - symbolsBefore.right, closeTo(boundaryDelta, 1));
    expect(plotAfter.left - plotBefore.left, closeTo(boundaryDelta, 1));

    workspaceKey.currentState!.resetLayout();
    await tester.pump();
    final resetHeader = tester.getRect(header);
    final resetSymbols = tester.getRect(symbols);

    await tester.drag(
      find.byKey(const ValueKey('resize-header-bottom')),
      const Offset(0, 80),
    );
    await tester.pump();

    final resizedHeader = tester.getRect(header);
    final resizedSymbols = tester.getRect(symbols);
    final verticalDelta = resizedHeader.bottom - resetHeader.bottom;
    expect(verticalDelta, greaterThan(0));
    expect(resizedSymbols.top - resetSymbols.top, closeTo(verticalDelta, 1));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
