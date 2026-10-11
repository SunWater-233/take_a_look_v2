import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_app.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode test toolbar drives the real workbench and progress feedback',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final directory = Directory.systemTemp.createTempSync('tal_ui_test_');
        final source = File('${directory.path}/motor_control.c')
          ..writeAsStringSync(UiTestSession.sourceText);
        final lab = UiTestSession(
          sourcePath: source.path,
          recordingDirectory: Directory('${directory.path}/recordings'),
          stepDelay: const Duration(milliseconds: 30),
        );
        final sync = MainWindowSync(lab.controller);
        addTearDown(() async {
          await sync.dispose();
          lab.dispose();
          directory.deleteSync(recursive: true);
        });
        Future<void> finishMenuAnimation() async {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: MainWorkbench(
              controller: lab.controller,
              windowSync: sync,
              layoutFile: File('${directory.path}/layout.json'),
              toolbar: UiTestToolbar(
                session: lab,
                inputMode: mode,
                onInputMode: (_) {},
                onExport: () {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('UI 测试版 · 模拟数据'), findsOneWidget);
        await tester.tap(find.text('实时波形'));
        await finishMenuAnimation();
        await tester.tap(find.text('空白状态'));
        await finishMenuAnimation();
        expect(lab.controller.watches, isEmpty);
        await tester.tap(find.text('空白状态'));
        await finishMenuAnimation();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await finishMenuAnimation();
        expect(lab.controller.watches.length, 6);
        await tester.tap(find.text('加载失败'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(TalProgressDialog), findsOneWidget);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          lab.controller.symbolLoadProgress!.status,
          SymbolLoadStatus.failed,
        );
        expect(find.byType(TalProgressDialog), findsNothing);
        expect(find.textContaining('模拟符号加载失败。'), findsWidgets);
        expect(lab.controller.watches.length, 6);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
        lab.dispose();
      },
    );
  }
}
