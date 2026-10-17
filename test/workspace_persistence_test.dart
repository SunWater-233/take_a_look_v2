import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';

void main() {
  late Directory directory;
  late File layoutFile;
  late TakeALookController controller;
  late MainWindowSync windowSync;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tal_persistence_');
    layoutFile = File('${directory.path}/layout.json');
    controller = TakeALookController();
    windowSync = MainWindowSync(controller);
  });

  tearDown(() async {
    await windowSync.dispose();
    controller.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> pumpWorkbench(WidgetTester tester, {File? file}) async {
    await tester.binding.setSurfaceSize(const Size(2000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable: controller.uiScaleListenable,
          child: child,
          builder: (context, scale, child) =>
              TalUiScaleViewport(scale: scale, child: child!),
        ),
        home: MainWorkbench(
          controller: controller,
          windowSync: windowSync,
          layoutFile: file ?? layoutFile,
        ),
      ),
    );
  }

  DockingWorkspaceState workspace(WidgetTester tester) =>
      tester.state<DockingWorkspaceState>(find.byType(DockingWorkspace));

  Future<void> waitForLog(WidgetTester tester, String prefix) async {
    for (
      var attempt = 0;
      attempt < 100 &&
          !controller.logs.any((entry) => entry.message.startsWith(prefix));
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      controller.logs.any((entry) => entry.message.startsWith(prefix)),
      isTrue,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('saved analysis layout is restored on a fresh workbench', (
    tester,
  ) async {
    final repository = WorkspaceLayoutRepository(layoutFile);
    await tester.runAsync(
      () => repository.save(
        WorkspaceLayoutSnapshot(
          uiScale: 1,
          groups: [
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
              id: 'plot',
              panels: const [
                WorkspacePanelId.plot,
                WorkspacePanelId.sourceDebug,
                WorkspacePanelId.analysis,
              ],
              activePanel: WorkspacePanelId.plot,
              rect: const Rect.fromLTWH(0.22, 0, 0.78, 0.76),
              z: 26,
            ),
            WorkspaceGroup(
              id: 'log',
              panels: const [WorkspacePanelId.log],
              activePanel: WorkspacePanelId.log,
              rect: const Rect.fromLTWH(0, 0.76, 1, 0.24),
              z: 4,
            ),
          ],
        ),
      ),
    );
    await pumpWorkbench(tester);
    await waitForLog(tester, '已启用横向工作台');
    expect(workspace(tester).usesWorkbenchLayout, isTrue);
    await tester.runAsync(workspace(tester).restoreLayout);
    await waitForLog(tester, '已恢复保存的工作区布局');
    await tester.tap(find.byKey(const ValueKey('panel-tab-analysis')));
    await tester.pump();
    await workspace(tester).togglePanelVisibility(WorkspacePanelId.log);
    await tester.drag(
      find.byKey(const ValueKey('resize-plot')),
      const Offset(-140, -80),
    );
    controller.setUiScale(1.25);
    await tester.pumpAndSettle();
    final plot = find.byKey(const ValueKey('workspace-group-plot'));
    final savedRect = tester.getRect(plot);
    await tester.runAsync(workspace(tester).saveLayout);
    final saved = await tester.runAsync(repository.load);
    expect(saved!.groups.last.activePanel, WorkspacePanelId.analysis);
    expect(saved.uiScale, 1.25);

    // Recreate both the controller and the workbench, as on an application restart.
    await tester.pumpWidget(const SizedBox.shrink());
    await windowSync.dispose();
    controller.dispose();
    await tester.runAsync(() async {
      controller = TakeALookController();
      windowSync = MainWindowSync(controller);
    });
    await pumpWorkbench(tester);
    await waitForLog(tester, '已恢复保存的工作区布局');

    final frame = tester.widget<TalPanelFrame>(
      find.descendant(of: plot, matching: find.byType(TalPanelFrame)),
    );
    expect(frame.panel, WorkspacePanelId.analysis);
    for (final name in ['plot', 'sourceDebug', 'analysis']) {
      expect(
        find.descendant(
          of: plot,
          matching: find.byKey(ValueKey('panel-tab-$name')),
        ),
        findsOneWidget,
      );
    }
    expect(
      tester.getCenter(find.byKey(const ValueKey('panel-tab-plot'))).dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('panel-tab-sourceDebug')))
            .dx,
      ),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('panel-tab-sourceDebug'))).dx,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('panel-tab-analysis'))).dx,
      ),
    );
    expect(workspace(tester).isPanelVisible(WorkspacePanelId.log), isFalse);
    expect(workspace(tester).isPanelVisible(WorkspacePanelId.symbols), isFalse);
    expect(controller.uiScale, 1.25);
    expect(tester.getRect(plot), savedRect);
    expect(find.text('导入一段数据开始分析'), findsOneWidget);

    // Changing scale must not re-run startup restoration or reset current edits.
    final restoredState = workspace(tester);
    await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
    controller.setUiScale(1);
    await tester.pumpAndSettle();
    expect(workspace(tester), same(restoredState));
    expect(controller.uiScale, 1);
    expect(
      tester
          .widget<TalPanelFrame>(
            find.descendant(of: plot, matching: find.byType(TalPanelFrame)),
          )
          .panel,
      WorkspacePanelId.plot,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing saved layout quietly keeps defaults on startup', (
    tester,
  ) async {
    final pendingFile = _PendingLayoutFile();
    final initialLogCount = controller.logs.length;
    await pumpWorkbench(tester, file: pendingFile);
    pendingFile.existsResult.complete(false);
    await tester.pumpAndSettle();

    expect(find.byType(TalPanelFrame), findsNWidgets(2));
    expect(workspace(tester).isPanelVisible(WorkspacePanelId.analysis), isTrue);
    expect(controller.logs, hasLength(initialLogCount));
    await workspace(tester).restoreLayout();
    expect(controller.logs.last.message, '尚未保存过工作区布局。');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('invalid saved layout keeps defaults and reports the failure', (
    tester,
  ) async {
    layoutFile.writeAsStringSync('{invalid layout');
    await pumpWorkbench(tester);
    await waitForLog(tester, '恢复布局失败：');

    expect(find.byType(TalPanelFrame), findsNWidgets(2));
    expect(workspace(tester).isPanelVisible(WorkspacePanelId.plot), isTrue);
    expect(controller.uiScale, 1);
    expect(layoutFile.readAsStringSync(), '{invalid layout');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a saved empty workspace stays empty on startup', (tester) async {
    await tester.runAsync(
      () => WorkspaceLayoutRepository(
        layoutFile,
      ).save(const WorkspaceLayoutSnapshot(groups: [], uiScale: 1, version: 2)),
    );
    await pumpWorkbench(tester);
    await waitForLog(tester, '已恢复保存的工作区布局');
    expect(find.byType(TalPanelFrame), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup loading ignores errors after the workbench closes', (
    tester,
  ) async {
    final pendingFile = _PendingLayoutFile();
    final initialLogCount = controller.logs.length;
    await pumpWorkbench(tester, file: pendingFile);
    await tester.pumpWidget(const SizedBox.shrink());
    pendingFile.existsResult.completeError(const FileSystemException('closed'));
    await tester.pump();
    expect(controller.logs, hasLength(initialLogCount));
    expect(tester.takeException(), isNull);
  });
}

class _PendingLayoutFile extends Fake implements File {
  final existsResult = Completer<bool>();

  @override
  Future<bool> exists() => existsResult.future;
}
