import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';

void main() {
  testWidgets('double clicking a source file shows and reselects its tab', (
    tester,
  ) async {
    final fixture = await _sourceFixture(tester);
    final controller = fixture.controller;
    controller.openSourceFile(fixture.main);
    await tester.pumpWidget(_Harness(controller: controller));
    final file = find.descendant(
      of: find.byKey(const ValueKey('symbol-tree-row-source/control.c')),
      matching: find.text('control.c'),
    );

    await tester.tap(file);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(file);
    await _waitForSource(tester, fixture.control);
    expect(controller.sourceWorkspace.selectedPath, fixture.control);
    expect(controller.sourceWorkspace.openPaths, [
      fixture.main,
      fixture.control,
    ]);
    expect(controller.sourceWorkspace.unreadPaths, isEmpty);
    expect(controller.selectedSymbols, isEmpty);
    expect(controller.watches, isEmpty);

    controller.openSourceFile(fixture.main);
    await _waitForSource(tester, fixture.main);
    await tester.tap(file);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(file);
    await _waitForSource(tester, fixture.control);
    expect(controller.sourceWorkspace.openPaths, [
      fixture.main,
      fixture.control,
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final useSourceRoot in [false, true]) {
    testWidgets(
      'dragging a symbol file opens source using ${useSourceRoot ? 'the source root' : 'its debug path'}',
      (tester) async {
        final fixture = await _sourceFixture(tester);
        final controller = fixture.controller;
        final expectedPath = useSourceRoot ? 'control.c' : fixture.control;
        if (useSourceRoot) {
          controller.applyDebugState({
            'executionState': 'running',
            'sourceFiles': <String>[],
            'sourceRoot': File(fixture.control).parent.path,
          });
        }
        controller.openSourceFile(fixture.main);
        await tester.pumpWidget(
          _Harness(
            controller: controller,
            initialPanel: WorkspacePanelId.sourceDebug,
          ),
        );
        await _waitForSource(tester, fixture.main);
        for (var attempt = 0; attempt < 2; attempt++) {
          final drag = await tester.startGesture(
            tester.getCenter(
              find.descendant(
                of: find.byKey(
                  const ValueKey('symbol-tree-row-source/control.c'),
                ),
                matching: find.text('control.c'),
              ),
            ),
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveBy(const Offset(-25, 0));
          await tester.pump();
          await drag.moveTo(
            tester.getCenter(
              find.byKey(const ValueKey('source-symbol-drop-target')),
            ),
          );
          await tester.pump();
          expect(
            find.byKey(const ValueKey('source-file-drop-overlay')),
            findsOneWidget,
          );
          await drag.up();
          await _waitForSource(tester, expectedPath);
          expect(controller.sourceWorkspace.selectedPath, expectedPath);
          expect(controller.sourceWorkspace.openPaths, [
            fixture.main,
            expectedPath,
          ]);
          expect(
            find.byKey(const ValueKey('source-file-drop-overlay')),
            findsNothing,
          );
        }
        expect(controller.selectedSymbols, isEmpty);
        expect(controller.watches, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('cancelling a symbol file drag clears the drop highlight', (
    tester,
  ) async {
    final fixture = await _sourceFixture(tester);
    final controller = fixture.controller;
    await tester.pumpWidget(
      _Harness(
        controller: controller,
        initialPanel: WorkspacePanelId.sourceDebug,
      ),
    );
    final drag = await tester.startGesture(
      tester.getCenter(find.text('control.c')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(-25, 0));
    await tester.pump();
    await drag.moveTo(
      tester.getCenter(find.byKey(const ValueKey('source-symbol-drop-target'))),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-file-drop-overlay')),
      findsOneWidget,
    );
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('source-file-drop-overlay')),
      findsNothing,
    );
    expect(controller.sourceWorkspace.openPaths, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'source additions are idempotent, alias aware, and separate from stops',
    () {
      final controller = TakeALookController();
      addTearDown(controller.dispose);
      controller.applyDebugState({
        'executionState': 'halted',
        'sourceFiles': ['C:/firmware/main.c', 'C:/firmware/control.c'],
        'stoppedLocation': {
          'path': 'C:/firmware/main.c',
          'line': 10,
          'address': 0x08000100,
        },
      });
      controller.openSourceFile('C:/firmware/main.c');
      controller.addSourceFileFromSymbols('control.c');
      final state = controller.sourceWorkspace;
      expect(state.selectedPath, 'C:/firmware/main.c');
      expect(state.unreadPaths, {'C:/firmware/control.c'});
      expect(state.attentionUntilMs - state.attentionStartedAtMs, 4200);
      final before = state.toJson();
      controller.addSourceFileFromSymbols(r'C:\firmware\CONTROL.c');
      expect(state.toJson(), before);
      expect(controller.debugState.currentSource, 'C:/firmware/main.c');
      expect(controller.debugState.programCounter, 0x08000100);

      controller.openSourceFile('control.c');
      expect(state.unreadPaths, isNotEmpty);
      controller.markSourceFileRead('control.c');
      expect(state.unreadPaths, isEmpty);
      expect(state.attentionUntilMs, 0);
      controller.closeSourceFile('control.c');
      expect(controller.isSourceFileOpen('control.c'), isFalse);
      controller.addSourceFileFromSymbols('control.c');
      expect(state.additionRevision, 2);
      expect(state.unreadPaths, isNotEmpty);
    },
  );

  test('visible source view selects additions without attention', () {
    final controller = TakeALookController();
    addTearDown(controller.dispose);
    controller.setSourceViewVisible('window:child:view', true);
    controller.addSourceFileFromSymbols('control.c');
    expect(controller.sourceWorkspace.selectedPath, 'control.c');
    expect(controller.sourceWorkspace.unreadPaths, isEmpty);
    expect(controller.sourceWorkspace.attentionUntilMs, 0);
    controller.removeSourceViewsForWindow('child');
    controller.addSourceFileFromSymbols('other.c');
    expect(controller.sourceWorkspace.selectedPath, 'control.c');
    expect(controller.sourceWorkspace.unreadPaths, {'other.c'});
  });

  test(
    'same basenames remain distinct and backend patches preserve source UI',
    () {
      final controller = TakeALookController();
      final mirror = TakeALookController();
      addTearDown(controller.dispose);
      addTearDown(mirror.dispose);
      controller.applyDebugState({
        'sourceFiles': ['C:/first/shared.c', 'C:/second/shared.c'],
      });
      controller.addSourceFileFromSymbols('C:/first/shared.c');
      controller.addSourceFileFromSymbols('C:/second/shared.c');
      expect(controller.sourceWorkspace.openPaths, hasLength(2));
      expect(controller.isSourceFileOpen('shared.c'), isFalse);
      mirror.applySnapshot(controller.stateSnapshot());
      expect(
        mirror.sourceWorkspace.toJson(),
        controller.sourceWorkspace.toJson(),
      );
      final before = mirror.sourceWorkspace.toJson();
      mirror.applySnapshot({
        'debug': {'executionState': 'running'},
      });
      expect(mirror.sourceWorkspace.toJson(), before);
      expect(mirror.isSourceDebugVisible, isFalse);
    },
  );

  test(
    'detached source commands synchronize additions, read state and closure',
    () async {
      final owner = TakeALookController(
        backendCommand: (_, _) async {
          fail('Source UI commands must not go to the hardware backend.');
        },
      );
      late TakeALookController remote;
      remote = TakeALookController(
        remoteCommand: (command, args) async {
          remote.applySnapshot(
            Map<String, dynamic>.from(await owner.handleCommand(command, args)),
          );
        },
      );
      addTearDown(owner.dispose);
      addTearDown(remote.dispose);
      remote.addSourceFileFromSymbols('control.c');
      await Future<void>.delayed(Duration.zero);
      expect(remote.sourceWorkspace.unreadPaths, {'control.c'});
      remote.openSourceFile('control.c');
      remote.markSourceFileRead('control.c');
      await Future<void>.delayed(Duration.zero);
      expect(owner.sourceWorkspace.selectedPath, 'control.c');
      expect(owner.sourceWorkspace.unreadPaths, isEmpty);
      remote.closeSourceFile('control.c');
      await Future<void>.delayed(Duration.zero);
      expect(owner.sourceWorkspace.openPaths, isEmpty);
      expect(remote.sourceWorkspace.openPaths, isEmpty);
      expect(
        BackendCommandMapper.translate(
          ControllerCommand.addSourceFile,
          'control.c',
          {},
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'file menu adds in background, breathes, and only viewed files become read',
    (tester) async {
      final fixture = await _sourceFixture(tester);
      final controller = fixture.controller;
      controller.openSourceFile(fixture.main);
      await tester.pumpWidget(_Harness(controller: controller));
      final tabKey = find.byKey(const ValueKey('panel-tab-sourceDebug'));
      final originalTabSize = tester.getSize(tabKey);
      final label = find.descendant(of: tabKey, matching: find.text('源码调试'));
      final originalLabelRect = tester.getRect(label);

      await _fileMenu(tester);
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('gain'), findsOneWidget);
      await _fileMenu(tester);
      expect(find.text('收起'), findsOneWidget);
      await tester.tap(find.text('添加到源码调试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550));
      expect(controller.sourceWorkspace.selectedPath, fixture.main);
      expect(controller.isSourceFileUnread(fixture.control), isTrue);
      expect(find.byKey(const ValueKey('source-panel-unread')), findsOneWidget);
      final surface = tester
          .widgetList<TalPanelTabSurface>(find.byType(TalPanelTabSurface))
          .singleWhere(
            (surface) => surface.tab == WorkspacePanelId.sourceDebug,
          );
      expect(surface.attention, greaterThan(0.5));
      expect(tester.getSize(tabKey), originalTabSize);
      expect(tester.getRect(label), originalLabelRect);
      await tester.pump(const Duration(seconds: 6));
      final settledSurface = tester
          .widgetList<TalPanelTabSurface>(find.byType(TalPanelTabSurface))
          .singleWhere(
            (surface) => surface.tab == WorkspacePanelId.sourceDebug,
          );
      expect(settledSurface.attention, 0);
      expect(find.byKey(const ValueKey('source-panel-unread')), findsOneWidget);

      await _fileMenu(tester);
      final addedItem = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('已添加到源码调试'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(addedItem.enabled, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(tabKey);
      await _waitForSource(tester, fixture.main);
      expect(
        find.byKey(ValueKey('source-file-unread-${fixture.control}')),
        findsOneWidget,
      );
      expect(controller.sourceWorkspace.unreadPaths, {fixture.control});
      await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
      await tester.pump();
      await tester.tap(tabKey);
      await _waitForSource(tester, fixture.main);
      expect(controller.sourceWorkspace.openPaths, [
        fixture.main,
        fixture.control,
      ]);
      expect(controller.isSourceFileUnread(fixture.control), isTrue);
      await tester.tap(find.byKey(ValueKey('source-tab-${fixture.control}')));
      await _waitForSource(tester, fixture.control);
      expect(controller.sourceWorkspace.unreadPaths, isEmpty);
      expect(find.byKey(const ValueKey('source-panel-unread')), findsNothing);
      expect(tester.getSize(tabKey), originalTabSize);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'adding while source is visible opens it directly; closing allows adding again',
    (tester) async {
      final fixture = await _sourceFixture(tester);
      final controller = fixture.controller;
      controller.openSourceFile(fixture.main);
      await tester.pumpWidget(
        _Harness(
          controller: controller,
          initialPanel: WorkspacePanelId.sourceDebug,
        ),
      );
      await _waitForSource(tester, fixture.main);
      expect(controller.isSourceDebugVisible, isTrue);
      await _fileMenu(tester);
      await tester.tap(find.text('添加到源码调试'));
      await _waitForSource(tester, fixture.control);
      expect(controller.sourceWorkspace.selectedPath, fixture.control);
      expect(controller.sourceWorkspace.unreadPaths, isEmpty);
      expect(controller.sourceWorkspace.attentionUntilMs, 0);
      await tester.tap(
        find.byKey(ValueKey('source-tab-close-${fixture.control}')),
      );
      await _waitForSource(tester, fixture.main);
      expect(controller.isSourceFileOpen(fixture.control), isFalse);
      await _fileMenu(tester);
      expect(find.text('添加到源码调试'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(controller.isSourceDebugVisible, isFalse);
    },
  );

  testWidgets(
    'saved file choice yields to a new stop while the source panel is hidden',
    (tester) async {
      final fixture = await _sourceFixture(tester);
      final controller = fixture.controller;
      final halted = {
        'executionState': 'halted',
        'stoppedLocation': {
          'path': fixture.main,
          'line': 1,
          'address': 0x08000100,
        },
      };
      controller.applyDebugState(halted);
      await tester.pumpWidget(
        _Harness(
          controller: controller,
          initialPanel: WorkspacePanelId.sourceDebug,
        ),
      );
      await _waitForSource(tester, fixture.main);
      controller.openSourceFile(fixture.control);
      await _waitForSource(tester, fixture.control);
      await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await _waitForSource(tester, fixture.control);
      await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
      await tester.pump();
      controller.applyDebugState({'executionState': 'running'});
      controller.applyDebugState(halted);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await _waitForSource(tester, fixture.main);
      expect(controller.sourceWorkspace.openPaths, [
        fixture.main,
        fixture.control,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reduced motion uses a finite static highlight', (tester) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _Harness(controller: controller, reduceMotion: true),
    );
    controller.addSourceFileFromSymbols('control.c');
    await tester.pump();
    TalPanelTabSurface sourceTab() => tester
        .widgetList<TalPanelTabSurface>(find.byType(TalPanelTabSurface))
        .singleWhere((item) => item.tab == WorkspacePanelId.sourceDebug);
    expect(sourceTab().attention, 0.7);
    await tester.pump(const Duration(milliseconds: 300));
    expect(sourceTab().attention, 0.7);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(sourceTab().attention, 0);
    expect(sourceTab().unread, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('adding restores a hidden source tab without leaving the plot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TakeALookController(backendCommand: (_, _) async {});
    final sync = MainWindowSync(controller);
    final key = GlobalKey<DockingWorkspaceState>();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: key,
            controller: controller,
            windowSync: sync,
          ),
        ),
      ),
    );
    await key.currentState!.togglePanelVisibility(WorkspacePanelId.sourceDebug);
    await tester.pump();
    expect(find.byKey(const ValueKey('panel-tab-sourceDebug')), findsNothing);
    controller.addSourceFileFromSymbols('control.c');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('panel-tab-sourceDebug')), findsOneWidget);
    expect(controller.isSourceDebugVisible, isFalse);
    expect(controller.isSourceFileUnread('control.c'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await sync.dispose();
  });

  testWidgets('a drag preview cannot read files or consume attention', (
    tester,
  ) async {
    final fixture = await _sourceFixture(tester);
    fixture.controller.addSourceFileFromSymbols('control.c');
    final before = fixture.controller.sourceWorkspace.toJson();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: buildWorkspacePanelBody(
            WorkspacePanelId.sourceDebug,
            fixture.controller,
            sourcePreview: true,
          ),
        ),
      ),
    );
    await _waitForSource(tester, fixture.control);
    expect(fixture.controller.isSourceDebugVisible, isFalse);
    expect(fixture.controller.sourceWorkspace.toJson(), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a pooled hidden window only reads source after assignment', (
    tester,
  ) async {
    final fixture = await _sourceFixture(tester);
    final controller = fixture.controller;
    controller.addSourceFileFromSymbols('control.c');
    final before = controller.sourceWorkspace.toJson();
    var assigned = false;
    late StateSetter changeAssignment;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: StatefulBuilder(
          builder: (context, setState) {
            changeAssignment = setState;
            return DetachedPanelWindow(
              controller: controller,
              panel: WorkspacePanelId.sourceDebug,
              assigned: assigned,
            );
          },
        ),
      ),
    );
    await _waitForSource(tester, fixture.control);
    expect(controller.isSourceDebugVisible, isFalse);
    expect(controller.sourceWorkspace.toJson(), before);
    changeAssignment(() => assigned = true);
    await tester.pump();
    await _waitForSource(tester, fixture.control);
    expect(controller.isSourceDebugVisible, isTrue);
    expect(controller.sourceWorkspace.unreadPaths, isEmpty);
    changeAssignment(() => assigned = false);
    await tester.pump();
    expect(controller.isSourceDebugVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed source read keeps its unread marker', (tester) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    const missing = 'test/fixtures/missing_source_for_unread.c';
    controller.addSourceFileFromSymbols(missing);
    await tester.pumpWidget(
      _Harness(
        controller: controller,
        initialPanel: WorkspacePanelId.sourceDebug,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.sourceWorkspace.selectedPath, missing);
    expect(controller.isSourceFileUnread(missing), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<({TakeALookController controller, String main, String control})>
_sourceFixture(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late Directory directory;
  late File main;
  late File control;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('tal-source-unread-');
    main = File.fromUri(directory.uri.resolve('main.c'));
    control = File.fromUri(directory.uri.resolve('control.c'));
    await main.writeAsString('int main(void) { return 0; }\n');
    await control.writeAsString('float gain = 1.0f;\n');
  });
  final controller = TakeALookController(
    backendCommand: (_, _) async {
      fail('Opening source must not control the target.');
    },
  );
  controller.applySnapshot({
    'symbols': [
      {
        'source': 'control.c',
        'name': 'gain',
        'key': 'gain',
        'address': 0x20000000,
        'type': 'float',
        'size': 4,
        'section': '.data',
      },
    ],
    'debug': {
      'executionState': 'running',
      'sourceFiles': [main.path, control.path],
    },
  });
  addTearDown(controller.dispose);
  addTearDown(() => directory.delete(recursive: true));
  return (controller: controller, main: main.path, control: control.path);
}

Future<void> _fileMenu(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('symbol-tree-row-source/control.c')),
      matching: find.text('control.c'),
    ),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

Future<void> _waitForSource(WidgetTester tester, String path) async {
  for (var attempt = 0; attempt < 15; attempt++) {
    await tester.pump();
    if (find.byKey(ValueKey('source-view-$path')).evaluate().isNotEmpty) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump(const Duration(milliseconds: 250));
  expect(find.byKey(ValueKey('source-view-$path')), findsOneWidget);
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.controller,
    this.initialPanel = WorkspacePanelId.plot,
    this.reduceMotion = false,
  });
  final TakeALookController controller;
  final WorkspacePanelId initialPanel;
  final bool reduceMotion;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late WorkspacePanelId active = widget.initialPanel;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildTalTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reduceMotion),
      child: Scaffold(
        body: Row(
          children: [
            Expanded(
              flex: 3,
              child: buildWorkspacePanel(
                active,
                widget.controller,
                chrome: PanelChrome(
                  tabs: const [
                    WorkspacePanelId.plot,
                    WorkspacePanelId.sourceDebug,
                  ],
                  activePanel: active,
                  highlighted: false,
                  onSelect: (panel) => setState(() => active = panel),
                  onFloat: () {},
                  onClose: () {},
                  onSeparate: () {},
                  onDragStart: (_) {},
                  onDragUpdate: (_) {},
                  onDragEnd: (_) {},
                  showActions: false,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: buildWorkspacePanel(
                WorkspacePanelId.symbols,
                widget.controller,
                onShowSource: () =>
                    setState(() => active = WorkspacePanelId.sourceDebug),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
