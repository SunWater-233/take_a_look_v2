import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';
import 'package:take_a_look_v2/src/workspace/workspace_widgets.dart';

class _Workbench {
  _Workbench(this.tester, {bool detachedEvents = false})
    : directory = Directory.systemTemp.createTempSync('tal_sidebar_'),
      controller = TakeALookController(backendCommand: (_, _) async {}) {
    sync = detachedEvents
        ? _DragWindowSync(controller)
        : MainWindowSync(controller);
  }

  final WidgetTester tester;
  final Directory directory;
  final TakeALookController controller;
  late final MainWindowSync sync;
  final key = GlobalKey<DockingWorkspaceState>();
  bool disposed = false;
  File get file => File('${directory.path}/layout.json');
  DockingWorkspaceState get workspace => key.currentState!;

  Future<void> mount({double width = 1400}) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: key,
            controller: controller,
            windowSync: sync,
            layoutFile: file,
            workbenchLayout: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
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

  String groupOf(WorkspacePanelId panel) => tester
      .widgetList<TalPanelFrame>(find.byType(TalPanelFrame))
      .firstWhere((frame) => frame.chrome!.tabs.contains(panel))
      .chrome!
      .groupId!;

  bool sidebarExpanded(WorkspaceSidebarSide side) => tester
      .widgetList<WorkspaceSidebarHandle>(find.byType(WorkspaceSidebarHandle))
      .singleWhere((handle) => handle.side == side)
      .expanded;

  Future<void> move(WorkspacePanelId panel, String action) async {
    await workspace.activateWorkbenchView(panel);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('panel-menu-${groupOf(panel)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  Future<TestGesture> drag(
    WorkspacePanelId panel,
    Offset target, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('panel-tab-${panel.name}'))),
      kind: kind,
    );
    await gesture.moveBy(const Offset(0, 35));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    return gesture;
  }
}

class _DragWindowSync extends MainWindowSync {
  _DragWindowSync(super.controller);

  final drags = StreamController<DetachedTabDragEvent>.broadcast(sync: true);

  @override
  Stream<DetachedTabDragEvent> get detachedTabDrags => drags.stream;

  @override
  Future<void> dispose() async {
    await drags.close();
    await super.dispose();
  }
}

