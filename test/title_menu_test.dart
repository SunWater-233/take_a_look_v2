import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  late TakeALookController controller;

  setUp(() {
    controller = TakeALookController();
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pumpTitleBar(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(body: TalWindowTitleBar(controller: controller)),
      ),
    );
  }

  testWidgets('view menu preserves the original cascading layout', (
    tester,
  ) async {
    await pumpTitleBar(tester);

    expect(find.byTooltip('视图'), findsNothing);
    expect(find.byTooltip('实时变量'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('视图')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('视图'), findsOneWidget);
    expect(find.byTooltip('视图'), findsNothing);
    await mouse.moveTo(const Offset(800, 400));
    await tester.pump();
    expect(find.text('视图'), findsOneWidget);

    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    expect(find.text('UI 缩放'), findsOneWidget);
    expect(find.text('网格模式'), findsOneWidget);
    expect(find.text('组件组合'), findsOneWidget);
    expect(find.text('保存布局'), findsOneWidget);
    expect(find.text('恢复保存的布局'), findsOneWidget);
    expect(find.text('重置默认布局'), findsOneWidget);

    const panelLabels = [
      '主标题',
      '采样控制',
      '运行控制',
      '实时图表',
      '连接设置',
      '符号变量',
      '实时调参',
      '事件日志',
    ];
    var previousY = -1.0;
    for (final label in panelLabels) {
      final item = find.text(label);
      expect(item, findsOneWidget);
      final y = tester.getTopLeft(item).dy;
      expect(y, greaterThan(previousY));
      previousY = y;
    }

    await tester.tap(find.text('UI 缩放'));
    await tester.pumpAndSettle();

    expect(find.text('放大界面'), findsOneWidget);
    expect(find.text('缩小界面'), findsOneWidget);
    expect(find.text('重置界面缩放'), findsOneWidget);
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('125%'), findsOneWidget);
    expect(find.text('145%'), findsOneWidget);

    await tester.tap(find.text('125%'));
    await tester.pumpAndSettle();
    expect(controller.uiScale, 1.25);
  });

  testWidgets('window title bar matches the legacy dimensions and brand', (
    tester,
  ) async {
    await pumpTitleBar(tester);

    expect(tester.getSize(find.byType(TalWindowTitleBar)).height, 46);
    final brand = tester.widget<Text>(find.text('Take A Look'));
    expect(brand.style?.fontFamily, talBrandFontFamily);
    expect(brand.style?.fontSize, 18);
    expect(brand.style?.fontWeight, FontWeight.w800);
  });

  testWidgets('real-time variable menu keeps the three-level RTT menu', (
    tester,
  ) async {
    await pumpTitleBar(tester);

    await tester.tap(find.text('实时变量'));
    await tester.pumpAndSettle();

    expect(find.text('刷新率设置'), findsOneWidget);
    expect(find.text('RTT设置'), findsOneWidget);
    expect(find.text('导出原始采样 CSV'), findsOneWidget);

    await tester.tap(find.text('RTT设置'));
    await tester.pumpAndSettle();
    expect(find.text('RTT采样'), findsOneWidget);
    expect(find.text('RTT协议'), findsOneWidget);

    await tester.tap(find.text('RTT协议'));
    await tester.pumpAndSettle();
    expect(find.text('RTT-Normal'), findsOneWidget);
    expect(find.text('RTT-Plus'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });
}
