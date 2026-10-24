import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode watch sections collapse independently and keep their state',
      (tester) async {
        final c = structureFixture();
        addTearDown(c.dispose);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        c.setWatchPinned('motor.speed', true);
        c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
        c.compactExpandedWatches.add('motor.current');
        c.watchInputDrafts['motor.current.q'] = '4.5';
        await mount(
          tester,
          c,
          width: mode == TalInputMode.touch ? 320 : 430,
          inputMode: mode,
        );
        final expansion = Set<String>.of(c.compactExpandedWatches);
        const pinned = ValueKey('pinned-watch-motor.speed');
        const plotted = ValueKey('plotted-watch-motor.current.q');
        const member = ValueKey('compact-watch-motor.current.q');
        for (final key in [pinned, plotted, member]) {
          expect(find.byKey(key), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('watch-pinned-section')));
        await tester.pump();
        expect(find.byKey(pinned), findsNothing);
        expect(find.byKey(plotted), findsOneWidget);
        expect(find.byKey(member), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('watch-plotted-section')));
        await tester.pump();
        expect(find.byKey(plotted), findsNothing);
        expect(find.byKey(member), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('watch-members-section')));
        await tester.pump();
        expect(find.byKey(member), findsNothing);
        expect(
          find.byKey(const ValueKey('watch-value-column-resize')),
          findsNothing,
        );
        final captured = c.watches.firstWhere(
          (w) => w.symbol.key == 'motor.current.q',
        );
        expect(captured.samplingEnabled, isTrue);
        expect(captured.plotted, isTrue);
        expect(
          c.isWatchMonitorActive(
            c.watches.firstWhere((w) => w.symbol.key == 'motor.speed'),
          ),
          isTrue,
        );
        expect(
          c.isWatchMonitorActive(
            c.watches.firstWhere((w) => w.symbol.key == 'motor.current.d'),
          ),
          isFalse,
        );
        c.setWatchColor(captured.symbol.key, Colors.blue);
        await tester.enterText(
          find.byKey(const ValueKey('watch-member-search')),
          'current.q',
        );
        await tester.pump();
        for (final key in [pinned, plotted, member]) {
          expect(find.byKey(key), findsNothing);
        }
        await tester.enterText(
          find.byKey(const ValueKey('watch-member-search')),
          '',
        );
        for (final section in ['pinned', 'plotted', 'members']) {
          await tester.tap(find.byKey(ValueKey('watch-$section-section')));
          await tester.pump();
        }
        for (final key in [pinned, plotted, member]) {
          expect(find.byKey(key), findsOneWidget);
        }
        expect(c.compactExpandedWatches, expansion);
        expect(c.watchInputDrafts['motor.current.q'], '4.5');
        expect(captured.color, Colors.blue);
        expect(
          c.isWatchMonitorActive(
            c.watches.firstWhere((w) => w.symbol.key == 'motor.current.d'),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final mode in TalInputMode.values) {
    testWidgets('$mode capture and plotting controls work independently', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(
        tester,
        c,
        width: mode == TalInputMode.touch ? 320 : 430,
        inputMode: mode,
      );
      final watch = c.watches.firstWhere((w) => w.symbol.key == 'motor.speed');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('compact-watch-motor.speed')),
          matching: find.text('speed'),
        ),
      );
      await tester.pump();
      const capture = ValueKey('compact-watch-capture-motor.speed');
      const plot = ValueKey('compact-watch-plot-motor.speed');
      const plottedRow = ValueKey('plotted-watch-motor.speed');
      expect(find.byKey(plot), findsNothing);
      expect(find.byKey(plottedRow), findsNothing);
      expect(find.text('加入曲线'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(capture),
          matching: find.byIcon(Icons.sensors),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(capture));
      await tester.pump();
      expect(watch.readMode, WatchReadMode.capture);
      expect(find.byKey(plot), findsOneWidget);
      expect(find.byKey(plottedRow), findsOneWidget);
      await tester.tap(find.byKey(plot));
      await tester.pump();
      expect(watch.plotted, isFalse);
      expect(watch.readMode, WatchReadMode.capture);
      expect(find.byKey(plottedRow), findsNothing);
      c.applyBackendSamples({
        'captureOnly': true,
        'updatedAtMs': 1,
        'frames': [
          {
            'elapsed': 1.0,
            'values': {watch.symbol.key: 12.0},
          },
        ],
      });
      expect(watch.samples.single.dy, 12);
      await tester.tap(
        find.byKey(const ValueKey('watch-detail-plot-motor.speed')),
      );
      await tester.pump();
      expect(find.byKey(plottedRow), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('watch-detail-capture-motor.speed')),
      );
      await tester.pump();
      expect(watch.readMode, WatchReadMode.monitor);
      expect(watch.plotted, isFalse);
      expect(find.byKey(plot), findsNothing);
      expect(find.byKey(plottedRow), findsNothing);
      expect(watch.samples.single.dy, 12);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('plotted members remain accessible through collapse and search', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
    c.setWatchPinned('motor.current.q', true);
    await mount(tester, c);
    const plottedRow = ValueKey('plotted-watch-motor.current.q');
    expect(find.byKey(plottedRow), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compact-watch-motor.current.q')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('watch-member-search')),
      'pid',
    );
    await tester.pump();
    expect(find.byKey(plottedRow), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pinned-watch-motor.current.q')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('compact-watch-plot-plotted-motor.current.q')),
    );
    await tester.pump();
    final watch = c.watches.firstWhere(
      (w) => w.symbol.key == 'motor.current.q',
    );
    expect(watch.samplingEnabled, isTrue);
    expect(watch.plotted, isFalse);
    expect(find.byKey(plottedRow), findsNothing);
    expect(
      find.byKey(const ValueKey('pinned-watch-motor.current.q')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  testWidgets('blank collapse clears searches and array range expansions', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.compactExpandedWatches.addAll([
      'motor.current',
      'motor.samples',
      'motor.samples:range:0',
    ]);
    await mount(tester, c);
    final search = find.byKey(const ValueKey('watch-member-search'));
    await tester.enterText(search, 'current.q');
    await tester.pump();
    final area = tester.getRect(
      find.byKey(const ValueKey('compact-watch-list-context-area')),
    );
    await tester.tapAt(
      area.topLeft + const Offset(3, 3),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('折叠所有'));
    await tester.pumpAndSettle();
    expect(c.compactExpandedWatches, isEmpty);
    expect(c.watchSearchQuery, isEmpty);
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('compact-watch-motor')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compact-watch-motor.speed')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Shift range skips collapsed children and keeps branches folded',
    (tester) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, c);
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor.speed')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor.pid')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(c.compactExpandedWatches, {'motor'});
      await tester.tap(
        find.byKey(const ValueKey('compact-watch-motor.current')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('删除所选变量（3）'), findsOneWidget);
      await tester.tap(find.text('删除所选变量（3）'));
      await tester.pumpAndSettle();
      expect(
        c.watches.map((w) => w.symbol.key),
        isNot(contains(anyOf('motor.speed', 'motor.current', 'motor.pid'))),
      );
      expect(c.watches.map((w) => w.symbol.key), contains('motor.current.q'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'isolating a branch plots its captured members without filtering rows',
    (tester) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.setWatchReadMode('motor.speed', WatchReadMode.capture);
      c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
      await mount(tester, c);
      await tester.tap(
        find.byKey(const ValueKey('compact-watch-motor.current')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('孤立'));
      await tester.pumpAndSettle();
      expect(c.watches.where((w) => w.plotted).map((w) => w.symbol.key), [
        'motor.current.q',
      ]);
      expect(
        find.byKey(const ValueKey('compact-watch-motor.speed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('compact-watch-motor.pid')),
        findsOneWidget,
      );
      expect(c.compactExpandedWatches, {'motor'});
      c.exitWatchPlotIsolation();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
    c.setWatchReadMode('motor.speed', WatchReadMode.capture);
    c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
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
      await tester.pumpAndSettle();
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
