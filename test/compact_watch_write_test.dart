import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

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
    testWidgets('$mode empty editors stay quiet during live sampling', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final controller = session.controller;
      final watch = controller.watches.first;
      final key = watch.symbol.key;
      final input = find.byKey(ValueKey('compact-watch-input-$key'));
      final write = find.byKey(ValueKey('compact-watch-write-$key'));
      final initialValue = watch.value;

      final group = find.byKey(ValueKey('compact-watch-write-group-$key'));
      final height = TalUiTheme(inputMode: mode).controlHeight;
      expect(tester.getSize(group).height, height);
      expect(tester.getSize(input).height, height);
      expect(tester.getSize(write).height, height);
      expect(tester.getSize(input).width, 121);
      final selector = find.byKey(ValueKey('watch-read-mode-$key'));
      expect(tester.getSize(selector).height, height);
      expect(tester.widget<TalDropdown>(selector).subtle, isTrue);
      expect(
        tester.getTopLeft(selector).dy,
        lessThan(tester.getTopLeft(group).dy),
      );
      expect(find.text('变量详情'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.widget<TalButton>(write).onPressed, isNull);

      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.widget<TalButton>(write).variant,
          TalButtonVariant.text,
          reason:
              'Automatic readback must not change the button style ($frame).',
        );
      }
      expect(watch.value, isNot(initialValue));
      expect(controller.watchInputDrafts.containsKey(key), isFalse);

      // Merely focusing an empty editor does not create a write draft.
      await tester.tap(input);
      await tester.pump();
      final focusedText = tester.widget<TextField>(input).controller!.text;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<TextField>(input).controller!.text, focusedText);
        expect(tester.widget<TalButton>(write).variant, TalButtonVariant.text);
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
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.text);
      expect(
        find.descendant(of: write, matching: find.text('已写入')),
        findsOneWidget,
      );
      expect(tester.widget<TalButton>(write).onPressed, isNotNull);

      // Matching readback does not suppress another explicit write command.
      await tester.tap(write);
      await tester.pump(const Duration(milliseconds: 100));
      expect(writeCount(), 2);
      expect(watch.value, 42.5);
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.text);

      await tester.enterText(input, '');
      await tester.pump();
      expect(tester.widget<TalButton>(write).variant, TalButtonVariant.text);
      expect(tester.widget<TalButton>(write).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });
    testWidgets('$mode failed writes keep drafts and Escape clears them', (
      tester,
    ) async {
      final session = await mountWatchPanel(tester, mode);
      final controller = session.controller;
      final key = controller.watches.first.symbol.key;
      final input = find.byKey(ValueKey('compact-watch-input-$key'));
      final write = find.byKey(ValueKey('compact-watch-write-$key'));
      await tester.enterText(input, 'bad-value');
      await tester.pump();
      await tester.tap(write);
      await tester.pump();
      expect(
        find.byKey(ValueKey('compact-watch-write-error-$key')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(input).controller!.text, 'bad-value');
      expect(controller.watchInputDrafts[key], 'bad-value');
      expect(
        find.descendant(of: write, matching: find.text('已写入')),
        findsNothing,
      );
      await tester.tap(input);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(
        find.byKey(ValueKey('compact-watch-write-error-$key')),
        findsNothing,
      );
      expect(tester.widget<TalButton>(write).onPressed, isNull);
      await tester.enterText(input, '3.5');
      controller.applySnapshot({'connectionStatus': 'disconnected'});
      await tester.pump();
      expect(tester.widget<TalButton>(write).onPressed, isNull);
      expect(controller.watchInputDrafts[key], '3.5');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    for (final width in [240.0, 280.0, 320.0]) {
      testWidgets('$mode watch layout fits a $width dock', (tester) async {
        final session = await mountWatchPanel(tester, mode, width: width);
        await tester.pump();
        final key = session.controller.watches.first.symbol.key;
        final group = find.byKey(ValueKey('compact-watch-write-group-$key'));
        final row = find.byKey(ValueKey('compact-watch-$key'));
        expect(
          tester.getRect(group).right,
          lessThanOrEqualTo(tester.getRect(row).right),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      });
    }
  }
  testWidgets(
    'write feedback waits for acknowledgement and ignores a superseded draft',
    (tester) async {
      final pending = Completer<void>();
      final controller = TakeALookController(
        backendCommand: (command, args) async {
          if (command == ControllerCommand.writeWatch) await pending.future;
        },
      )..loadDemoSymbols();
      controller.selectSymbols([controller.symbols.first.key]);
      controller.addSelectedToWatch();
      controller.applySnapshot({'connectionStatus': 'connected'});
      final key = controller.watches.single.symbol.key;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 400,
              child: buildWorkspacePanelBody(
                WorkspacePanelId.watch,
                controller,
                workbench: true,
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(ValueKey('compact-watch-input-$key'));
      final write = find.byKey(ValueKey('compact-watch-write-$key'));
      await tester.enterText(input, '5');
      await tester.pump();
      await tester.tap(write);
      await tester.pump();
      expect(
        find.descendant(of: write, matching: find.text('写入中')),
        findsOneWidget,
      );
      expect(tester.widget<TalButton>(write).onPressed, isNull);
      await tester.enterText(input, '6');
      pending.complete();
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '6');
      expect(
        find.descendant(of: write, matching: find.text('已写入')),
        findsNothing,
      );
      expect(tester.widget<TalButton>(write).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  test('write failures are returned to local and detached callers', () async {
    final controller = TakeALookController(
      backendCommand: (command, args) async {
        if (command == ControllerCommand.writeWatch) {
          throw const BackendException('write_failed', '回读失败。');
        }
      },
    );
    addTearDown(controller.dispose);
    expect(await controller.writeWatch('key', '12'), isFalse);
    expect(controller.watchInputDrafts['key'], '12');
    await expectLater(
      controller.handleCommand(ControllerCommand.writeWatch, {
        'key': 'key',
        'value': '12',
      }),
      throwsStateError,
    );
  });
  const previewDirectory = String.fromEnvironment('TAL_WATCH_PREVIEW_DIR');
  if (previewDirectory.isNotEmpty) {
    testWidgets('render watch panel previews with production fonts', (
      tester,
    ) async {
      for (final font in [
        ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
        ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        final loader = FontLoader(font.$1)..addFont(rootBundle.load(font.$2));
        await loader.load();
      }
      for (final mode in TalInputMode.values) {
        final session = await mountWatchPanel(tester, mode, width: 392);
        final key = session.controller.watches.first.symbol.key;
        await tester.enterText(
          find.byKey(ValueKey('compact-watch-input-$key')),
          '1.5000',
        );
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('watch-preview-boundary')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(previewDirectory).createSync(recursive: true);
          File(
            '$previewDirectory/watch-panel-${mode.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      }
    });
  }
}
