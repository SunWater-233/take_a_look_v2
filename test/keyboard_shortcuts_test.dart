import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/keyboard_shortcuts.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';

Future<void> command(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool meta = false,
  PhysicalKeyboardKey? physicalKey,
}) async {
  final modifier = meta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key, physicalKey: physicalKey);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  late TakeALookController controller;
  late MainWindowSync windowSync;

  setUp(() {
    controller = TakeALookController();
    windowSync = MainWindowSync(controller);
  });

  tearDown(() async {
    await windowSync.dispose();
    controller.dispose();
  });

  Future<void> pumpWorkbench(WidgetTester tester, {File? layoutFile}) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: MainWorkbench(
          controller: controller,
          windowSync: windowSync,
          layoutFile: layoutFile,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('workbench-resource-toggle')));
    await tester.pumpAndSettle();
  }

  Future<void> finishSourceRead(WidgetTester tester) async {
    for (
      var attempt = 0;
      attempt < 50 &&
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  testWidgets(
    'window shortcuts work without clicking and while a text field is focused',
    (tester) async {
      late Directory temporary;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp(
          'take_a_look_shortcuts_',
        );
      });
      addTearDown(() => temporary.delete(recursive: true));
      final layout = File('${temporary.path}/layout.json');
      controller.setUiScale(1.45);
      await pumpWorkbench(tester, layoutFile: layout);
      FocusManager.instance.rootScope.requestFocus();
      await tester.pump();
      await command(tester, LogicalKeyboardKey.digit0);
      expect(controller.uiScale, 1);

      final search = find.byKey(const ValueKey('symbol-search-field'));
      await tester.enterText(search, 'motor_controller');
      controller.setUiScale(1.25);
      await command(tester, LogicalKeyboardKey.digit0, meta: true);
      expect(controller.uiScale, 1);
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
      expect(
        tester.widget<TextField>(search).controller!.text,
        'motor_controller',
      );

      await command(
        tester,
        LogicalKeyboardKey.keyQ,
        physicalKey: PhysicalKeyboardKey.keyS,
        shift: true,
      );
      for (
        var attempt = 0;
        attempt < 50 &&
            !controller.logs.any((entry) => entry.message == '工作区布局已保存。');
        attempt += 1
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(layout.existsSync(), isTrue);
      expect(
        controller.logs.any((entry) => entry.message == '工作区布局已保存。'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source shortcuts survive tab switches, cleared focus and popup dismissal',
    (tester) async {
      controller.applyDebugState({
        'sourceFiles': ['Z:/firmware/main.c'],
      });
      await pumpWorkbench(tester);
      await tester.enterText(
        find.byKey(const ValueKey('symbol-search-field')),
        'main',
      );
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pump();
      await finishSourceRead(tester);
      await command(tester, LogicalKeyboardKey.keyF);
      final search = find.byKey(const ValueKey('source-search-field'));
      expect(search, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      FocusManager.instance.rootScope.requestFocus();
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(search, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('source-file-menu')));
      await tester.pumpAndSettle();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(search, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(search, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('panel-tab-plot')));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(search, findsNothing);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(search, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'visible source commands work after using another panel without clicking a file tab',
    (tester) async {
      const path = 'Z:/firmware/main.c';
      controller.applyDebugState({
        'sourceFiles': [path],
      });
      await pumpWorkbench(tester);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pump();
      await finishSourceRead(tester);

      final variableSearch = find.byKey(const ValueKey('symbol-search-field'));
      await tester.tap(variableSearch);
      await tester.pump();
      expect(
        tester.widget<TextField>(variableSearch).focusNode!.hasFocus,
        isTrue,
      );
      await command(tester, LogicalKeyboardKey.keyF);
      final sourceSearch = find.byKey(const ValueKey('source-search-field'));
      expect(sourceSearch, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await tester.tap(variableSearch);
      await tester.pump();
      await command(
        tester,
        LogicalKeyboardKey.keyF,
        physicalKey: PhysicalKeyboardKey.keyQ,
      );
      expect(sourceSearch, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await tester.tap(variableSearch);
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyW);
      expect(find.byKey(const ValueKey('source-tab-$path')), findsNothing);
      expect(
        tester.widget<TextField>(variableSearch).focusNode!.hasFocus,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'modal dialogs and text editing take priority over workspace shortcuts',
    (tester) async {
      controller.applyDebugState({
        'sourceFiles': ['Z:/firmware/main.c'],
      });
      await pumpWorkbench(tester);
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pump();
      final editor = TextEditingController(text: 'dialog text');
      await finishSourceRead(tester);
      addTearDown(editor.dispose);
      final dialog = showDialog<void>(
        context: tester.element(find.byType(MainWorkbench)),
        builder: (_) => AlertDialog(
          content: TextField(
            key: const ValueKey('dialog-input'),
            controller: editor,
            autofocus: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.setUiScale(1.45);
      await command(tester, LogicalKeyboardKey.digit0);
      expect(controller.uiScale, 1.45);
      await command(tester, LogicalKeyboardKey.keyF);
      expect(find.byKey(const ValueKey('source-search-field')), findsNothing);
      await command(tester, LogicalKeyboardKey.keyA);
      expect(
        editor.selection,
        const TextSelection(baseOffset: 0, extentOffset: 11),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await dialog;
      await command(tester, LogicalKeyboardKey.keyF);
      expect(find.byKey(const ValueKey('source-search-field')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'watch select all works after header activation without taking text selection',
    (tester) async {
      controller.loadDemoSymbols();
      controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
      controller.addSelectedToWatch();
      final editor = TextEditingController(text: 'input text');
      addTearDown(editor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: WorkspaceKeyboardShortcuts(
            child: Scaffold(
              body: Column(
                children: [
                  TextField(
                    key: const ValueKey('outside-input'),
                    controller: editor,
                  ),
                  Expanded(
                    child: buildWorkspacePanel(
                      WorkspacePanelId.watch,
                      controller,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('实时调参'));
      await tester.pump();
      FocusManager.instance.rootScope.requestFocus();
      await tester.pump();
      await command(
        tester,
        LogicalKeyboardKey.keyQ,
        physicalKey: PhysicalKeyboardKey.keyA,
      );
      await tester.tap(find.text('id_ref'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('移除所选变量（3）'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('id_ref'));
      await tester.enterText(
        find.byKey(const ValueKey('outside-input')),
        'input text',
      );
      await command(tester, LogicalKeyboardKey.keyA);
      expect(
        editor.selection,
        const TextSelection(baseOffset: 0, extentOffset: 10),
      );
      await tester.tap(find.text('id_ref'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('移除所选变量（3）'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'detached source tabs restore shortcuts without an extra body click',
    (tester) async {
      controller.applyDebugState({
        'sourceFiles': ['Z:/firmware/main.c'],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: DetachedPanelWindow(
            controller: controller,
            panel: WorkspacePanelId.log,
            panels: const [WorkspacePanelId.log, WorkspacePanelId.sourceDebug],
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('panel-tab-sourceDebug')));
      await tester.pump();
      FocusManager.instance.rootScope.requestFocus();
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyF);
      expect(find.byKey(const ValueKey('source-search-field')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyW);
      expect(
        find.byKey(const ValueKey('source-tab-Z:/firmware/main.c')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
