import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/panels/watch_panel.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';

typedef Commands = List<(ControllerCommand, Object?)>;

TakeALookController fixture(Commands commands) {
  final controller = TakeALookController(
    backendCommand: (command, arguments) async {
      commands.add((command, arguments));
    },
  );
  final symbols = [
    ('motor', 'struct Motor'),
    ('motor.speed', 'float'),
    ('motor.loop', 'struct Loop'),
    ('motor.loop.gain', 'float'),
    ('motor.samples', 'float[2]'),
    ('motor.samples[0]', 'float'),
    ('motor.samples[1]', 'float'),
    ('capture', 'float'),
    ('manual', 'float'),
  ];
  controller.applySnapshot({
    'symbols': [
      for (final (index, definition) in symbols.indexed)
        {
          'key': definition.$1,
          'name': definition.$1,
          'source': 'motor.c',
          'address': 0x20000000 + index * 4,
          'size': 4,
          'type': definition.$2,
        },
    ],
  });
  controller.selectSymbols(['motor', 'capture', 'manual']);
  controller.addSelectedToWatch(mode: WatchReadMode.monitor);
  controller.setWatchReadMode('capture', WatchReadMode.capture);
  controller.setWatchReadMode('manual', WatchReadMode.manual);
  commands.clear();
  return controller;
}

WatchItem watch(TakeALookController controller, String key) =>
    controller.watches.firstWhere((w) => w.symbol.key == key);

Set<String> enabled(Commands commands) => Set<String>.from(
  (commands.lastWhere((c) => c.$1 == ControllerCommand.setMonitorVisibility).$2
          as Map)['enabledKeys']
      as List,
);

