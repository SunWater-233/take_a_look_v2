import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

import 'watch_value_test_helpers.dart';

Future<UiTestSession> mountWatchPanel(
  WidgetTester tester,
  TalInputMode mode, {
  double width = 360,
}) async {
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
            width: width,
            height: 600,
            child: RepaintBoundary(
              key: const ValueKey('watch-preview-boundary'),
              child: buildWorkspacePanelBody(
                WorkspacePanelId.watch,
                session.controller,
                workbench: true,
              ),
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
    testWidgets(
      '$mode edits a current-value snapshot while telemetry continues',
      (tester) async {
        final session = await mountWatchPanel(tester, mode);
        final c = session.controller, watch = session.controller.watches.first;
        final key = watch.symbol.key;
        expect(find.byKey(ValueKey('compact-watch-input-$key')), findsNothing);
        expect(find.text('输入新值'), findsNothing);
        expect(find.byKey(ValueKey('compact-watch-write-$key')), findsNothing);
        final input = await editWatchValue(tester, key);
        expect(input, findsOneWidget);
        final field = tester.widget<TextField>(input);
        expect(field.controller!.selection.baseOffset, 0);
        expect(
          field.controller!.selection.extentOffset,
          field.controller!.text.length,
        );
        final initialText = field.controller!.text;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tester.widget<TextField>(input).controller!.text, initialText);
        expect(c.watchInputDrafts.containsKey(key), isFalse);
        await tester.enterText(input, '42.5');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(const Duration(milliseconds: 100));
        expect(input, findsNothing);
        expect(watch.value, 42.5);
        expect(c.watchInputDrafts.containsKey(key), isFalse);
        expect(
          c.logs.where((e) => e.message == '模拟写入 ${watch.symbol.name} = 42.5。'),
          hasLength(1),
        );
        // Reopening uses the latest readback and permits an explicit equal-value write.
        final again = await editWatchValue(tester, key);
        expect(tester.widget<TextField>(again).controller!.text, '42.5000000');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          c.logs.where((e) => e.message == '模拟写入 ${watch.symbol.name} = 42.5。'),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      },
    );

    testWidgets('$mode Escape cancels and blur never writes', (tester) async {
      final session = await mountWatchPanel(tester, mode);
      final c = session.controller,
          key = session.controller.watches.first.symbol.key;
      var input = await editWatchValue(tester, key);
      await tester.enterText(input, '123');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(input, findsNothing);
      expect(c.watchInputDrafts.containsKey(key), isFalse);
      input = await editWatchValue(tester, key);
      await tester.enterText(input, '456');
      await tester.tap(find.byKey(const ValueKey('watch-member-search')));
      await tester.pump();
      expect(input, findsNothing);
      expect(c.watchInputDrafts[key], '456');
      expect(c.logs.where((e) => e.message.startsWith('模拟写入')), isEmpty);
      input = await editWatchValue(tester, key);
      expect(tester.widget<TextField>(input).controller!.text, '456');
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    testWidgets('$mode failed writes keep the inline draft for retry', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final key = session.controller.watches.first.symbol.key;
      final input = await editWatchValue(tester, key);
      await tester.enterText(input, 'bad-value');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        find.byKey(ValueKey('compact-watch-write-error-$key')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(input).controller!.text, 'bad-value');
      expect(session.controller.watchInputDrafts[key], 'bad-value');
      await tester.enterText(input, '3.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 100));
      expect(input, findsNothing);
      expect(session.controller.watches.first.value, 3.5);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    testWidgets('$mode pinned and ordinary cells share readback', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final c = session.controller,
          key = session.controller.watches.first.symbol.key;
      c.setWatchPinned(key, true);
      await tester.pump();
      final input = await editWatchValue(tester, key, pinned: true);
      await tester.enterText(input, '9.25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('pinned-watch-value-$key')))
            .data,
        startsWith('9.2500'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('compact-watch-value-$key')))
            .data,
        startsWith('9.2500'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    for (final width in [240.0, 280.0, 320.0]) {
      testWidgets('$mode inline editing fits a $width dock', (tester) async {
        final session = await mountWatchPanel(tester, mode, width: width);
        final key = session.controller.watches.first.symbol.key;
        final input = await editWatchValue(tester, key);
        final row = find.byKey(ValueKey('compact-watch-$key'));
        expect(
          tester.getRect(input).right,
          lessThanOrEqualTo(tester.getRect(row).right),
        );
        expect(
          tester.getSize(input).height,
          lessThanOrEqualTo(tester.getSize(row).height),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      });
    }
  }

  testWidgets(
    'Enter waits for acknowledgement, suppresses duplicates and preserves newer edits',
    (tester) async {
      final pending = Completer<void>();
      var writes = 0;
      final c = TakeALookController(
        backendCommand: (command, args) async {
          if (command == ControllerCommand.writeWatch) {
            writes++;
            await pending.future;
          }
        },
      )..loadDemoSymbols();
      c.selectSymbols([c.symbols.first.key]);
      c.addSelectedToWatch();
      c.applySnapshot({'connectionStatus': 'connected'});
      final key = c.watches.single.symbol.key;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: buildWorkspacePanelBody(
              WorkspacePanelId.watch,
              c,
              workbench: true,
            ),
          ),
        ),
      );
      final input = await editWatchValue(tester, key);
      await tester.enterText(input, '5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(input, findsOneWidget);
      expect(writes, 1);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(writes, 1);
      await tester.enterText(input, '6');
      pending.complete();
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '6');
      expect(c.watchInputDrafts[key], '6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes, 2);
      expect(input, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('read-only and disconnected variables never enter editing', (
    tester,
  ) async {
    final c = TakeALookController(backendCommand: (_, _) async {});

    c.applySnapshot({
      'connectionStatus': 'connected',
      'symbols': [
        {
          'key': 'read-only',
          'source': 'test.c',
          'name': 'constant',
          'address': 0x20000000,
          'type': 'float',
          'size': 4,
          'writable': false,
        },
      ],
    });
    c.selectSymbols(['read-only']);
    c.addSelectedToWatch();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: buildWorkspacePanelBody(
            WorkspacePanelId.watch,
            c,
            workbench: true,
          ),
        ),
      ),
    );
    expect(await editWatchValue(tester, 'read-only'), findsNothing);
    c.applySnapshot({
      'symbols': [for (final s in demoSymbols) s.toJson()],
      'watches': [],
    });
    c.selectSymbols([demoSymbols.first.key]);
    c.addSelectedToWatch();
    c.applySnapshot({'connectionStatus': 'disconnected'});
    await tester.pump();
    expect(await editWatchValue(tester, demoSymbols.first.key), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
