import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';
import 'watch_value_test_helpers.dart';

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets('$mode keeps draft values and analysis state across views', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final folder = Directory.systemTemp.createTempSync('tal_horizontal_');
      final controller = TakeALookController(backendCommand: (_, _) async {});
      final sync = MainWindowSync(controller);
      var controllerDisposed = false;
      addTearDown(() async {
        await sync.dispose();
        if (!controllerDisposed) controller.dispose();
        folder.deleteSync(recursive: true);
      });
      controller.loadDemoSymbols();
      controller.selectSymbols([demoSymbols.first.key]);
      controller.addSelectedToWatch(mode: WatchReadMode.monitor);
      final watch = controller.watches.single;
      controller.applySnapshot({
        'connectionStatus': 'connected',
        'samplingPaused': true,
      });
      controller.analysisSession.replaceData([
        AnalysisSeries(
          name: 'signal',
          color: Colors.orange,
          points: const [
            AnalysisPoint(0, 1),
            AnalysisPoint(1, 3),
            AnalysisPoint(2, 2),
          ],
        ),
      ], '测试记录');
      controller.analysisSession
        ..selectionStart = 0
        ..selectionEnd = 2
        ..updateSelectionStats();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: MainWorkbench(
            controller: controller,
            windowSync: sync,
            layoutFile: File('${folder.path}/layout.json'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-group-watch')),
        findsOneWidget,
      );
      final input = find.byKey(
        ValueKey('compact-watch-input-${watch.symbol.key}'),
      );
      await editWatchValue(tester, watch.symbol.key);
      await tester.enterText(input, '123.5');
      final selector = find.byKey(
        ValueKey('watch-read-mode-${watch.symbol.key}'),
      );
      expect(
        tester
            .widget<TalDropdown<WatchReadMode>>(selector)
            .values
            .map((mode) => mode.label),
        ['仅监视', '采集', '手动读取'],
      );
      await tester.tap(selector);
      await tester.pumpAndSettle();
      for (final label in ['仅监视', '采集', '手动读取']) {
        expect(find.byKey(ValueKey('dropdown-item-$label')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('dropdown-item-手动读取')));
      await tester.pumpAndSettle();
      expect(watch.readMode, WatchReadMode.manual);
      await tester.tap(find.byKey(const ValueKey('panel-tab-analysis')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-group-watch')),
        findsOneWidget,
      );
      // The sidebars now stay under user control. Reclaim the left sidebar to
      // give the analysis view enough width for its statistics column.
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-left')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('analysis-horizontal-workbench')),
        findsOneWidget,
      );
      expect(find.text('区间统计'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pumpAndSettle();
      expect(controller.watchInputDrafts[watch.symbol.key], '123.5');
      await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
      await tester.pumpAndSettle();
      expect(controller.analysisSession.selectedRange, (0.0, 2.0));
      expect(controller.watchInputDrafts[watch.symbol.key], '123.5');
      final workspace = tester.state<DockingWorkspaceState>(
        find.byType(DockingWorkspace),
      );
      final initialHeight = tester
          .getSize(find.byKey(const ValueKey('workspace-group-plot')))
          .height;
      await tester.tap(find.byKey(const ValueKey('workbench-output-toggle')));
      await tester.pumpAndSettle();
      expect(workspace.outputDocked, isTrue);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('workspace-group-plot')))
            .height,
        lessThan(initialHeight),
      );
      await tester.tap(find.byKey(const ValueKey('workbench-output-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('workspace-group-plot')))
            .height,
        initialHeight,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      controllerDisposed = true;
    });
  }

  testWidgets('compact variable panel remains usable at 280 pixels', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch(mode: WatchReadMode.manual);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(inputMode: TalInputMode.touch),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              height: 560,
              child: buildWorkspacePanel(
                WorkspacePanelId.watch,
                controller,
                workbench: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('手动读取'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