Future<void> mount(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1200, 850));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  test(
    'a workspace with no watch view pauses unpinned memory monitors',
    () async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      controller.initializeWatchMonitorVisibility();
      await Future<void>.delayed(Duration.zero);
      expect(enabled(commands), isEmpty);
      expect(
        controller.isWatchMonitorActive(watch(controller, 'motor.speed')),
        isFalse,
      );
    },
  );

  test(
    'visibility changes coalesce, empty views stop polling, and pinning overrides them',
    () async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      final speed = watch(controller, 'motor.speed');
      final gain = watch(controller, 'motor.loop.gain');
      expect(controller.isWatchMonitorActive(speed), isTrue);
      controller.initializeWatchMonitorVisibility();
      controller.setWatchMonitorScope('list', ['motor.speed']);
      controller.setWatchMonitorScope('details', ['motor.loop.gain']);
      await Future<void>.delayed(Duration.zero);
      expect(commands, hasLength(1));
      expect(enabled(commands), {'motor.speed', 'motor.loop.gain'});

      commands.clear();
      controller.setWatchMonitorScope('list', ['motor.speed']);
      await Future<void>.delayed(Duration.zero);
      expect(commands, isEmpty);
      controller.setWatchMonitorScope('list', null);
      controller.setWatchMonitorScope('details', null);
      await Future<void>.delayed(Duration.zero);
      expect(enabled(commands), isEmpty);
      expect(controller.isWatchMonitorActive(speed), isFalse);
      expect(controller.isWatchMonitorActive(gain), isFalse);

      controller.setWatchPinned('motor.speed', true);
      controller.setWatchPinned('manual', true);
      await Future<void>.delayed(Duration.zero);
      expect(enabled(commands), {'motor.speed'});
      controller.setWatchPinned('motor.speed', false);
      await Future<void>.delayed(Duration.zero);
      expect(enabled(commands), isEmpty);
      expect(watch(controller, 'capture').readMode, WatchReadMode.capture);
      expect(watch(controller, 'manual').readMode, WatchReadMode.manual);
      expect(
        commands.every((c) => c.$1 == ControllerCommand.setMonitorVisibility),
        isTrue,
      );
    },
  );

  test('closing a detached window removes only its monitor demand', () async {
    final commands = <(ControllerCommand, Object?)>[];
    final controller = fixture(commands);
    final sync = MainWindowSync(controller);
    addTearDown(() async {
      await sync.dispose();
      controller.dispose();
    });
    controller.setWatchMonitorScope('main', ['motor.speed']);
    sync.setWatchMonitorScopeForWindow('one', 'watch', ['motor.loop.gain']);
    sync.setWatchMonitorScopeForWindow('two', 'watch', ['motor.samples[0]']);
    sync.reportDetachedWindowReleased('one');
    await Future<void>.delayed(Duration.zero);
    expect(enabled(commands), {'motor.speed', 'motor.samples[0]'});
    sync.setWatchMonitorScopeForWindow('one', 'watch', ['motor.loop.gain']);
    expect(
      controller.isWatchMonitorActive(watch(controller, 'motor.loop.gain')),
      isFalse,
    );
    sync.reportDetachedWindowReleased('two');
    controller.setWatchMonitorScope('main', null);
    await Future<void>.delayed(Duration.zero);
    expect(enabled(commands), isEmpty);
  });

  test(
    'restoring a project preserves pins and applies hidden demand before its first read',
    () async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      controller.initializeWatchMonitorVisibility();
      controller.setWatchPinned('motor.loop.gain', true);
      final project = controller.projectSettings();
      expect(
        (project['watches'] as List).every(
          (w) => !(w as Map).containsKey('monitorEnabled'),
        ),
        isTrue,
      );
      await controller.restoreProjectSettings(project);
      await Future<void>.delayed(Duration.zero);
      expect(enabled(commands), {'motor.loop.gain'});
      final restored =
          (commands.lastWhere((c) => c.$1 == ControllerCommand.setWatches).$2
                  as Map)['watches']
              as List;
      expect(
        restored
            .where((w) => (w as Map)['monitorEnabled'] == true)
            .map((w) => (w as Map)['key']),
        ['motor.loop.gain'],
      );
      expect(watch(controller, 'motor.loop.gain').pinned, isTrue);
    },
  );

  testWidgets(
    'compact structure, array and panel folding update only monitor demand',
    (tester) async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var visible = true;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CompactWatchPanel(controller: controller, visible: visible);
          },
        ),
      );
      expect(enabled(commands), {'motor.speed'});
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor.loop')));
      await tester.pumpAndSettle();
      expect(enabled(commands), {'motor.speed', 'motor.loop.gain'});
      await tester.tap(
        find.byKey(const ValueKey('compact-watch-motor.samples')),
      );
      await tester.pumpAndSettle();
      expect(enabled(commands), {
        'motor.speed',
        'motor.loop.gain',
        'motor.samples[0]',
        'motor.samples[1]',
      });
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
      await tester.pumpAndSettle();
      expect(enabled(commands), isEmpty);

      controller.setWatchPinned('motor.loop.gain', true);
      update(() => visible = false);
      await tester.pumpAndSettle();
      expect(enabled(commands), {'motor.loop.gain'});
      controller.setWatchPinned('motor.loop.gain', false);
      await tester.pumpAndSettle();
      expect(enabled(commands), isEmpty);
      expect(watch(controller, 'capture').samplingEnabled, isTrue);
      expect(
        commands.every((c) => c.$1 == ControllerCommand.setMonitorVisibility),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('table folding and whole frame collapse release monitor demand', (
    tester,
  ) async {
    final commands = <(ControllerCommand, Object?)>[];
    final controller = fixture(commands);
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(
      tester,
      buildWorkspacePanel(WorkspacePanelId.watch, controller),
    );
    expect(enabled(commands), isEmpty);
    final motor = find.byKey(const ValueKey<String>('motor'));
    await tester.tap(
      find.descendant(of: motor, matching: find.byTooltip('展开')).first,
    );
    await tester.pumpAndSettle();
    expect(enabled(commands), {'motor.speed'});
    controller.setWatchPinned('motor.loop.gain', true);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
    await tester.pumpAndSettle();
    expect(enabled(commands), {'motor.loop.gain'});
    controller.setWatchPinned('motor.loop.gain', false);
    await tester.pumpAndSettle();
    expect(enabled(commands), isEmpty);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_right).first);
    await tester.pumpAndSettle();
    final reopened = find.byKey(const ValueKey<String>('motor'));
    await tester.tap(
      find.descendant(of: reopened, matching: find.byTooltip('展开')).first,
    );
    await tester.pumpAndSettle();
    expect(enabled(commands), {'motor.speed'});
    expect(watch(controller, 'capture').samplingEnabled, isTrue);
    expect(
      commands.every((c) => c.$1 == ControllerCommand.setMonitorVisibility),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'open table and compact views union demand until the last view closes',
    (tester) async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var showTable = true;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Row(
              children: [
                Expanded(child: CompactWatchPanel(controller: controller)),
                if (showTable)
                  Expanded(child: WatchPanel(controller: controller)),
              ],
            );
          },
        ),
      );
      final motor = find.byKey(const ValueKey<String>('motor'));
      await tester.tap(
        find.descendant(of: motor, matching: find.byTooltip('展开')).first,
      );
      await tester.pumpAndSettle();
      final loop = find.byKey(const ValueKey<String>('motor.loop'));
      await tester.tap(
        find.descendant(of: loop, matching: find.byTooltip('展开')).first,
      );
      await tester.pumpAndSettle();
      expect(enabled(commands), {'motor.speed', 'motor.loop.gain'});
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
      await tester.pumpAndSettle();
      expect(enabled(commands), {'motor.speed', 'motor.loop.gain'});
      update(() => showTable = false);
      await tester.pumpAndSettle();
      expect(enabled(commands), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pooled detached watches stop while unassigned and resume on reuse',
    (tester) async {
      final commands = <(ControllerCommand, Object?)>[];
      final controller = fixture(commands);
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      controller.setWatchReadMode('manual', WatchReadMode.monitor);
      var assigned = true;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return DetachedPanelWindow(
              controller: controller,
              panel: WorkspacePanelId.watch,
              assigned: assigned,
            );
          },
        ),
      );
      expect(enabled(commands), {'manual'});
      update(() => assigned = false);
      await tester.pumpAndSettle();
      expect(enabled(commands), isEmpty);
      update(() => assigned = true);
      await tester.pumpAndSettle();
      expect(enabled(commands), {'manual'});
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
