import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  Future<TakeALookController> pumpWatchTable(WidgetTester tester) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 520,
            child: buildWorkspacePanel(WorkspacePanelId.watch, controller),
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  testWidgets('watch header supports Shift selection and context visibility', (
    tester,
  ) async {
    final controller = await pumpWatchTable(tester);

    await tester.tap(find.text('类型'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('当前值'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await rightClick(tester, find.text('当前值'));

    expect(find.text('隐藏所选列（2）'), findsOneWidget);
    expect(find.text('显示全列'), findsOneWidget);
    final desktopItem = tester.widget<PopupMenuItem<String>>(
      find
          .ancestor(
            of: find.text('显示全列'),
            matching: find.byType(PopupMenuItem<String>),
          )
          .first,
    );
    expect(desktopItem.height, 32);
    final popupShape = Theme.of(
      tester.element(find.text('显示全列')),
    ).popupMenuTheme.shape;
    expect(
      (popupShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(8),
    );
    await tester.tap(find.text('隐藏所选列（2）'));
    await tester.pumpAndSettle();
    expect(find.text('类型'), findsNothing);
    expect(find.text('当前值'), findsNothing);

    await rightClick(tester, find.text('变量'));
    await tester.tap(find.text('显示全列'));
    await tester.pumpAndSettle();
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('当前值'), findsOneWidget);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('watch header menu uses larger touch targets on long press', (
    tester,
  ) async {
    final controller = await pumpWatchTable(tester);

    Future<void> longPress(Finder finder) async {
      final gesture = await tester.startGesture(
        tester.getCenter(finder),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await longPress(find.text('类型'));
    expect(find.text('隐藏该列'), findsOneWidget);
    final headerItem = tester.widget<PopupMenuItem<String>>(
      find
          .ancestor(
            of: find.text('隐藏该列'),
            matching: find.byType(PopupMenuItem<String>),
          )
          .first,
    );
    expect(headerItem.height, 48);
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('watch row menus honor Ctrl Shift and Ctrl+A selections', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final controller = await pumpWatchTable(tester);

    await tester.tap(find.text('iq_ref'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('speed_rpm'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await rightClick(tester, find.text('speed_rpm'));
    expect(find.text('复制所选命令名（3）'), findsOneWidget);
    await tester.tap(find.text('复制所选命令名（3）'));
    await tester.pumpAndSettle();
    expect(copiedText, 'iq_ref\nid_ref\nspeed_rpm');

    await tester.tap(find.text('iq_ref'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('speed_rpm'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await rightClick(tester, find.text('iq_ref'));
    expect(find.text('仅绘制所选变量（2）'), findsOneWidget);
    await tester.tap(find.text('仅绘制所选变量（2）'));
    await tester.pumpAndSettle();
    expect(controller.watches.map((watch) => watch.plotted), <bool>[
      true,
      false,
      true,
    ]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await rightClick(tester, find.text('id_ref'));
    expect(find.text('移除所选变量（3）'), findsOneWidget);
    await tester.tap(find.text('全部不绘制'));
    await tester.pumpAndSettle();
    expect(controller.watches.every((watch) => !watch.plotted), isTrue);

    await rightClick(tester, find.text('id_ref'));
    await tester.tap(find.text('反转所选变量绘制状态'));
    await tester.pumpAndSettle();
    expect(controller.watches.every((watch) => watch.plotted), isTrue);

    await rightClick(tester, find.text('id_ref'));
    await tester.tap(find.text('为所选变量设置绘制颜色（3）'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('watch-color-preset-${TalColors.blue.toARGB32()}')),
    );
    await tester.tap(find.byKey(const ValueKey('watch-color-confirm')));
    await tester.pumpAndSettle();
    expect(
      controller.watches.every((watch) => watch.color == TalColors.blue),
      isTrue,
    );

    await tester.tap(find.text('id_ref'));
    await rightClick(tester, find.byType(Checkbox).at(1));
    expect(find.text('仅绘制该栏'), findsOneWidget);
    await tester.tap(find.text('仅绘制该栏'));
    await tester.pumpAndSettle();
    expect(controller.watches.map((watch) => watch.plotted), <bool>[
      false,
      true,
      false,
    ]);

    await rightClick(tester, find.byType(Checkbox).at(1));
    await tester.tap(find.text('全部绘制'));
    await tester.pumpAndSettle();
    expect(controller.watches.every((watch) => watch.plotted), isTrue);

    await rightClick(tester, find.text('id_ref'));
    await tester.tap(find.text('移除该变量'));
    await tester.pumpAndSettle();
    expect(controller.watches.map((watch) => watch.symbol.name), [
      'iq_ref',
      'speed_rpm',
    ]);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
