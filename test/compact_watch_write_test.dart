import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

Future<UiTestSession> mountWatchPanel(
  WidgetTester tester,
  TalInputMode mode,
) async {
  final directory = Directory.systemTemp.createTempSync('tal_watch_write_');
  final session = UiTestSession(
    sourcePath: 'test/fixtures/debug_source.c',
    recordingDirectory: directory,
  );
  addTearDown(() {
    session.dispose();
    directory.deleteSync(recursive: true);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(inputMode: mode),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            height: 600,
            child: buildWorkspacePanelBody(
              WorkspacePanelId.watch,
              session.controller,
              workbench: true,
            ),
          ),
        ),
      ),
    ),
  );
  return session;
}

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets('$mode write button stays filled during live sampling', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final controller = session.controller;
      final watch = controller.watches.first;
      final key = watch.symbol.key;
      final input = find.byKey(ValueKey('compact-watch-input-$key'));
      final write = find.byKey(ValueKey('compact-watch-write-$key'));
      final initialValue = watch.value;

      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.widget<TalButton>(write).variant,
          TalButtonVariant.filled,
          reason:
              'Automatic readback must not change the button style ($frame).',
        );
      }
      expect(watch.value, isNot(initialValue));
      expect(controller.watchInputDrafts.containsKey(key), isFalse);

      // Focusing the editor freezes its text without creating a write draft.
      await tester.tap(input);
      await tester.pump();
      final focusedText = tester.widget<TextField>(input).controller!.text;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<TextField>(input).controller!.text, focusedText);
        expect(
          tester.widget<TalButton>(write).variant,
          TalButtonVariant.filled,
        );
      }
      expect(controller.watchInputDrafts.containsKey(key), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    testWidgets('$mode preserves drafts and allows writing an equal value', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final controller = session.controller;
      final watch = controller.watches.first;
      final key = watch.symbol.key;
      final input = find.byKey(ValueKey('compact-watch-input-$key'));
      final write = find.byKey(ValueKey('compact-watch-write-$key'));

      await tester.enterText(input, '42.5');
      tester.widget<TextField>(input).focusNode!.unfocus();
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<TextField>(input).controller!.text, '42.5');
        expect(
          tester.widget<TalButton>(write).variant,
          TalButtonVariant.filled,
        );
      }
      expect(controller.watchInputDrafts[key], '42.5');
      final writeMessage = '模拟写入 ${watch.symbol.name} = 42.5。';
      int writeCount() => controller.logs
          .where((entry) => entry.message == writeMessage)
          .length;
      expect(writeCount(), 0);
      await tester.tap(write);
      await tester.pump(const Duration(milliseconds: 100));
      expect(watch.value, 42.5);
      expect(writeCount(), 1);
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.filled);
      expect(tester.widget<TalButton>(write).onPressed, isNotNull);

      // Matching readback does not suppress another explicit write command.
      await tester.tap(write);
      await tester.pump(const Duration(milliseconds: 100));
      expect(writeCount(), 2);
      expect(watch.value, 42.5);
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.filled);

      await tester.enterText(input, '');
      await tester.pump();
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.filled);
      expect(tester.widget<TalButton>(write).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });
  }
}
