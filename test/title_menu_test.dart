import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';

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

    final viewMenuAnchor = find.ancestor(
      of: find.text('视图'),
      matching: find.byType(MenuAnchor),
    );
    final viewMenuAnchorRect = tester.getRect(viewMenuAnchor);

    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    expect(find.text('UI 缩放'), findsOneWidget);
    expect(find.text('网格模式'), findsOneWidget);
    expect(find.text('组件组合'), findsOneWidget);
    expect(find.text('保存布局'), findsOneWidget);
    expect(find.text('恢复保存的布局'), findsOneWidget);
    expect(find.text('重置默认布局'), findsOneWidget);
    final titleBarRect = tester.getRect(find.byType(TalWindowTitleBar));
    final rootMenuFirstItem = find.ancestor(
      of: find.text('UI 缩放'),
      matching: find.byType(SubmenuButton),
    );
    expect(
      tester.getRect(rootMenuFirstItem).top,
      greaterThanOrEqualTo(titleBarRect.bottom),
    );
    expect(
      tester.getRect(rootMenuFirstItem).left,
      closeTo(viewMenuAnchorRect.left, 0.01),
    );

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

    final uiScaleButton = find.ancestor(
      of: find.text('UI 缩放'),
      matching: find.byType(SubmenuButton),
    );
    final uiScaleButtonRect = tester.getRect(uiScaleButton);

    await tester.tap(find.text('UI 缩放'));
    await tester.pumpAndSettle();

    expect(find.text('放大界面'), findsOneWidget);
    expect(find.text('缩小界面'), findsOneWidget);
    expect(find.text('重置界面缩放'), findsOneWidget);
    expect(find.text('85%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('125%'), findsOneWidget);
    expect(find.text('145%'), findsOneWidget);
    final zoomInItem = find.ancestor(
      of: find.text('放大界面'),
      matching: find.byType(MenuItemButton),
    );
    expect(
      tester.getRect(zoomInItem).left,
      greaterThanOrEqualTo(uiScaleButtonRect.right - 1),
    );

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

  testWidgets(
    'caption hover uses neutral surfaces and a readable orange close',
    (tester) async {
      await pumpTitleBar(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final label in ['最小化', '最大化/还原', '关闭']) {
        final button = find.widgetWithIcon(IconButton, switch (label) {
          '最小化' => Icons.remove,
          '关闭' => Icons.close,
          _ => Icons.crop_square,
        });
        await mouse.moveTo(tester.getCenter(button));
        await tester.pumpAndSettle();
        final material = tester.widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first,
        );
        expect(
          material.color,
          label == '关闭' ? TalColors.accent : TalColors.hover,
        );
        final icon = find.descendant(of: button, matching: find.byType(Icon));
        expect(
          IconTheme.of(tester.element(icon)).color,
          label == '关闭' ? TalColors.onAccent : TalColors.text,
        );
        expect(tester.getSize(button), const Size(44, 34));
      }
      await mouse.removePointer();
    },
  );

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

  testWidgets('RTT sampling checkbox toggles without closing its menu', (
    tester,
  ) async {
    await pumpTitleBar(tester);

    await tester.tap(find.text('实时变量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RTT设置'));
    await tester.pumpAndSettle();

    final rttSampling = find.byType(CheckboxMenuButton);
    expect(rttSampling, findsOneWidget);
    expect(tester.widget<CheckboxMenuButton>(rttSampling).value, isFalse);

    await tester.tap(rttSampling);
    await tester.pumpAndSettle();

    expect(controller.rttEnabled, isTrue);
    expect(rttSampling, findsOneWidget);
    expect(tester.widget<CheckboxMenuButton>(rttSampling).value, isTrue);
    expect(find.text('RTT协议'), findsOneWidget);
  });

  testWidgets('refresh-rate menu controls plotting instead of sampling', (
    tester,
  ) async {
    await pumpTitleBar(tester);

    await tester.tap(find.text('实时变量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新率设置'));
    await tester.pumpAndSettle();

    expect(find.text('标准模式（60 Hz）'), findsOneWidget);
    expect(find.text('高频模式（120 Hz）'), findsOneWidget);
    expect(find.text('实时模式（自适应）'), findsOneWidget);
    expect(find.text('50 Hz'), findsNothing);

    await tester.tap(find.text('高频模式（120 Hz）'));
    await tester.pumpAndSettle();
    expect(controller.displayRefreshMode, 'high');
    expect(controller.sampleRateHz, 50);
  });

  testWidgets('view menu refreshes panel visibility checks', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final windowSync = MainWindowSync(controller);
    addTearDown(windowSync.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: MainWorkbench(controller: controller, windowSync: windowSync),
      ),
    );

    Future<Finder> openHeaderMenuItem() async {
      await tester.tap(find.text('视图'));
      await tester.pumpAndSettle();
      return find.widgetWithText(MenuItemButton, WorkspacePanelId.watch.title);
    }

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('打开项目'), findsOneWidget);
    expect(find.text('保存项目'), findsOneWidget);
    expect(find.text('项目另存为'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    var headerItem = await openHeaderMenuItem();
    for (final removed in ['资源库', '输出', '专注视图']) {
      expect(find.widgetWithText(MenuItemButton, removed), findsNothing);
    }
    expect(
      find.descendant(of: headerItem, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    await tester.tap(headerItem);
    await tester.pumpAndSettle();

    headerItem = await openHeaderMenuItem();
    expect(
      find.descendant(of: headerItem, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  for (final mode in TalInputMode.values) {
    testWidgets('backend errors follow the $mode feedback policy', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final windowSync = MainWindowSync(controller);
      addTearDown(windowSync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: MainWorkbench(controller: controller, windowSync: windowSync),
        ),
      );

      final barriersBeforeError = find.byType(ModalBarrier).evaluate().length;
      controller.applyBackendEvent(BackendEventType.error, {
        'code': 'connect_failed',
        'message': '连接失败。',
        'details': '未找到探针',
      });
      await tester.pumpAndSettle();

      final touch = mode == TalInputMode.touch;
      expect(find.byType(AlertDialog), touch ? findsOneWidget : findsNothing);
      expect(find.text('pyOCD 连接失败'), findsOneWidget);
      if (!touch) {
        expect(find.byType(ModalBarrier), findsNWidgets(barriersBeforeError));
        await tester.tap(find.text('查看详情'));
        await tester.pumpAndSettle();
      }
      expect(
        find.descendant(
          of: touch
              ? find.byType(AlertDialog)
              : find.byKey(const ValueKey('tal-error-popup')),
          matching: find.textContaining('未找到探针'),
        ),
        findsOneWidget,
      );

      await tester.tap(touch ? find.text('确定') : find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('tal-error-popup')), findsNothing);
    });
  }
}