void main() {
  testWidgets('a detached panel can preview and dock at an empty bottom edge', (
    tester,
  ) async {
    const create = MethodChannel('mixin.one/desktop_multi_window');
    const windows = MethodChannel('mixin.one/window_controller/bottom_window');
    const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(create, (call) async {
      if (call.method == 'createWindow') return 'bottom_window';
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windows, (_) async => null);
    messenger.setMockMethodCallHandler(channels, (call) async {
      if (call.method == 'invokeMethod' &&
          (call.arguments as Map)['method'] == getDetachedWindowBoundsMethod) {
        return {'left': 2000.0, 'top': 0.0, 'width': 400.0, 'height': 300.0};
      }
      return null;
    });
    addTearDown(() {
      for (final channel in [create, windows, channels]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final bench = _Workbench(tester, detachedEvents: true);
    addTearDown(bench.dispose);
    await bench.mount();
    await bench.workspace.showPanel(WorkspacePanelId.registers);
    await tester.pumpAndSettle();
    bench.frame('output').chrome!.onFloat();
    await tester.pumpAndSettle();
    await bench.workspace.toggleWorkbenchOutput();
    await tester.pumpAndSettle();
    expect(
      bench.workspace.detachedWindows.windows,
      contains(WorkspacePanelId.registers),
    );
    final drags = (bench.sync as _DragWindowSync).drags;
    drags.add(
      const DetachedTabDragEvent(
        phase: DetachedTabDragPhase.start,
        sourceWindowId: 'bottom_window',
        panel: WorkspacePanelId.registers,
      ),
    );
    await tester.pump();
    drags.add(
      const DetachedTabDragEvent(
        phase: DetachedTabDragPhase.update,
        sourceWindowId: 'bottom_window',
        panel: WorkspacePanelId.registers,
        screenPosition: Offset(700, 892),
      ),
    );
    await tester.pump();
    final preview = find.byKey(const ValueKey('dock-preview-bottom'));
    expect(preview, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 310));
    expect(tester.widget<WorkspaceDockPreview>(preview).armed, isTrue);
    drags.add(
      const DetachedTabDragEvent(
        phase: DetachedTabDragPhase.end,
        sourceWindowId: 'bottom_window',
        panel: WorkspacePanelId.registers,
        screenPosition: Offset(700, 892),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    // Let the platform-channel handoff complete before checking its new group.
    final output = find.byKey(const ValueKey('workspace-group-output'));
    for (
      var attempt = 0;
      attempt < 100 && output.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(bench.frame('output').chrome!.tabs, [WorkspacePanelId.registers]);
    expect(
      bench.workspace.detachedWindows.windows,
      isNot(contains(WorkspacePanelId.registers)),
    );
    expect(preview, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('populated pages fit in the bottom dock', (tester) async {
    final bench = _Workbench(tester);
    addTearDown(bench.dispose);
    bench.controller.loadDemoSymbols();
    bench.controller.selectSymbols([demoSymbols.first.key]);
    bench.controller.addSelectedToWatch(mode: WatchReadMode.manual);
    bench.controller.analysisSession.replaceData([
      AnalysisSeries(
        name: 'signal',
        color: Colors.orange,
        points: const [AnalysisPoint(0, 1), AnalysisPoint(1, 2)],
      ),
    ], 'bottom test');
    await bench.mount();
    for (final panel in [
      WorkspacePanelId.analysis,
      WorkspacePanelId.plot,
      WorkspacePanelId.sourceDebug,
      WorkspacePanelId.symbols,
      WorkspacePanelId.watch,
      ...workspaceOutputPanels,
    ]) {
      await bench.workspace.activateWorkbenchView(panel);
      await tester.pumpAndSettle();
      if (bench.groupOf(panel) != 'output') {
        await bench.move(panel, '移至底部');
      }
      expect(bench.groupOf(panel), 'output');
      expect(tester.takeException(), isNull, reason: panel.name);
    }
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '$kind can create a bottom dock, merge tabs and drag them back',
      (tester) async {
        final bench = _Workbench(tester);
        addTearDown(bench.dispose);
        await bench.mount();
        final main = find.byKey(const ValueKey('workspace-group-plot'));
        final before = tester.getRect(main);
        var gesture = await bench.drag(
          WorkspacePanelId.analysis,
          const Offset(700, 892),
          kind: kind,
        );
        final preview = find.byKey(const ValueKey('dock-preview-bottom'));
        expect(find.byKey(const ValueKey('dock-drop-bottom')), findsOneWidget);
        expect(tester.widget<WorkspaceDockPreview>(preview).armed, isFalse);
        expect(tester.getRect(preview), const Rect.fromLTWH(0, 684, 1400, 216));
        expect(tester.getRect(main), before);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.moveBy(const Offset(2, 1));
        await tester.pump(const Duration(milliseconds: 110));
        expect(tester.widget<WorkspaceDockPreview>(preview).armed, isTrue);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(bench.frame('output').chrome!.tabs, [WorkspacePanelId.analysis]);
        expect(bench.frame('output').chrome!.tabsAtBottom, isTrue);
        expect(tester.getRect(main).height, lessThan(before.height));
        expect(preview, findsNothing);
        expect(tester.takeException(), isNull);

        gesture = await bench.drag(
          WorkspacePanelId.symbols,
          const Offset(700, 892),
          kind: kind,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(bench.frame('output').chrome!.tabs, [
          WorkspacePanelId.analysis,
          WorkspacePanelId.symbols,
        ]);
        expect(bench.frame('output').panel, WorkspacePanelId.symbols);
        expect(
          find.byKey(const ValueKey('workspace-group-resources')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        gesture = await bench.drag(
          WorkspacePanelId.analysis,
          tester.getCenter(main),
          kind: kind,
        );
        await tester.pump(const Duration(milliseconds: 320));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(bench.groupOf(WorkspacePanelId.analysis), 'plot');
        gesture = await bench.drag(
          WorkspacePanelId.symbols,
          const Offset(1392, 260),
          kind: kind,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(bench.groupOf(WorkspacePanelId.symbols), 'watch');
        expect(
          find.byKey(const ValueKey('workspace-group-output')),
          findsNothing,
        );
        expect(tester.getRect(main).height, before.height);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'bottom drop cancels and corners consistently prefer the bottom',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      var gesture = await bench.drag(
        WorkspacePanelId.analysis,
        const Offset(8, 892),
      );
      expect(find.byKey(const ValueKey('dock-preview-bottom')), findsOneWidget);
      expect(find.byKey(const ValueKey('dock-preview-left')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.analysis), 'plot');
      expect(find.byType(WorkspaceDockPreview), findsNothing);
      expect(
        find.byKey(const ValueKey('workspace-group-output')),
        findsNothing,
      );

      gesture = await bench.drag(
        WorkspacePanelId.analysis,
        const Offset(1392, 892),
      );
      expect(find.byKey(const ValueKey('dock-preview-bottom')), findsOneWidget);
      expect(find.byKey(const ValueKey('dock-preview-right')), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.analysis), 'output');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bottom tabs keep reordering and save arbitrary docked panels', (
    tester,
  ) async {
    final bench = _Workbench(tester);
    addTearDown(bench.dispose);
    await bench.mount();
    await bench.workspace.toggleWorkbenchOutput();
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('panel-tab-log'));
    final last = tester.getRect(
      find.byKey(const ValueKey('panel-tab-registers')),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(tab),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -35));
    await tester.pump();
    await gesture.moveTo(Offset(last.right - 1, last.center.dy));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('dock-drop-bottom')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(bench.frame('output').chrome!.tabs, [
      WorkspacePanelId.buildOutput,
      WorkspacePanelId.registers,
      WorkspacePanelId.log,
    ]);
    await bench.move(WorkspacePanelId.analysis, '移至底部');
    expect(bench.groupOf(WorkspacePanelId.analysis), 'output');
    await tester.runAsync(bench.workspace.saveLayout);
    await bench.move(WorkspacePanelId.analysis, '移回工作区');
    expect(bench.groupOf(WorkspacePanelId.analysis), 'plot');
    await tester.runAsync(bench.workspace.restoreLayout);
    await tester.pumpAndSettle();
    expect(bench.frame('output').chrome!.tabs, [
      WorkspacePanelId.buildOutput,
      WorkspacePanelId.registers,
      WorkspacePanelId.log,
      WorkspacePanelId.analysis,
    ]);
    expect(bench.frame('output').panel, WorkspacePanelId.analysis);
    expect(bench.frame('output').chrome!.tabsAtBottom, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'populated workbench pages fit when docked into a narrow sidebar',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      bench.controller.loadDemoSymbols();
      bench.controller.selectSymbols([demoSymbols.first.key]);
      bench.controller.addSelectedToWatch(mode: WatchReadMode.manual);
      bench.controller.analysisSession.replaceData([
        AnalysisSeries(
          name: 'velocity',
          color: Colors.orange,
          points: const [
            AnalysisPoint(0, 1),
            AnalysisPoint(1, 3),
            AnalysisPoint(2, 2),
          ],
        ),
      ], 'sidebar test');
      await bench.mount();
      for (final panel in [
        WorkspacePanelId.analysis,
        WorkspacePanelId.plot,
        WorkspacePanelId.watch,
        WorkspacePanelId.sourceDebug,
        WorkspacePanelId.log,
        WorkspacePanelId.buildOutput,
        WorkspacePanelId.registers,
      ]) {
        await bench.move(panel, '移至左侧栏');
        expect(bench.groupOf(panel), 'resources');
        expect(tester.takeException(), isNull, reason: panel.name);
      }
      await bench.move(WorkspacePanelId.watch, '移回工作区');
      expect(find.byKey(const ValueKey('watch-open-full-table')), findsNothing);
      expect(find.text('绘制颜色'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'version two side groups migrate and the original layout is backed up',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      final repository = WorkspaceLayoutRepository(bench.file);
      await tester.runAsync(
        () => repository.save(
          WorkspaceLayoutSnapshot(
            version: 2,
            uiScale: 1,
            groups: [
              WorkspaceGroup(
                id: 'resources',
                panels: [WorkspacePanelId.symbols],
                activePanel: WorkspacePanelId.symbols,
                rect: const Rect.fromLTWH(0, 0, .2, 1),
                z: 1,
              ),
              WorkspaceGroup(
                id: 'plot',
                panels: [WorkspacePanelId.plot, WorkspacePanelId.sourceDebug],
                activePanel: WorkspacePanelId.sourceDebug,
                rect: const Rect.fromLTWH(.2, 0, .5, 1),
                z: 2,
              ),
              WorkspaceGroup(
                id: 'watch',
                panels: [WorkspacePanelId.watch],
                activePanel: WorkspacePanelId.watch,
                rect: const Rect.fromLTWH(.7, 0, .3, 1),
                z: 3,
              ),
            ],
          ),
        ),
      );
      await bench.mount();
      await tester.runAsync(bench.workspace.restoreLayout);
      await tester.pumpAndSettle();
      expect(
        bench.frame('resources').chrome!.sidebar,
        WorkspaceSidebarSide.left,
      );
      expect(bench.frame('watch').chrome!.sidebar, WorkspaceSidebarSide.right);
      expect(bench.frame('plot').panel, WorkspacePanelId.sourceDebug);
      await tester.runAsync(bench.workspace.saveLayout);
      expect(File('${bench.file.path}.v2.bak').existsSync(), isTrue);
      final previous = await tester.runAsync(
        () =>
            WorkspaceLayoutRepository(File('${bench.file.path}.v2.bak')).load(),
      );
      expect(previous!.version, 2);
      expect(previous.groups.every((g) => g.sidebar == null), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sidebars collapse into handles without reserving a rail', (
    tester,
  ) async {
    final bench = _Workbench(tester);
    addTearDown(bench.dispose);
    bench.controller.loadDemoSymbols();
    bench.controller.selectSymbols([demoSymbols.first.key]);
    bench.controller.addSelectedToWatch(mode: WatchReadMode.monitor);
    bench.controller.applySnapshot({
      'connectionStatus': 'connected',
      'samplingPaused': true,
    });
    await bench.mount();
    expect(bench.frame('resources').chrome!.sidebar, WorkspaceSidebarSide.left);
    expect(bench.frame('watch').chrome!.sidebar, WorkspaceSidebarSide.right);
    expect(
      find.byKey(const ValueKey('workbench-resource-toggle')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('watch-open-full-table')), findsNothing);
    final input = find.byKey(
      ValueKey(
        'compact-watch-input-${bench.controller.watches.single.symbol.key}',
      ),
    );
    await tester.enterText(input, '123.75');
    final main = find.byKey(const ValueKey('workspace-group-plot'));
    final left = find.byKey(const ValueKey('workspace-group-resources'));
    final right = find.byKey(const ValueKey('workspace-group-watch'));
    final leftHandle = find.byKey(const ValueKey('sidebar-handle-left'));
    final rightHandle = find.byKey(const ValueKey('sidebar-handle-right'));
    final width = tester.getSize(main).width;
    expect(
      tester.getTopLeft(leftHandle).dx,
      closeTo(tester.getTopRight(left).dx, 2),
    );
    expect(
      tester.getTopRight(rightHandle).dx,
      closeTo(tester.getTopLeft(right).dx, 2),
    );
    await tester.tap(find.byKey(const ValueKey('panel-tab-symbols')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-tab-watch')));
    await tester.pumpAndSettle();
    expect(tester.getSize(main).width, width);
    expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isTrue);
    expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
    expect(find.byType(WorkspaceSidebarHandle), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('sidebar-handle-left')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(main).width, greaterThan(width));
    expect(
      tester.getTopLeft(leftHandle).dx,
      closeTo(tester.getTopRight(left).dx, 2),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-handle-left')), findsOneWidget);
    expect(tester.getTopLeft(leftHandle).dx, 0);
    expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isFalse);
    await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
    await tester.pumpAndSettle();
    expect(tester.getSize(main).width, closeTo(1397, .1));
    expect(find.byKey(const ValueKey('sidebar-handle-right')), findsOneWidget);
    expect(tester.getTopRight(rightHandle).dx, 1400);
    expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isFalse);
    await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getTopRight(rightHandle).dx,
      closeTo(tester.getTopLeft(right).dx, 2),
    );
    await tester.pumpAndSettle();
    expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
    expect(tester.widget<TextField>(input).controller!.text, '123.75');
    expect(tester.takeException(), isNull);
    await bench.dispose();
  });

  testWidgets(
    'edge preview survives movement then docks and can return to center',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      final before = tester.getRect(
        find.byKey(const ValueKey('workspace-group-plot')),
      );
      final gesture = await bench.drag(
        WorkspacePanelId.analysis,
        const Offset(8, 240),
      );
      final preview = find.byKey(const ValueKey('dock-preview-left'));
      expect(tester.widget<WorkspaceDockPreview>(preview).armed, isFalse);
      expect(
        bench.frame('plot').chrome!.tabs,
        contains(WorkspacePanelId.analysis),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('workspace-group-plot'))),
        before,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(2, 10));
      await tester.pump(const Duration(milliseconds: 110));
      expect(tester.widget<WorkspaceDockPreview>(preview).armed, isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.analysis), 'resources');
      expect(
        bench.frame('resources').chrome!.activePanel,
        WorkspacePanelId.analysis,
      );
      expect(
        bench.frame('plot').chrome!.tabs,
        isNot(contains(WorkspacePanelId.analysis)),
      );
      expect(preview, findsNothing);

      final center = tester.getCenter(
        find.byKey(const ValueKey('workspace-group-plot')),
      );
      final returnGesture = await bench.drag(WorkspacePanelId.analysis, center);
      await tester.pump(const Duration(milliseconds: 320));
      await returnGesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.analysis), 'plot');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging between sidebars and cancelling preserves unique ownership',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      var gesture = await bench.drag(
        WorkspacePanelId.symbols,
        const Offset(1392, 260),
      );
      expect(
        tester
            .widget<WorkspaceDockPreview>(find.byType(WorkspaceDockPreview))
            .edge,
        WorkspaceDockEdge.right,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.symbols), 'watch');
      expect(
        find.byKey(const ValueKey('workspace-group-resources')),
        findsNothing,
      );
      expect(bench.frame('watch').chrome!.tabs, [
        WorkspacePanelId.watch,
        WorkspacePanelId.symbols,
      ]);

      gesture = await bench.drag(
        WorkspacePanelId.sourceDebug,
        const Offset(8, 260),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bench.groupOf(WorkspacePanelId.sourceDebug), 'plot');
      expect(find.byType(WorkspaceDockPreview), findsNothing);
      expect(
        tester
            .widgetList<TalPanelFrame>(find.byType(TalPanelFrame))
            .expand((frame) => frame.chrome!.tabs)
            .toSet()
            .length,
        5,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source body survives tab changes and docking but hidden views are not visible',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      await bench.workspace.activateWorkbenchView(WorkspacePanelId.sourceDebug);
      await tester.pumpAndSettle();
      final source = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_SourceDebugPanel',
        skipOffstage: false,
      );
      final state = tester.state(source);
      expect(bench.controller.isSourceDebugVisible, isTrue);
      await bench.workspace.activateWorkbenchView(WorkspacePanelId.plot);
      await tester.pumpAndSettle();
      expect(tester.state(source), same(state));
      expect(bench.controller.isSourceDebugVisible, isFalse);
      await bench.move(WorkspacePanelId.sourceDebug, '移至右侧栏');
      expect(tester.state(source), same(state));
      expect(bench.controller.isSourceDebugVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pumpAndSettle();
      expect(bench.controller.isSourceDebugVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
      await tester.pumpAndSettle();
      expect(bench.controller.isSourceDebugVisible, isFalse);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
      await tester.pumpAndSettle();
      expect(tester.state(source), same(state));
      expect(bench.controller.isSourceDebugVisible, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved sidebars retain order widths selection and collapsed state',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount();
      await bench.move(WorkspacePanelId.analysis, '移至左侧栏');
      final handle = find.byKey(const ValueKey('sidebar-handle-left'));
      final beforeResize = tester.getTopLeft(handle).dx;
      final resizeGesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await resizeGesture.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(tester.getTopLeft(handle).dx, greaterThan(beforeResize));
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isTrue);
      expect(
        tester.getTopLeft(handle).dx,
        closeTo(
          tester
              .getTopRight(
                find.byKey(const ValueKey('workspace-group-resources')),
              )
              .dx,
          2,
        ),
      );
      await resizeGesture.up();
      await tester.pumpAndSettle();
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isTrue);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-left')));
      await tester.pumpAndSettle();
      await tester.runAsync(bench.workspace.saveLayout);
      final saved = await tester.runAsync(
        () => WorkspaceLayoutRepository(bench.file).load(),
      );
      final left = saved!.groups.singleWhere(
        (g) => g.sidebar == WorkspaceSidebarSide.left,
      );
      expect(saved.version, 4);
      expect(left.panels, [
        WorkspacePanelId.symbols,
        WorkspacePanelId.analysis,
      ]);
      expect(left.activePanel, WorkspacePanelId.analysis);
      expect(left.sidebarWidth, greaterThan(280));
      expect(left.sidebarCollapsed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await bench.mount();
      await tester.runAsync(bench.workspace.restoreLayout);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar-handle-left')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-left')));
      await tester.pumpAndSettle();
      expect(bench.frame('resources').panel, WorkspacePanelId.analysis);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('workspace-group-resources')))
            .width,
        closeTo(left.sidebarWidth - 3, .1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow workspace uses one overlay and no reserved sidebar width',
    (tester) async {
      final bench = _Workbench(tester);
      addTearDown(bench.dispose);
      await bench.mount(width: 760);
      final main = find.byKey(const ValueKey('workspace-group-plot'));
      expect(tester.getSize(main).width, closeTo(757, .1));
      expect(find.byType(WorkspaceSidebarHandle), findsNWidgets(2));
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isFalse);
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isFalse);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-left')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar-handle-left')), findsOneWidget);
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isTrue);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('sidebar-handle-left'))).dx,
        closeTo(
          tester
              .getTopRight(
                find.byKey(const ValueKey('workspace-group-resources')),
              )
              .dx,
          2,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('panel-tab-symbols')));
      await tester.pumpAndSettle();
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isTrue);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar-handle-left')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sidebar-handle-right')),
        findsOneWidget,
      );
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.left), isFalse);
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
      final right = find.byKey(const ValueKey('workspace-group-watch'));
      final rightHandle = find.byKey(const ValueKey('sidebar-handle-right'));
      final initialWidth = tester.getSize(right).width;
      await tester.drag(rightHandle, const Offset(60, 0));
      await tester.pumpAndSettle();
      final smallerWidth = tester.getSize(right).width;
      expect(smallerWidth, lessThan(initialWidth));
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
      await tester.drag(rightHandle, const Offset(-80, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(right).width, greaterThan(smallerWidth));
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
      expect(
        tester
            .getTopRight(find.byKey(const ValueKey('sidebar-handle-right')))
            .dx,
        closeTo(
          tester
              .getTopLeft(find.byKey(const ValueKey('workspace-group-watch')))
              .dx,
          2,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('panel-tab-watch')));
      await tester.pumpAndSettle();
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isTrue);
      await tester.tap(find.byKey(const ValueKey('sidebar-handle-right')));
      await tester.pumpAndSettle();
      expect(bench.sidebarExpanded(WorkspaceSidebarSide.right), isFalse);
      expect(tester.getSize(main).width, closeTo(757, .1));
      expect(tester.takeException(), isNull);
    },
  );
}
