import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

import 'watch_browser_test.dart' show mount, structureFixture;

Finder pane(String name) => find.byKey(ValueKey('watch-$name-pane'));
Finder row(String section, String key) =>
    find.byKey(ValueKey('$section-watch-$key'));

Future<void> reorder(
  WidgetTester tester,
  String section,
  String key,
  Finder target, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  bool after = true,
  double startFraction = .25,
}) async {
  final source = find.byKey(ValueKey('watch-reorder-$section-$key'));
  final sourceRect = tester.getRect(source);
  final rect = tester.getRect(target);
  final gesture = await tester.startGesture(
    Offset(
      sourceRect.left + sourceRect.width * startFraction,
      sourceRect.center.dy,
    ),
    kind: kind,
  );
  if (kind != PointerDeviceKind.mouse) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  await gesture.moveBy(const Offset(0, 8));
  await tester.pump();
  await gesture.moveTo(
    Offset(rect.left + 60, after ? rect.bottom - 3 : rect.top + 3),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final mode in TalInputMode.values) {
    final kind = mode == TalInputMode.touch
        ? PointerDeviceKind.touch
        : PointerDeviceKind.mouse;

    testWidgets('$mode three panes resize adjacent sections independently', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (var i = 0; i < 12; i++) {
        c.setWatchPinned('motor.samples[$i]', true);
        c.setWatchReadMode('motor.samples[$i]', WatchReadMode.capture);
      }
      c.compactExpandedWatches.add('motor.samples');
      c.compactWatchPinnedFraction = .18;
      c.compactWatchSummaryFraction = .6;
      await mount(tester, c, width: 1040, inputMode: mode);
      final pinned = tester.getSize(pane('pinned')).height;
      final capture = tester.getSize(pane('capture')).height;
      final members = tester.getSize(pane('members')).height;
      await tester.drag(
        find.byKey(const ValueKey('watch-pinned-capture-resize')),
        const Offset(0, 40),
        kind: kind,
      );
      await tester.pump();
      expect(tester.getSize(pane('pinned')).height, closeTo(pinned + 40, .01));
      expect(
        tester.getSize(pane('capture')).height,
        closeTo(capture - 40, .01),
      );
      expect(tester.getSize(pane('members')).height, members);
      await tester.drag(
        find.byKey(const ValueKey('watch-sections-resize')),
        const Offset(0, 40),
        kind: kind,
      );
      await tester.pump();
      expect(tester.getSize(pane('pinned')).height, closeTo(pinned + 40, .01));
      expect(tester.getSize(pane('capture')).height, closeTo(capture, .01));
      expect(
        tester.getSize(pane('members')).height,
        closeTo(members - 40, .01),
      );

      final lists = [
        for (final key in [
          'watch-pinned-list',
          'watch-capture-list',
          'compact-watch-list',
        ])
          tester.widget<ListView>(find.byKey(ValueKey(key))).controller!,
      ];
      for (final (i, scroll) in lists.indexed) {
        scroll.jumpTo(40);
        await tester.pump();
        expect(scroll.offset, 40);
        for (var j = i + 1; j < lists.length; j++) {
          expect(lists[j].offset, 0);
        }
      }
      for (final height in [280.0, 160.0, 80.0, 850.0]) {
        await mount(tester, c, inputMode: mode, height: height);
        expect(tester.takeException(), isNull);
        for (final name in ['pinned', 'capture', 'members']) {
          expect(tester.getSize(pane(name)).height, greaterThanOrEqualTo(0));
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$mode each section reorders without changing other sections', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final key in ['motor.speed', 'motor.current.d', 'motor.current.q']) {
        c.setWatchPinned(key, true);
        c.setWatchReadMode(key, WatchReadMode.capture);
      }
      c.compactExpandedWatches.add('motor.current');
      c.compactWatchSummaryFraction = .55;
      c.compactWatchPinnedFraction = .25;
      final original = c.watches.toList();
      await mount(tester, c, width: 1040, height: 1000, inputMode: mode);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);

      await reorder(
        tester,
        'pinned',
        'motor.speed',
        row('pinned', 'motor.current.q'),
        kind: kind,
      );
      expect(
        tester.getTopLeft(row('pinned', 'motor.speed')).dy,
        greaterThan(tester.getTopLeft(row('pinned', 'motor.current.q')).dy),
      );
      expect(
        tester.getTopLeft(row('capture', 'motor.speed')).dy,
        lessThan(tester.getTopLeft(row('capture', 'motor.current.q')).dy),
      );
      await reorder(
        tester,
        'capture',
        'motor.current.q',
        row('capture', 'motor.speed'),
        kind: kind,
        after: false,
        startFraction: .6,
      );
      expect(
        tester.getTopLeft(row('capture', 'motor.current.q')).dy,
        lessThan(tester.getTopLeft(row('capture', 'motor.speed')).dy),
      );

      await reorder(
        tester,
        'members',
        'motor.current.d',
        row('compact', 'motor.current.q'),
        kind: kind,
        startFraction: .02,
      );
      expect(
        tester.getTopLeft(row('compact', 'motor.current.d')).dy,
        greaterThan(tester.getTopLeft(row('compact', 'motor.current.q')).dy),
      );
      expect(
        tester.getTopLeft(row('pinned', 'motor.speed')).dy,
        greaterThan(tester.getTopLeft(row('pinned', 'motor.current.q')).dy),
      );
      expect(c.watches, orderedEquals(original));
      expect(c.watches.where((w) => w.samplingEnabled), hasLength(3));
      expect(c.watches.where((w) => w.pinned), hasLength(3));

      final memberOrder = c.compactWatchSectionOrders['members']!.toList();
      await reorder(
        tester,
        'members',
        'motor.current.d',
        row('compact', 'motor.speed'),
        kind: kind,
      );
      expect(c.compactWatchSectionOrders['members'], memberOrder);
      final pinnedOrder = c.compactWatchSectionOrders['pinned']!.toList();
      await reorder(
        tester,
        'pinned',
        'motor.speed',
        row('capture', 'motor.speed'),
        kind: kind,
      );
      expect(c.compactWatchSectionOrders['members'], memberOrder);
      expect(c.compactWatchSectionOrders['pinned'], pinnedOrder);

      await reorder(
        tester,
        'members',
        'motor.current',
        row('compact', 'motor.pid'),
        kind: kind,
      );
      expect(
        tester.getTopLeft(row('compact', 'motor.current')).dy,
        greaterThan(tester.getTopLeft(row('compact', 'motor.pid')).dy),
      );
      expect(
        tester.getTopLeft(row('compact', 'motor.current.q')).dy,
        greaterThan(tester.getTopLeft(row('compact', 'motor.current')).dy),
      );
      expect(c.compactExpandedWatches, contains('motor.current'));

      final settings = c.projectSettings();
      await tester.pumpWidget(const SizedBox.shrink());
      final restored = structureFixture();
      addTearDown(restored.dispose);
      await restored.restoreProjectSettings(settings);
      await mount(tester, restored, width: 1040, height: 1000, inputMode: mode);
      expect(restored.compactWatchSectionOrders, c.compactWatchSectionOrders);
      expect(restored.compactWatchPinnedFraction, c.compactWatchPinnedFraction);
      expect(
        restored.compactWatchSummaryFraction,
        c.compactWatchSummaryFraction,
      );
      expect(
        tester.getTopLeft(row('pinned', 'motor.speed')).dy,
        greaterThan(tester.getTopLeft(row('pinned', 'motor.current.q')).dy),
      );
      expect(
        tester.getTopLeft(row('compact', 'motor.current.d')).dy,
        greaterThan(tester.getTopLeft(row('compact', 'motor.current.q')).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$mode dragging near an edge scrolls only its own section', (
      tester,
    ) async {
      final c = structureFixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (var i = 0; i < 40; i++) {
        c.setWatchPinned('motor.samples[$i]', true);
        c.setWatchReadMode('motor.samples[$i]', WatchReadMode.capture);
      }
      c.compactWatchPinnedFraction = .2;
      c.compactWatchSummaryFraction = .5;
      await mount(tester, c, width: 1040, inputMode: mode);
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('watch-pinned-list')))
          .controller!;
      final source = find.byKey(
        const ValueKey('watch-reorder-pinned-motor.samples[0]'),
      );
      final gesture = await tester.startGesture(
        tester.getTopLeft(source) + const Offset(90, 16),
        kind: kind,
      );
      if (kind != PointerDeviceKind.mouse) {
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      }
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      final rect = tester.getRect(pane('pinned'));
      await gesture.moveTo(Offset(rect.left + 60, rect.bottom - 1));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(scroll.offset, greaterThan(32));
      for (final key in ['watch-capture-list', 'compact-watch-list']) {
        expect(
          tester.widget<ListView>(find.byKey(ValueKey(key))).controller!.offset,
          0,
        );
      }
      await gesture.moveTo(Offset(rect.left + 60, rect.top + 1));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(scroll.offset, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test(
    'older projects use default layouts and malformed preferences are rejected',
    () async {
      final c = structureFixture();
      addTearDown(c.dispose);
      final settings = c.projectSettings()
        ..remove('compactWatchPinnedFraction')
        ..remove('compactWatchSectionOrders');
      await c.restoreProjectSettings(settings);
      expect(c.compactWatchPinnedFraction, isNull);
      expect(c.compactWatchSectionOrders, isEmpty);
      for (final invalid in [
        {'compactWatchPinnedFraction': 1},
        {'compactWatchPinnedFraction': double.nan},
        {'compactWatchSectionOrders': []},
        {
          'compactWatchSectionOrders': {
            'members': ['motor', 'motor'],
          },
        },
        {
          'compactWatchSectionOrders': {
            'members': [1],
          },
        },
      ]) {
        expect(
          () => TakeALookControllerProject.validateProjectSettings({
            ...settings,
            ...invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
