import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';
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
