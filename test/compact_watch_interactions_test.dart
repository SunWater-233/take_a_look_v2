import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/panels/watch_color_dialog.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

void main() {
  setUpAll(() async {
    for (final font in [
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
      ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
  });
  Future<TakeALookController> mount(
    WidgetTester tester, {
    TalInputMode mode = TalInputMode.mouseKeyboard,
    double width = 390,
  }) async {
    final controller = TakeALookController(backendCommand: (_, _) async {})
      ..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(2).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(inputMode: mode),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 580,
              child: RepaintBoundary(
                key: const ValueKey('preview'),
                child: buildWorkspacePanelBody(
                  WorkspacePanelId.watch,
                  controller,
                  workbench: true,
                ),
              ),
            ),
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

  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode full-height color strip opens picker and aligns with both row lines',
      (tester) async {
        final controller = await mount(tester, mode: mode);
        final key = controller.watches.first.symbol.key;
        final bar = find.byKey(ValueKey('compact-watch-color-bar-$key'));
        final strip = find.byKey(ValueKey('compact-watch-color-$key'));
        final row = find.byKey(ValueKey('compact-watch-$key'));
        final name = find.text('iq_ref');
        final group = find.byKey(ValueKey('compact-watch-write-group-$key'));
        final barRect = tester.getRect(bar), rowRect = tester.getRect(row);
        expect(barRect.width, 3);
        expect(barRect.height, greaterThan(50));
        expect((barRect.center.dy - rowRect.center.dy).abs(), lessThan(2));
        expect(barRect.left, lessThan(tester.getTopLeft(name).dx));
        expect(barRect.bottom, greaterThan(tester.getRect(group).center.dy));
        await tester.tap(strip);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.tap(strip);
        await tester.pumpAndSettle();
        expect(find.byType(WatchColorDialog), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('watch-color-hex')),
          '123ABC',
        );
        await tester.tap(find.byKey(const ValueKey('watch-color-confirm')));
        await tester.pumpAndSettle();
        expect(controller.watches.first.color, const Color(0xFF123ABC));
        expect(
          (tester.widget<DecoratedBox>(bar).decoration as BoxDecoration).color,
          const Color(0xFF123ABC),
        );

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/watch_interactions/${mode.name}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'row and strip context menus change color, visibility, delete and undo',
    (tester) async {
      final controller = await mount(tester);
      final key = controller.watches.first.symbol.key;
      await rightClick(
        tester,
        find.byKey(ValueKey('compact-watch-color-$key')),
      );
      expect(find.text('颜色调整'), findsOneWidget);
      await tester.tap(find.text('隐藏曲线'));
      await tester.pumpAndSettle();
      expect(controller.watches.first.plotted, isFalse);
      await rightClick(tester, find.text('iq_ref'));
      await tester.tap(find.text('显示曲线'));
      await tester.pumpAndSettle();
      expect(controller.watches.first.plotted, isTrue);
      await rightClick(tester, find.text('iq_ref'));
      await tester.tap(find.text('颜色调整'));
      await tester.pumpAndSettle();
      expect(find.byType(WatchColorDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('iq_ref'));
      await tester.tap(find.text('删除变量'));
      await tester.pumpAndSettle();
      expect(find.text('iq_ref'), findsNothing);
      await rightClick(tester, find.text('id_ref'));
      await tester.tap(find.text('撤回删除'));
      await tester.pumpAndSettle();
      expect(find.text('iq_ref'), findsOneWidget);
      expect(controller.watches.first.symbol.key, key);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Del and Ctrl+Z work on rows and leave text editing intact', (
    tester,
  ) async {
    final controller = await mount(tester);
    final key = controller.watches.first.symbol.key;
    await tester.tap(find.text('iq_ref'));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(find.text('iq_ref'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('iq_ref'), findsOneWidget);
    await tester.enterText(
      find.byKey(ValueKey('compact-watch-input-$key')),
      '123',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.watches, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Ctrl+Y redoes a deletion after Ctrl+Z restores it', (
    tester,
  ) async {
    final controller = await mount(tester);
    await tester.tap(find.text('iq_ref'));
    await tester.pump();
    controller.removeWatch(controller.watches.first.symbol.key);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.watches, hasLength(2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.watches, hasLength(1));
    controller.undoWatchDeletion();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Ctrl+Z restores the last removed row without a toolbar button', (
    tester,
  ) async {
    final controller = await mount(tester);
    await tester.tap(find.text('iq_ref'));
    await tester.pump();
    controller.removeWatches(
      controller.watches.map((watch) => watch.symbol.key),
    );
    await tester.pump();
    expect(controller.watches, isEmpty);
    expect(find.byKey(const ValueKey('compact-watch-undo')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.watches, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch long press opens adaptive row menu and supports undo', (
    tester,
  ) async {
    final controller = await mount(tester, mode: TalInputMode.touch);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('iq_ref')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('删除变量'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(item.height, 48);
    await tester.tap(find.text('删除变量'));
    await tester.pumpAndSettle();
    expect(controller.watches, hasLength(1));
    expect(find.byKey(const ValueKey('compact-watch-undo')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.watches, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
