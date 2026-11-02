import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';

class _Workbench {
  _Workbench(this.tester)
    : directory = Directory.systemTemp.createTempSync('tal_output_'),
      controller = TakeALookController(backendCommand: (_, _) async {}) {
    sync = MainWindowSync(controller);
  }

  final WidgetTester tester;
  final Directory directory;
  final TakeALookController controller;
  late final MainWindowSync sync;
  File get file => File('${directory.path}/layout.json');
  DockingWorkspaceState get workspace =>
      tester.state<DockingWorkspaceState>(find.byType(DockingWorkspace));

  Future<void> mount({TalInputMode mode = TalInputMode.mouseKeyboard}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(inputMode: mode),
        home: MainWorkbench(
          controller: controller,
          windowSync: sync,
          layoutFile: file,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await sync.dispose();
    controller.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
    await tester.binding.setSurfaceSize(null);
  }

  TalPanelFrame frame(String group) => tester.widget<TalPanelFrame>(
    find.descendant(
      of: find.byKey(ValueKey('workspace-group-$group')),
      matching: find.byType(TalPanelFrame),
    ),
  );
}

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets('$mode output uses independent panels with bottom tabs', (
      tester,
    ) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      bench.controller.addLog('independent event log');
      await bench.mount(mode: mode);
      await bench.workspace.toggleWorkbenchOutput();
      await tester.pumpAndSettle();

      expect(bench.frame('output').chrome!.tabs, workspaceOutputPanels);
      expect(bench.frame('output').chrome!.tabsAtBottom, isTrue);
      final outputRect = tester.getRect(
        find.byKey(const ValueKey('workspace-group-output')),
      );
      for (final panel in workspaceOutputPanels) {
        final tabRect = tester.getRect(
          find.byKey(ValueKey('panel-tab-${panel.name}')),
        );
        expect(tabRect.top, greaterThan(outputRect.center.dy));
        expect(find.text(panel.title), findsOneWidget);
      }
      expect(
        tester.getRect(find.byKey(const ValueKey('log-selection-area'))).bottom,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byKey(const ValueKey('panel-tab-log'))).dy,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('panel-tab-registers')));
      await tester.pumpAndSettle();
      expect(bench.frame('output').panel, WorkspacePanelId.registers);
      expect(find.text('暂停目标后查看寄存器'), findsOneWidget);
      expect(find.byKey(const ValueKey('log-selection-area')), findsNothing);
      bench.controller.applyDebugState({
        'registers': {'r0': 42},
      });
      await tester.pumpAndSettle();
      expect(find.text('R0   42'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('panel-tab-buildOutput')));
      await tester.pumpAndSettle();
      expect(find.text('编译和下载的输出将显示在这里。'), findsOneWidget);
      await bench.workspace.togglePanelVisibility(WorkspacePanelId.log);
      await tester.pumpAndSettle();
      expect(bench.workspace.isPanelVisible(WorkspacePanelId.log), isFalse);
      expect(bench.frame('output').chrome!.tabs, [
        WorkspacePanelId.buildOutput,
        WorkspacePanelId.registers,
      ]);
      await bench.workspace.showPanel(WorkspacePanelId.log);
      await tester.pumpAndSettle();
      expect(bench.frame('output').panel, WorkspacePanelId.log);
      expect(find.textContaining('independent event log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '$kind output drags open, snaps, collapses and reopens for download',
      (tester) async {
        final bench = _Workbench(tester);
        addTearDown(bench.dispose);
        await bench.mount();
        final bar = find.byKey(const ValueKey('workbench-output-drag'));
        final initialHandleY = tester
            .getCenter(find.byKey(const ValueKey('sidebar-handle-right')))
            .dy;
        final gesture = await tester.startGesture(
          tester.getCenter(bar),
          kind: kind,
        );
        await gesture.moveBy(const Offset(0, -290));
        await tester.pump();
        final output = find.byKey(const ValueKey('workspace-group-output'));
        final raisedHandleY = tester
            .getCenter(find.byKey(const ValueKey('sidebar-handle-right')))
            .dy;
        expect(raisedHandleY, lessThan(initialHandleY));
        await gesture.moveBy(const Offset(0, -300));
        await tester.pump();
        for (final side in WorkspaceSidebarSide.values) {
          final handle = tester.getRect(
            find.byKey(ValueKey('sidebar-handle-${side.name}')),
          );
          expect(handle.center.dy, lessThan(raisedHandleY));
          expect(handle.bottom, lessThan(tester.getTopLeft(output).dy));
        }
        await gesture.moveBy(const Offset(0, 300));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(bench.workspace.outputDocked, isTrue);
        expect(tester.getSize(output).height, closeTo(297, 1));
        await tester.tap(find.byKey(const ValueKey('panel-tab-registers')));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('resize-output-top')),
          const Offset(0, 340),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(bench.workspace.outputDocked, isFalse);
        for (final side in WorkspaceSidebarSide.values) {
          expect(
            tester
                .getCenter(find.byKey(ValueKey('sidebar-handle-${side.name}')))
                .dy,
            closeTo(initialHandleY, .1),
          );
        }
        // A second drag can reopen the same group with its selected tab intact.
        await tester.drag(bar, const Offset(0, -290), kind: kind);
        await tester.pumpAndSettle();
        expect(bench.frame('output').panel, WorkspacePanelId.registers);
        bench.controller.applySourceTask({
          'id': 'build-and-download',
          'status': 'running',
          'phase': 'build',
        });
        await tester.pumpAndSettle();
        expect(bench.frame('output').panel, WorkspacePanelId.buildOutput);
        await bench.workspace.toggleWorkbenchOutput();
        await tester.pumpAndSettle();
        expect(bench.workspace.outputDocked, isFalse);
        bench.controller.applySourceTask({
          'id': 'build-and-download',
          'status': 'running',
          'phase': 'download',
        });
        await tester.pumpAndSettle();
        expect(bench.workspace.outputDocked, isTrue);
        expect(bench.frame('output').panel, WorkspacePanelId.buildOutput);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a build opens and selects its independent output panel', (
    tester,
  ) async {
    final bench = _Workbench(tester);
    addTearDown(bench.dispose);
    await bench.mount();
    bench.workspace.toggleWorkbenchFocus();
    bench.controller.applySourceTask({
      'id': 'first-build',
      'status': 'running',
      'phase': 'build',
      'lines': [
        {'seq': 1, 'text': 'first build output'},
      ],
    });
    await tester.pumpAndSettle();
    expect(bench.workspace.focusedWorkbench, isFalse);
    expect(bench.frame('output').panel, WorkspacePanelId.buildOutput);
    expect(bench.frame('output').chrome!.tabs, workspaceOutputPanels);
    expect(find.text('first build output'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('panel-tab-registers')));
    bench.controller.applySourceTask({
      'id': 'first-build',
      'lines': [
        {'seq': 2, 'text': 'more output'},
      ],
    });
    await tester.pumpAndSettle();
    expect(bench.frame('output').panel, WorkspacePanelId.registers);
    await bench.workspace.togglePanelVisibility(WorkspacePanelId.buildOutput);
    bench.controller.applySourceTask({
      'id': 'second-build',
      'status': 'running',
      'phase': 'build',
      'lines': [
        {'seq': 1, 'text': 'second build output'},
      ],
    });
    await tester.pumpAndSettle();
    expect(bench.frame('output').panel, WorkspacePanelId.buildOutput);
    expect(find.text('second build output'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'output tabs can move independently and merge back at the bottom',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      await bench.workspace.toggleWorkbenchOutput();
      await tester.pumpAndSettle();
      final registerTab = find.byKey(const ValueKey('panel-tab-registers'));
      final gesture = await tester.startGesture(
        tester.getCenter(registerTab),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -35));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('panel-tab-sourceDebug'))),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        bench.frame('plot').chrome!.tabs,
        contains(WorkspacePanelId.registers),
      );
      expect(bench.frame('output').chrome!.tabs, [
        WorkspacePanelId.log,
        WorkspacePanelId.buildOutput,
      ]);

      final returnGesture = await tester.startGesture(
        tester.getCenter(registerTab),
        kind: PointerDeviceKind.mouse,
      );
      await returnGesture.moveBy(const Offset(0, 35));
      await tester.pump();
      await returnGesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('panel-tab-buildOutput'))),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await returnGesture.up();
      await tester.pumpAndSettle();
      expect(
        bench.frame('output').chrome!.tabs,
        contains(WorkspacePanelId.registers),
      );
      expect(
        bench.frame('plot').chrome!.tabs,
        isNot(contains(WorkspacePanelId.registers)),
      );
      expect(bench.frame('output').panel, WorkspacePanelId.registers);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('floating an output panel leaves the other two docked', (
    tester,
  ) async {
    const createChannel = MethodChannel('mixin.one/desktop_multi_window');
    const windowChannel = MethodChannel(
      'mixin.one/window_controller/output_window',
    );
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    Map<String, dynamic>? assignedPanel;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') return 'output_window';
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method == 'invokeMethod') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        if (arguments['method'] == configureDetachedPanelMethod) {
          assignedPanel = Map<String, dynamic>.from(
            arguments['arguments'] as Map,
          );
        }
      }
      return null;
    });
    addTearDown(() {
      for (final channel in [createChannel, windowChannel, channelsChannel]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final bench = _Workbench(tester);
    addTearDown(bench.dispose);
    await bench.mount();
    await bench.workspace.showPanel(WorkspacePanelId.registers);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-menu-output')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('弹出为独立窗口'));
    await tester.pumpAndSettle();
    final launch = detachedPanelLaunchFromJson(assignedPanel)!;
    expect(launch.panel, WorkspacePanelId.registers);
    expect(launch.groupPanels, [WorkspacePanelId.registers]);
    expect(bench.frame('output').chrome!.tabs, [
      WorkspacePanelId.log,
      WorkspacePanelId.buildOutput,
    ]);
    expect(bench.workspace.isPanelVisible(WorkspacePanelId.registers), isTrue);
    await bench.workspace.toggleWorkbenchOutput();
    await bench.workspace.toggleWorkbenchOutput();
    await tester.pumpAndSettle();
    expect(bench.frame('output').chrome!.tabs, [
      WorkspacePanelId.log,
      WorkspacePanelId.buildOutput,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'old nested output migrates once and preserves independent visibility',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      final repository = WorkspaceLayoutRepository(bench.file);
      await tester.runAsync(
        () => repository.save(
          WorkspaceLayoutSnapshot(
            version: 3,
            uiScale: 1,
            groups: [
              WorkspaceGroup(
                id: 'output',
                panels: const [WorkspacePanelId.log],
                activePanel: WorkspacePanelId.log,
                rect: const Rect.fromLTWH(0, .76, 1, .24),
                z: 4,
              ),
            ],
          ),
        ),
      );
      await bench.mount();
      await tester.runAsync(bench.workspace.restoreLayout);
      await tester.pumpAndSettle();
      expect(bench.frame('output').chrome!.tabs, workspaceOutputPanels);
      await bench.workspace.togglePanelVisibility(WorkspacePanelId.log);
      await bench.workspace.showPanel(WorkspacePanelId.registers);
      await tester.pumpAndSettle();
      await tester.runAsync(bench.workspace.saveLayout);
      final saved = (await tester.runAsync(repository.load))!;
      expect(saved.version, 4);
      expect(saved.groups.single.panels, [
        WorkspacePanelId.buildOutput,
        WorkspacePanelId.registers,
      ]);
      final old = (await tester.runAsync(
        () =>
            WorkspaceLayoutRepository(File('${bench.file.path}.v3.bak')).load(),
      ))!;
      expect(old.groups.single.panels, [WorkspacePanelId.log]);
      await tester.runAsync(bench.workspace.restoreLayout);
      await tester.pumpAndSettle();
      expect(bench.workspace.isPanelVisible(WorkspacePanelId.log), isFalse);
      expect(bench.frame('output').panel, WorkspacePanelId.registers);
      expect(bench.frame('output').chrome!.tabsAtBottom, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
