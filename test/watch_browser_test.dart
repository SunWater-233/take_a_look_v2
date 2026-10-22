import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

TakeALookController structureFixture() {
  final c = TakeALookController(backendCommand: (_, _) async {});
  final definitions = <(String, String)>[
    ('motor', 'struct MotorState'),
    ('motor.speed', 'float'),
    ('motor.current', 'struct CurrentDQ'),
    ('motor.current.d', 'float'),
    ('motor.current.q', 'float'),
    ('motor.pid', 'struct PIDConfig'),
    ('motor.pid.kp', 'float'),
    ('motor.pid.ki', 'float'),
    ('motor.samples', 'float[256]'),
    for (var i = 0; i < 256; i++) ('motor.samples[$i]', 'float'),
  ];
  c.applySnapshot({
    'symbols': [
      for (final (i, d) in definitions.indexed)
        {
          'key': d.$1,
          'source': 'motor.c',
          'name': d.$1,
          'address': 0x20001000 + i * 4,
          'size': 4,
          'type': d.$2,
        },
    ],
  });
  c.selectSymbols(['motor']);
  c.addSelectedToWatch(mode: WatchReadMode.monitor);
  return c;
}

Future<void> mount(
  WidgetTester tester,
  TakeALookController c, {
  double width = 430,
  TalInputMode inputMode = TalInputMode.mouseKeyboard,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 850));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(inputMode: inputMode),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('browser-preview'),
          child: buildWorkspacePanelBody(
            WorkspacePanelId.watch,
            c,
            workbench: true,
            adaptiveWorkbench: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('search reveals nested members and clearing restores expansion', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester, c);
    expect(c.compactExpandedWatches, contains('motor'));
    expect(
      find.byKey(const ValueKey('compact-watch-motor.current.q')),
      findsNothing,
    );
    final search = find.byKey(const ValueKey('watch-member-search'));
    await tester.enterText(search, 'current.q');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compact-watch-motor.current.q')),
      findsOneWidget,
    );
    expect(c.compactExpandedWatches, isNot(contains('motor.current')));
    await tester.enterText(search, '');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compact-watch-motor.current.q')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compact-watch-motor.speed')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pin survives collapse and selected details preserve drafts', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester, c);
    await tester.tap(find.byKey(const ValueKey('compact-watch-motor.speed')));
    await tester.pump();
    c.watchInputDrafts['motor.speed'] = '1500';
    await tester.tap(find.byKey(const ValueKey('watch-pin-motor.speed')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('pinned-watch-motor.speed')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('pinned-watch-motor.speed')),
      findsOneWidget,
    );
    expect(c.watchInputDrafts['motor.speed'], '1500');
    expect(
      c.isWatchMonitorActive(
        c.watches.firstWhere((w) => w.symbol.key == 'motor.speed'),
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large arrays expand in ranges without extra details controls', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester, c);
    await tester.tap(find.byKey(const ValueKey('compact-watch-motor.samples')));
    await tester.pump();
    expect(find.text('[0]…[31]'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compact-watch-motor.samples[0]')),
      findsNothing,
    );
    expect(find.text('展开本层'), findsNothing);
    expect(find.text('索引'), findsNothing);
    expect(find.text('·'), findsNothing);
    await tester.tap(find.text('[0]…[31]'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compact-watch-motor.samples[0]')),
      findsOneWidget,
    );
    expect(c.watches.every((w) => w.readMode == WatchReadMode.monitor), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'read scopes union across views and pinned configuration round trips',
    () async {
      final calls = <(ControllerCommand, Object?)>[];
      final c = TakeALookController(
        backendCommand: (cmd, args) async {
          calls.add((cmd, args));
        },
      )..loadDemoSymbols();
      addTearDown(c.dispose);
      c.selectSymbols(demoSymbols.take(2).map((s) => s.key));
      c.addSelectedToWatch(mode: WatchReadMode.monitor);
      final a = c.watches[0], b = c.watches[1];
      c.setWatchMonitorScope('sidebar', [a.symbol.key]);
      expect(c.isWatchMonitorActive(b), isFalse);
      c.setWatchMonitorScope('focus', [b.symbol.key]);
      expect(c.isWatchMonitorActive(b), isTrue);
      c.setWatchMonitorScope('focus', null);
      c.setWatchPinned(b.symbol.key, true);
      expect(c.isWatchMonitorActive(b), isTrue);
      c.setWatchReadMode(a.symbol.key, WatchReadMode.capture);
      c.setWatchMonitorScope('sidebar', []);
      final wire = (calls.last.$2 as Map)['watches'] as List;
      expect((wire.first as Map)['readMode'], 'capture');
      expect((wire.last as Map)['monitorEnabled'], isTrue);
      final project = c.projectSettings();
      final restored = TakeALookController();
      addTearDown(restored.dispose);
      await restored.restoreProjectSettings(project);
      expect(restored.watches.last.pinned, isTrue);
      final remote = TakeALookController()..applySnapshot(c.stateSnapshot());
      addTearDown(remote.dispose);
      expect(remote.watches.last.pinned, isTrue);
      // Backend echoes do not know about presentation preferences.
      final echo = c.stateSnapshot();
      for (final watch in echo['watches'] as List) {
        (watch as Map).remove('pinned');
      }
      c.applySnapshot(echo);
      expect(c.watches.last.pinned, isTrue);
    },
  );

  testWidgets('production rendering fits sidebar, focus view and touch', (
    tester,
  ) async {
    for (final font in [
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
      ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.compactExpandedWatches.addAll(['motor.current', 'motor.pid']);
    c.compactWatchSelection = 'motor.current.q';
    c.setWatchPinned('motor.speed', true);
    c.setWatchPinned('motor.current.q', true);
    c.applyWatchValues({
      'values': [
        {'key': 'motor.speed', 'value': 1450, 'updatedAtMs': 1},
        {'key': 'motor.current.q', 'value': 2.31, 'updatedAtMs': 1},
      ],
    });
    for (final (name, width, mode) in [
      ('sidebar', 430.0, TalInputMode.mouseKeyboard),
      ('focus', 1040.0, TalInputMode.mouseKeyboard),
      ('touch', 320.0, TalInputMode.touch),
    ]) {
      await mount(tester, c, width: width, inputMode: mode);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('browser-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/watch_browser/$name.png')
          ..parent.createSync(recursive: true);
        file.writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
