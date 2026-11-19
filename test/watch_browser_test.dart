import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart' show TalUiScaleViewport;
import 'package:take_a_look_v2/src/chart/inspection_anchor.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

TakeALookController structureFixture({
  BackendCommand? backendCommand,
  Iterable<(String, String)> additionalDefinitions = const [],
}) {
  final c = TakeALookController(
    backendCommand: backendCommand ?? (_, _) async {},
  );
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
    ...additionalDefinitions,
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
  double height = 850,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width * scale, height * scale));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(inputMode: inputMode),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('browser-preview'),
          child: TalUiScaleViewport(
            scale: scale,
            child: buildWorkspacePanelBody(
              WorkspacePanelId.watch,
              c,
              workbench: true,
              adaptiveWorkbench: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets('$mode members header aligns the name and monitor rate', (
      tester,
    ) async {
      late final TakeALookController c;
      c = structureFixture(
        backendCommand: (command, arguments) async {
          if (command == ControllerCommand.setMonitorRate) {
            c.applySnapshot({'monitorRateHz': arguments});
          }
        },
      );
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, c, width: 320, inputMode: mode);

      final rate = find.descendant(
        of: find.byKey(const ValueKey('watch-members-pane')),
        matching: find.byKey(const ValueKey('watch-default-monitor-rate')),
      );
      final section = find.text('正在监视');
      final name = find.text('名称');
      final variable = find.descendant(
        of: find.byKey(const ValueKey('compact-watch-motor')),
        matching: find.text('motor'),
      );
      expect(tester.getCenter(rate).dy, tester.getCenter(section).dy);
      expect(
        tester.getTopLeft(rate).dx,
        greaterThan(tester.getTopRight(section).dx),
      );
      expect(tester.getTopLeft(name).dx, tester.getTopLeft(variable).dx);
      expect(
        tester.getBottomLeft(name).dy,
        lessThan(tester.getTopLeft(variable).dy),
      );

      final kind = mode == TalInputMode.touch
          ? PointerDeviceKind.touch
          : PointerDeviceKind.mouse;
      final arrow = find.descendant(
        of: rate,
        matching: find.byIcon(Icons.arrow_drop_down),
      );
      final preset = find.byKey(const ValueKey('dropdown-item-5 Hz'));
      await tester.tap(arrow, kind: kind);
      await tester.pump();
      expect(preset, findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(preset, kind: kind);
      await tester.pumpAndSettle();
      expect(c.monitorRateHz, 5);
      expect(variable.hitTestable(), findsOneWidget);

      await tester.tap(
        find.descendant(of: rate, matching: find.text('5 Hz')),
        kind: kind,
      );
      await tester.pump();
      final editor = find.descendant(
        of: rate,
        matching: find.byType(TextField),
      );
      expect(editor, findsOneWidget);
      expect(preset, findsNothing);
      await tester.enterText(editor, '7.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.monitorRateHz, 7.5);
    });

    testWidgets('$mode section splitter resizes independent scroll areas', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (var i = 0; i < 12; i++) {
        c.setWatchReadMode('motor.samples[$i]', WatchReadMode.capture);
      }
      c.compactExpandedWatches.add('motor.samples');
      await mount(tester, c, inputMode: mode);
      final handle = find.byKey(const ValueKey('watch-sections-resize'));
      final upper = find.byKey(const ValueKey('watch-summary-pane'));
      final lower = find.byKey(const ValueKey('watch-members-pane'));
      final upperHeight = tester.getSize(upper).height;
      final lowerHeight = tester.getSize(lower).height;
      await tester.drag(
        handle,
        const Offset(0, 100),
        kind: mode == TalInputMode.touch
            ? PointerDeviceKind.touch
            : PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(tester.getSize(upper).height, closeTo(upperHeight + 100, .01));
      expect(tester.getSize(lower).height, closeTo(lowerHeight - 100, .01));
      final upperList = find.byKey(const ValueKey('watch-capture-list'));
      final lowerList = find.byKey(const ValueKey('compact-watch-list'));
      final upperScroll = tester.widget<ListView>(upperList).controller!;
      final lowerScroll = tester.widget<ListView>(lowerList).controller!;
      await tester.drag(upperList, const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(upperScroll.offset, greaterThan(0));
      expect(lowerScroll.offset, 0);
      final upperOffset = upperScroll.offset;
      await tester.drag(lowerList, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(lowerScroll.offset, greaterThan(0));
      expect(upperScroll.offset, upperOffset);
      expect(c.watches.where((w) => w.samplingEnabled), hasLength(12));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode member scrolling pins only the current ancestor chain', (
      tester,
    ) async {
      final c = structureFixture(
        additionalDefinitions: [
          ('other', 'struct Other'),
          for (var i = 0; i < 24; i++) ('other.member$i', 'float'),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.selectSymbols(['other']);
      c.addSelectedToWatch(mode: WatchReadMode.monitor);
      c.compactExpandedWatches.addAll([
        'motor.current',
        'motor.samples',
        'motor.samples:range:0',
        'motor.samples:range:1',
      ]);
      c.compactWatchSelection = 'motor.current';
      const scale = 1.25;
      await mount(tester, c, height: 620, inputMode: mode, scale: scale);

      Finder sticky(String key) => find.byKey(ValueKey('watch-sticky-$key'));
      final list = find.byKey(const ValueKey('compact-watch-list'));
      final scroll = tester.widget<ListView>(list).controller!;
      final root = find.byKey(const ValueKey('compact-watch-motor'));
      final top = tester.getTopLeft(list).dy;
      final rowHeight = tester.getSize(root).height;
      final firstRowOffset = (tester.getTopLeft(root).dy - top) / scale;
      Future<void> scrollRows(double count) async {
        scroll.jumpTo(firstRowOffset + count * rowHeight);
        await tester.pumpAndSettle();
      }

      expect(sticky('motor'), findsNothing);
      await scrollRows(2.5);
      expect(tester.getTopLeft(sticky('motor')).dy, closeTo(top, .01));
      expect(
        tester.getTopLeft(sticky('motor.current')).dy,
        closeTo(top + rowHeight * scale, .01),
      );
      expect(sticky('motor.pid'), findsNothing);

      final fade = find.byKey(const ValueKey('watch-members-overflow-top'));
      final firstHeaderRect = tester.getRect(sticky('motor'));
      final headerRect = tester.getRect(sticky('motor.current'));
      final fadeRect = tester.getRect(fade);
      expect(fadeRect.top, closeTo(headerRect.bottom, .01));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('browser-preview')),
      );
      expect(watchRowCenterInChart(c, 'motor.current.d', boundary), isNull);
      Future<void> checkPixels(
        void Function(Color Function(double, double) pixel) check,
      ) async {
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            check((x, y) {
              final p = boundary.globalToLocal(Offset(x, y));
              final index = (p.dy.floor() * image.width + p.dx.floor()) * 4;
              return Color.fromARGB(
                bytes.getUint8(index + 3),
                bytes.getUint8(index),
                bytes.getUint8(index + 1),
                bytes.getUint8(index + 2),
              );
            });
          } finally {
            image.dispose();
          }
        });
      }

      await checkPixels((pixel) {
        final left = headerRect.left;
        expect(pixel(left + 1, headerRect.center.dy), TalColors.surface);
        expect(pixel(left + 8, headerRect.center.dy), TalColors.surface);
        for (var x = left + 8; x < firstHeaderRect.center.dx; x++) {
          expect(pixel(x, firstHeaderRect.top), TalColors.surface);
        }
        for (var x = left + 8; x < headerRect.right - 8; x += 2) {
          expect(pixel(x, headerRect.top), TalColors.surface);
        }
        expect(
          pixel(left + 8, fadeRect.top + 2).r,
          lessThan(TalColors.surface.r),
        );
        expect(pixel(left + 8, fadeRect.bottom + 2), TalColors.surface);
      });

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: firstHeaderRect.center);
      await tester.pumpAndSettle();
      await checkPixels((pixel) {
        expect(
          pixel(firstHeaderRect.left + 8, firstHeaderRect.center.dy),
          TalColors.hover,
        );
        expect(
          pixel(headerRect.left + 8, headerRect.center.dy),
          TalColors.surface,
        );
      });
      await mouse.removePointer();
      await tester.pumpAndSettle();

      await scrollRows(9);
      expect(sticky('motor.current'), findsNothing);
      expect(
        tester.getTopLeft(sticky('motor.samples:range:0')).dy,
        closeTo(top + 2 * rowHeight * scale, .01),
      );
      final before = scroll.offset;
      if (mode == TalInputMode.touch) {
        await tester.timedDrag(
          sticky('motor'),
          Offset(0, -2 * rowHeight),
          const Duration(milliseconds: 220),
        );
      } else {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(sticky('motor')),
            scrollDelta: Offset(0, rowHeight),
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before));

      // The second range starts at row 40, which pushes the first range up.
      await scrollRows(37.5);
      expect(
        tester.getSize(sticky('motor.samples:range:0')).height,
        closeTo(rowHeight / 2, .01),
      );
      expect(
        tester.getTopLeft(fade).dy,
        closeTo(tester.getBottomLeft(sticky('motor.samples:range:0')).dy, .01),
      );
      await scrollRows(38.5);
      expect(sticky('motor.samples:range:0'), findsNothing);
      expect(sticky('motor.samples:range:1'), findsOneWidget);

      await tester.tap(sticky('motor.samples'));
      await tester.pumpAndSettle();
      expect(c.compactExpandedWatches, isNot(contains('motor.samples')));
      expect(sticky('motor.samples'), findsNothing);
      expect(
        find.byKey(const ValueKey('compact-watch-motor.samples')).hitTestable(),
        findsOneWidget,
      );

      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(sticky('motor'), findsNothing);
      expect(tester.getTopLeft(sticky('other')).dy, closeTo(top, .01));
      await tester.enterText(
        find.byKey(const ValueKey('watch-member-search')),
        'other.member22',
      );
      await tester.pumpAndSettle();
      expect(sticky('other'), findsNothing);
      expect(
        find
            .byKey(const ValueKey('compact-watch-other.member22'))
            .hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('$mode section splitter clamps and survives panel resize', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, c, inputMode: mode);
      final handle = find.byKey(const ValueKey('watch-sections-resize'));
      final upper = find.byKey(const ValueKey('watch-summary-pane'));
      final lower = find.byKey(const ValueKey('watch-members-pane'));
      await tester.drag(handle, const Offset(0, 2000));
      await tester.pump();
      final headerHeight = mode == TalInputMode.touch ? 48.0 : 30.0;
      expect(tester.getSize(lower).height, closeTo(headerHeight, .01));
      await tester.drag(handle, const Offset(0, -2000));
      await tester.pump();
      expect(tester.getSize(upper).height, closeTo(headerHeight, .01));
      expect(tester.getSize(lower).height, greaterThan(0));
      c.compactWatchSummaryFraction = .4;
      for (final height in [600.0, 280.0, 160.0, 80.0, 850.0]) {
        await mount(tester, c, inputMode: mode, height: height);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(upper).height, greaterThan(0));
        expect(tester.getSize(lower).height, greaterThan(0));
      }
      final total = tester.getSize(upper).height + tester.getSize(lower).height;
      expect(tester.getSize(upper).height / total, closeTo(.4, .001));
      // A different panel instance uses the same saved presentation preference.
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, c, inputMode: mode);
      expect(tester.getSize(upper).height / total, closeTo(.4, .001));
    });

    testWidgets(
      '$mode watch sections collapse independently and keep their state',
      (tester) async {
        final c = structureFixture();
        addTearDown(c.dispose);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        c.setWatchPinned('motor.speed', true);
        c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
        c.toggleWatchPlot('motor.current.q', true);
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
        const capturedRow = ValueKey('capture-watch-motor.current.q');
        const member = ValueKey('compact-watch-motor.current.q');
        for (final key in [pinned, capturedRow, member]) {
          expect(find.byKey(key), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('watch-pinned-section')));
        await tester.pump();
        expect(find.byKey(pinned), findsNothing);
        expect(find.byKey(capturedRow), findsOneWidget);
        expect(find.byKey(member), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('watch-capture-section')));
        await tester.pump();
        expect(find.byKey(capturedRow), findsNothing);
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
        for (final key in [pinned, capturedRow, member]) {
          expect(find.byKey(key), findsNothing);
        }
        await tester.enterText(
          find.byKey(const ValueKey('watch-member-search')),
          '',
        );
        for (final section in ['pinned', 'capture', 'members']) {
          await tester.tap(find.byKey(ValueKey('watch-$section-section')));
          await tester.pump();
        }
        for (final key in [pinned, capturedRow, member]) {
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
      const capturedRow = ValueKey('capture-watch-motor.speed');
      expect(find.byKey(plot), findsNothing);
      expect(find.byKey(capturedRow), findsNothing);
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
      expect(watch.plotted, isTrue);
      expect(find.byKey(capturedRow), findsOneWidget);
      expect(find.text('正在采集'), findsOneWidget);
      await tester.tap(find.byKey(plot));
      await tester.pump();
      expect(watch.readMode, WatchReadMode.capture);
      expect(watch.plotted, isFalse);
      expect(find.byKey(capturedRow), findsOneWidget);
      await tester.tap(find.byKey(plot));
      await tester.pump();
      expect(watch.plotted, isTrue);
      expect(watch.readMode, WatchReadMode.capture);
      expect(find.byKey(capturedRow), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('watch-capture-section')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
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
      expect(find.byKey(capturedRow), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('watch-detail-capture-motor.speed')),
      );
      await tester.pump();
      expect(watch.readMode, WatchReadMode.monitor);
      expect(watch.plotted, isFalse);
      expect(find.byKey(plot), findsNothing);
      expect(find.byKey(capturedRow), findsNothing);
      expect(watch.samples.single.dy, 12);
      await tester.tap(find.byKey(capture));
      await tester.pump();
      expect(watch.readMode, WatchReadMode.capture);
      expect(watch.plotted, isTrue);
      expect(find.byKey(capturedRow), findsOneWidget);
      await tester.tap(find.byKey(plot));
      await tester.pump();
      expect(watch.plotted, isFalse);
      expect(watch.readMode, WatchReadMode.capture);
      expect(watch.samples.single.dy, 12);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'captured members stay listed when curves are hidden, collapsed or filtered',
    (tester) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
      c.toggleWatchPlot('motor.current.q', true);
      c.setWatchPinned('motor.current.q', true);
      await mount(tester, c);
      const capturedRow = ValueKey('capture-watch-motor.current.q');
      expect(find.byKey(capturedRow), findsOneWidget);
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
      expect(find.byKey(capturedRow), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pinned-watch-motor.current.q')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('compact-watch-plot-capture-motor.current.q'),
        ),
      );
      await tester.pump();
      final watch = c.watches.firstWhere(
        (w) => w.symbol.key == 'motor.current.q',
      );
      expect(watch.samplingEnabled, isTrue);
      expect(watch.plotted, isFalse);
      expect(find.byKey(capturedRow), findsOneWidget);
      c.applySnapshot({'samplingPaused': true});
      await tester.pump();
      expect(find.byKey(capturedRow), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('compact-watch-plot-capture-motor.current.q'),
        ),
      );
      await tester.pump();
      expect(watch.plotted, isTrue);
      expect(find.byKey(capturedRow), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('compact-watch-capture-capture-motor.current.q'),
        ),
      );
      await tester.pump();
      expect(watch.samplingEnabled, isFalse);
      expect(find.byKey(capturedRow), findsNothing);
      expect(find.text('暂无正在采集的变量'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pinned-watch-motor.current.q')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
      expect(
        c.watches.map((w) => w.symbol.key),
        isNot(
          contains(
            anyOf(
              'motor.current.d',
              'motor.current.q',
              'motor.pid.kp',
              'motor.pid.ki',
            ),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('array deletion and restore members work from the branch menu', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final originalKeys = c.watches.map((w) => w.symbol.key).toList();
    await mount(tester, c);

    Future<void> menu(String key) async {
      await tester.tap(
        find.byKey(ValueKey('compact-watch-$key')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
    }

    void expectRestoreEnabled(bool enabled) {
      final item = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('恢复成员'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, enabled);
    }

    await menu('motor');
    expectRestoreEnabled(false);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    await menu('motor.samples');
    await tester.tap(find.text('删除变量'));
    await tester.pumpAndSettle();
    expect(
      c.watches.any((w) => w.symbol.name.startsWith('motor.samples')),
      isFalse,
    );
    expect(find.text('[0]'), findsNothing);
    expect(
      find.byKey(const ValueKey('compact-watch-motor.samples')),
      findsNothing,
    );

    await menu('motor');
    expectRestoreEnabled(true);
    await tester.tap(find.text('恢复成员'));
    await tester.pumpAndSettle();
    expect(c.watches.map((w) => w.symbol.key), originalKeys);
    expect(
      find.byKey(const ValueKey('compact-watch-motor.samples')),
      findsOneWidget,
    );
    expect(c.canUndoWatchDeletion, isFalse);

    await menu('motor.speed');
    expect(find.text('恢复成员'), findsNothing);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    // Restoration remains available even when every member has been removed.
    c.removeWatches(c.watches.skip(1).map((w) => w.symbol.key));
    await tester.pump();
    await menu('motor');
    expectRestoreEnabled(true);
    await tester.tap(find.text('恢复成员'));
    await tester.pumpAndSettle();
    expect(c.watches.map((w) => w.symbol.key), originalKeys);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'isolating a branch plots its captured members without filtering rows',
    (tester) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.setWatchReadMode('motor.speed', WatchReadMode.capture);
      c.setWatchReadMode('motor.current.q', WatchReadMode.capture);
      c.setAllWatchesPlotted(true);
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

  testWidgets('long watch names keep their suffix and fade at the left', (
    tester,
  ) async {
    const root = 'chassis_task';
    const path = '$root.some_long_name';
    final c = structureFixture(
      additionalDefinitions: [(root, 'struct ChassisTask'), (path, 'float')],
    );
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.selectSymbols([root]);
    c.addSelectedToWatch(mode: WatchReadMode.monitor);
    c.setWatchStandalone(path, true);
    c.compactWatchSelection = path;
    await mount(tester, c, width: 320);

    final name = find.descendant(
      of: find.byKey(const ValueKey('compact-watch-list')),
      matching: find.text(path),
    );
    final shortName = find.text('motor');
    final mask = find.ancestor(of: name, matching: find.byType(ShaderMask));
    expect(mask, findsOneWidget);
    expect(tester.widget<ShaderMask>(mask).blendMode, BlendMode.dstIn);
    final maskRect = tester.getRect(mask);
    final nameRect = tester.getRect(name);
    expect(nameRect.right, closeTo(maskRect.right, .01));
    expect(nameRect.left, lessThan(maskRect.left));
    expect(maskRect.left, closeTo(tester.getTopLeft(shortName).dx, .01));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('browser-preview')),
    );
    final bounds = maskRect.shift(-boundary.localToGlobal(Offset.zero));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int brightestRed(double left, double right) {
          var brightest = 0;
          for (var y = bounds.top.ceil(); y < bounds.bottom.floor(); y++) {
            for (var x = left.ceil(); x < right.floor(); x++) {
              final red = bytes.getUint8((y * image.width + x) * 4);
              if (red > brightest) brightest = red;
            }
          }
          return brightest;
        }

        final leadingRed = brightestRed(bounds.left, bounds.left + 3);
        final trailingRed = brightestRed(bounds.right - 24, bounds.right);
        expect(leadingRed, lessThan(trailingRed));
        expect(trailingRed, TalColors.text.toARGB32() >> 16 & 0xff);
      } finally {
        image.dispose();
      }
    });

    await mount(tester, c, width: 1040);
    expect(mask, findsNothing);
    expect(
      tester.getTopLeft(name).dx,
      closeTo(tester.getTopLeft(shortName).dx, .01),
    );
  });

  testWidgets('a nested watch can also be monitored at the top level', (
    tester,
  ) async {
    final c = structureFixture();
    addTearDown(c.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    c.setWatchReadMode('motor.speed', WatchReadMode.capture);
    c.toggleWatchPlot('motor.speed', true);
    await mount(tester, c);

    Finder row(String key) => find.byKey(ValueKey('compact-watch-$key'));
    final motor = row('motor');
    final member = row('motor.current');
    final standalone = row('standalone:13:motor.current:motor.current');
    final standaloneLeaf = row('standalone:13:motor.current:motor.current.q');
    Finder label(Finder target, String text) =>
        find.descendant(of: target, matching: find.text(text));
    Future<void> choose(Finder target, String action) async {
      await tester.tap(target, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    final original = c.watches.toList();
    await choose(member, '单独添加到监视');
    expect(standalone.hitTestable(), findsOneWidget);
    expect(label(standalone, 'motor.current'), findsOneWidget);
    expect(standaloneLeaf.hitTestable(), findsOneWidget);
    expect(label(standaloneLeaf, 'q'), findsOneWidget);
    expect(member.hitTestable(), findsOneWidget);
    expect(label(member, 'current'), findsOneWidget);
    expect(row('motor.current.q'), findsNothing);
    expect(
      tester.getTopLeft(standalone).dy,
      lessThan(tester.getTopLeft(motor).dy),
    );
    expect(c.watches, orderedEquals(original));
    expect(
      c.watches
          .firstWhere((watch) => watch.symbol.key == 'motor.speed')
          .plotted,
      isTrue,
    );

    await tester.tap(motor);
    await tester.pumpAndSettle();
    expect(member, findsNothing);
    expect(standaloneLeaf.hitTestable(), findsOneWidget);
    await choose(standalone, '取消单独监视');
    expect(standalone, findsNothing);
    expect(member, findsNothing);

    await tester.tap(motor);
    await tester.pumpAndSettle();
    expect(member.hitTestable(), findsOneWidget);
    await choose(row('motor.speed'), '单独添加到监视');
    final standaloneSpeed = row('standalone:11:motor.speed:motor.speed');
    expect(standaloneSpeed.hitTestable(), findsOneWidget);
    expect(label(standaloneSpeed, 'motor.speed'), findsOneWidget);
    expect(c.watches, orderedEquals(original));
  });

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
    c.setAllWatchesPlotted(true);
    c.toggleWatchPlot('motor.speed', false);
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
