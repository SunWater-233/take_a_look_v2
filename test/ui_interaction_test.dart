import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  testWidgets('actual input switches the theme without moving an active tap', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      TalInteractionRegion(
        initialMode: TalInputMode.mouseKeyboard,
        builder: (context, mode) => MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Center(
              child: TalButton(
                onPressed: () => presses++,
                child: const Text('操作'),
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byType(OutlinedButton);
    expect(tester.getSize(button).height, 32);
    final touch = await tester.startGesture(
      tester.getCenter(button),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(tester.getSize(button).height, 32);
    await touch.up();
    await tester.pumpAndSettle();
    expect(presses, 1);
    expect(tester.getSize(button).height, 48);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.getSize(button).height, 32);
    final pen = await tester.startGesture(
      tester.getCenter(button),
      kind: PointerDeviceKind.stylus,
    );
    await pen.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(button).height, 48);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    await mouse.moveTo(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.getSize(button).height, 32);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode dropdown fits near the bottom and supports keyboard selection',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 300));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var selected = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: SizedBox(
                  width: 160,
                  child: TalDropdown<int>(
                    value: selected,
                    values: List.generate(20, (index) => index),
                    label: (value) => '选项 $value',
                    onChanged: (value) => selected = value,
                  ),
                ),
              ),
            ),
          ),
        );
        final anchor = find.byKey(const ValueKey('compact-dropdown-选项 1'));
        expect(
          tester.getSize(anchor).height,
          mode == TalInputMode.touch ? 48 : 32,
        );
        await tester.tap(anchor);
        await tester.pumpAndSettle();
        final menu = find.byKey(const ValueKey('dropdown-menu-animation'));
        final menuRect = tester.getRect(menu);
        expect(menuRect.top, greaterThanOrEqualTo(0));
        expect(
          menuRect.bottom,
          lessThanOrEqualTo(tester.getTopLeft(anchor).dy),
        );
        expect(menuRect.right, lessThanOrEqualTo(420));
        final item = find.byKey(const ValueKey('dropdown-item-选项 1'));
        expect(
          tester.getSize(item).height,
          mode == TalInputMode.touch ? 48 : 32,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 2);
        expect(menu, findsNothing);
        await tester.tap(anchor);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(menu, findsNothing);
        expect(selected, 2);
      },
    );
  }

  testWidgets(
    'an open dropdown follows input changes without losing its menu',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        TalInteractionRegion(
          initialMode: TalInputMode.mouseKeyboard,
          builder: (context, mode) => MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 160,
                  child: TalDropdown<int>(
                    value: selected,
                    values: const [0, 1, 2],
                    label: (value) => '$value',
                    onChanged: (value) => selected = value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('compact-dropdown-0')));
      await tester.pumpAndSettle();
      final item = find.byKey(const ValueKey('dropdown-item-1'));
      expect(tester.getSize(item).height, 48);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.getSize(item).height, 32);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touch controls fit in every workspace panel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    for (final panel in WorkspacePanelId.values) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(panel),
          theme: buildTalTheme(inputMode: TalInputMode.touch),
          home: Scaffold(body: buildWorkspacePanel(panel, controller)),
        ),
      );
      // Realtime panels can keep scheduling frames while data is visible.
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: panel.name);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'desktop errors keep the workspace interactive and replace previous notices',
    (tester) async {
      final feedback = TalFeedbackController();
      addTearDown(feedback.dispose);
      late BuildContext workbench;
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Builder(
            builder: (context) {
              workbench = context;
              return Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: TalButton(
                    onPressed: () => presses++,
                    child: const Text('继续操作'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final barriersBeforeError = find.byType(ModalBarrier).evaluate().length;
      await feedback.showError(
        context: workbench,
        title: '连接失败',
        message: '未找到探针',
        details: 'USB 设备未连接',
      );
      await tester.pumpAndSettle();
      expect(find.byType(ModalBarrier), findsNWidgets(barriersBeforeError));
      await tester.tap(find.text('继续操作'));
      await tester.pumpAndSettle();
      expect(presses, 1);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('USB 设备未连接'), findsOneWidget);
      await feedback.showError(
        context: workbench,
        title: '读取失败',
        message: '读取超时',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tal-error-popup')), findsOneWidget);
      expect(find.text('连接失败'), findsNothing);
      expect(find.text('读取超时'), findsOneWidget);
      feedback.dispose();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tal-error-popup')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
