import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  Future<TakeALookController> pumpChart(WidgetTester tester) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch();
    final key = controller.watches.single.symbol.key;
    controller.applyTelemetrySnapshot({
      'elapsedSeconds': 20,
      'watches': [
        {
          'key': key,
          'value': 2,
          'samples': [
            for (var second = 0; second <= 20; second += 1)
              [second.toDouble(), second / 10],
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 480,
            child: TelemetryChart(controller: controller),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('left drag pans the plot and exits follow-latest mode', (
    tester,
  ) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );
    final before = telemetryViewport(controller, tester.getSize(interaction));
    final gesture = await tester.startGesture(
      tester.getCenter(interaction),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(80, 24));
    await gesture.up();
    await tester.pump();

    final after = telemetryViewport(controller, tester.getSize(interaction));
    expect(controller.followLatest, isFalse);
    expect(controller.plotAutoY, isFalse);
    expect(after.xMax, lessThan(before.xMax));
    expect(after.yMin, greaterThan(before.yMin));
    controller.dispose();
  });

  testWidgets('mouse right click uses the compact PyQtGraph-style menu', (
    tester,
  ) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );

    final rightClick = await tester.startGesture(
      tester.getTopLeft(interaction) + const Offset(140, 160),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.moveBy(const Offset(1, 1));
    await tester.pump();
    expect(find.text('View All'), findsNothing);
    expect(controller.followLatest, isTrue);
    expect(controller.plotAutoY, isTrue);
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(timeDilation, 0.6);
    expect(find.text('View All'), findsOneWidget);
    expect(find.text('X Axis'), findsOneWidget);
    expect(find.text('Y Axis'), findsOneWidget);
    expect(find.text('Mouse Mode'), findsOneWidget);
    expect(find.text('显示全部'), findsNothing);
    final menuAnchor = tester.widget<MenuAnchor>(
      find.byKey(const ValueKey('desktop-plot-menu-anchor')),
    );
    final menuShape = menuAnchor.style!.shape!.resolve({});
    expect(menuAnchor.animated, isTrue);
    expect(
      (menuShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(8),
    );
    expect(
      tester
          .widget<SubmenuButton>(
            find.byKey(const ValueKey('desktop-plot-x-axis')),
          )
          .animated,
      isTrue,
    );

    final rootAxisRect = tester.getRect(
      find.byKey(const ValueKey('desktop-plot-x-axis')),
    );
    await tester.tap(find.text('X Axis'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-x-axis-panel')), findsOneWidget);
    final submenuRect = tester.getRect(
      find.byKey(const ValueKey('desktop-x-axis-panel')),
    );
    expect(submenuRect.left, greaterThanOrEqualTo(rootAxisRect.right - 1));
    expect(find.text('Y Axis'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Invert Axis'), findsOneWidget);
    expect(find.text('Mouse Enabled'), findsOneWidget);
    expect(find.text('Link Axis:'), findsOneWidget);

    await tester.tap(find.text('Manual'));
    await tester.pump();
    expect(controller.followLatest, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-x-minimum')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('desktop-x-maximum')),
      '8',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(controller.followLatest, isFalse);
    expect(controller.plotVisibleWindowSeconds, 6);
    expect(controller.plotWindowEndSeconds, 8);
    await tester.tapAt(tester.getTopRight(interaction) + const Offset(-20, 20));
    await tester.pumpAndSettle();
    expect(timeDilation, 1);
    controller.dispose();
  });

  for (final inverted in [false, true]) {
    for (final vertical in [false, true]) {
      testWidgets(
        'right drag zooms only the ${vertical ? 'Y' : 'X'} axis around its '
        'starting point (inverted: $inverted)',
        (tester) async {
          final controller = await pumpChart(tester);
          controller.configurePlotView({
            'plotInvertX': inverted,
            'plotInvertY': inverted,
          });
          final interaction = find.byKey(
            const ValueKey('telemetry-chart-interaction'),
          );
          final size = tester.getSize(interaction);
          final before = telemetryViewport(controller, size);
          final localStart =
              before.plot.topLeft +
              Offset(before.plot.width * 0.35, before.plot.height * 0.6);
          CartesianPlotViewport mappingFor(TelemetryViewport viewport) =>
              CartesianPlotViewport(
                plot: viewport.plot,
                xMin: viewport.xMin,
                xMax: viewport.xMax,
                yMin: viewport.yMin,
                yMax: viewport.yMax,
                invertX: inverted,
                invertY: inverted,
              );
          final anchorX = mappingFor(before).unmapX(localStart.dx);
          final anchorY = mappingFor(before).unmapY(localStart.dy);
          final drag = await tester.startGesture(
            tester.getTopLeft(interaction) + localStart,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          final delta = vertical ? const Offset(0, -20) : const Offset(20, 0);
          for (var move = 0; move < 2; move += 1) {
            await drag.moveBy(delta);
            await tester.pump();
            final after = telemetryViewport(controller, size);
            if (vertical) {
              expect(after.ySpan, lessThan(before.ySpan));
              expect(after.xMin, closeTo(before.xMin, 1e-9));
              expect(after.xMax, closeTo(before.xMax, 1e-9));
            } else {
              expect(after.xSpan, lessThan(before.xSpan));
              expect(after.yMin, closeTo(before.yMin, 1e-9));
              expect(after.yMax, closeTo(before.yMax, 1e-9));
            }
            expect(
              mappingFor(after).mapX(anchorX),
              closeTo(localStart.dx, 1e-8),
            );
            expect(
              mappingFor(after).mapY(anchorY),
              closeTo(localStart.dy, 1e-8),
            );
            expect(find.text('View All'), findsNothing);
          }
          expect(controller.followLatest, isFalse);
          expect(controller.plotAutoY, isFalse);

          await drag.moveBy(-delta * 2);
          await drag.up();
          await tester.pumpAndSettle();
          final restored = telemetryViewport(controller, size);
          expect(restored.xMin, closeTo(before.xMin, 1e-9));
          expect(restored.xMax, closeTo(before.xMax, 1e-9));
          expect(restored.yMin, closeTo(before.yMin, 1e-9));
          expect(restored.yMax, closeTo(before.yMax, 1e-9));
          expect(find.text('View All'), findsNothing);
          controller.dispose();
        },
      );
    }
  }

  for (final enabled in [(true, false), (false, true), (false, false)]) {
    testWidgets(
      'right drag respects mouse axis locks (X: ${enabled.$1}, Y: ${enabled.$2})',
      (tester) async {
        final controller = await pumpChart(tester);
        controller.setPlotViewport(xMin: 4, xMax: 16, yMin: -2, yMax: 4);
        controller.configurePlotView({
          'plotMouseXEnabled': enabled.$1,
          'plotMouseYEnabled': enabled.$2,
        });
        final interaction = find.byKey(
          const ValueKey('telemetry-chart-interaction'),
        );
        final size = tester.getSize(interaction);
        final before = telemetryViewport(controller, size);
        final drag = await tester.startGesture(
          tester.getCenter(interaction),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await drag.moveBy(const Offset(40, -40));
        await drag.up();
        await tester.pumpAndSettle();
        final after = telemetryViewport(controller, size);
        if (enabled.$1) {
          expect(after.xSpan, lessThan(before.xSpan));
        } else {
          expect(after.xMin, before.xMin);
          expect(after.xMax, before.xMax);
        }
        if (enabled.$2) {
          expect(after.ySpan, lessThan(before.ySpan));
        } else {
          expect(after.yMin, before.yMin);
          expect(after.yMax, before.yMax);
        }
        expect(find.text('View All'), findsNothing);
        controller.dispose();
      },
    );
  }

  testWidgets('cancelled right drag ends zoom without opening the menu', (
    tester,
  ) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );
    final size = tester.getSize(interaction);
    final drag = await tester.startGesture(
      tester.getCenter(interaction),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await drag.moveBy(const Offset(30, -30));
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(find.text('View All'), findsNothing);

    final beforePan = telemetryViewport(controller, size);
    final pan = await tester.startGesture(
      tester.getCenter(interaction),
      kind: PointerDeviceKind.mouse,
    );
    await pan.moveBy(const Offset(20, 20));
    await pan.up();
    await tester.pump();
    final afterPan = telemetryViewport(controller, size);
    expect(afterPan.xSpan, closeTo(beforePan.xSpan, 1e-9));
    expect(afterPan.ySpan, closeTo(beforePan.ySpan, 1e-9));
    expect(afterPan.xMin, lessThan(beforePan.xMin));
    expect(afterPan.yMin, greaterThan(beforePan.yMin));
    expect(find.text('View All'), findsNothing);
    controller.dispose();
  });

  testWidgets('wheel zoom still scales both axes', (tester) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );
    final size = tester.getSize(interaction);
    final before = telemetryViewport(controller, size);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(interaction),
        scrollDelta: const Offset(0, -40),
      ),
    );
    await tester.pump();
    final after = telemetryViewport(controller, size);
    expect(after.xSpan, lessThan(before.xSpan));
    expect(after.ySpan, lessThan(before.ySpan));
    controller.dispose();
  });

  testWidgets('touch long press keeps the touch-friendly menu', (tester) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );

    final touch = await tester.startGesture(
      tester.getCenter(interaction),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('显示全部'), findsOneWidget);
    expect(find.text('跟随最新'), findsOneWidget);
    expect(find.text('X 轴详细设置…'), findsOneWidget);
    expect(find.text('Y 轴详细设置…'), findsOneWidget);
    expect(find.text('View All'), findsNothing);

    await touch.up();
    controller.dispose();
  });

  testWidgets('desktop one-button mode performs rectangle zoom', (
    tester,
  ) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );
    final center = tester.getCenter(interaction);
    final rightClick = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 Button'));
    await tester.pumpAndSettle();

    final before = telemetryViewport(controller, tester.getSize(interaction));
    final zoom = await tester.startGesture(
      center - const Offset(100, 70),
      kind: PointerDeviceKind.mouse,
    );
    await zoom.moveTo(center + const Offset(100, 70));
    await zoom.up();
    await tester.pump();
    final after = telemetryViewport(controller, tester.getSize(interaction));

    expect(controller.followLatest, isFalse);
    expect(after.xSpan, lessThan(before.xSpan));
    expect(after.ySpan, lessThan(before.ySpan));

    final rightDrag = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightDrag.moveBy(const Offset(20, -20));
    await rightDrag.up();
    await tester.pumpAndSettle();
    final afterRightDrag = telemetryViewport(
      controller,
      tester.getSize(interaction),
    );
    expect(afterRightDrag.xSpan, lessThan(after.xSpan));
    expect(afterRightDrag.ySpan, lessThan(after.ySpan));
    expect(find.text('View All'), findsNothing);
    controller.dispose();
  });

  testWidgets('desktop context menu closes when the plot is clicked', (
    tester,
  ) async {
    final controller = await pumpChart(tester);
    final interaction = find.byKey(
      const ValueKey('telemetry-chart-interaction'),
    );
    final chartRect = tester.getRect(interaction);
    final rightClick = await tester.startGesture(
      chartRect.center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(find.text('View All'), findsOneWidget);

    final dismissClick = await tester.startGesture(
      chartRect.topRight + const Offset(-20, 20),
      kind: PointerDeviceKind.mouse,
    );
    await dismissClick.up();
    await tester.pumpAndSettle();

    expect(find.text('View All'), findsNothing);
    expect(timeDilation, 1);
    controller.dispose();
  });
}
