import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  test(
    'cancelled picker does not load and overlapping loads are rejected',
    () async {
      var calls = 0;
      var picks = 0;
      final operation = Completer<void>();
      final controller = TakeALookController(
        backendCommand: (_, _) {
          calls++;
          return operation.future;
        },
        symbolFilePicker: () async {
          picks++;
          return null;
        },
      );
      addTearDown(controller.dispose);
      await controller.chooseSymbolFile();
      expect(controller.symbolLoadProgress, isNull);
      expect(calls, 0);
      final loading = controller.loadSymbolsFromPath('motor.elf');
      await controller.loadSymbolsFromPath('second.axf');
      await controller.chooseSymbolFile();
      expect(calls, 1);
      expect(picks, 1);
      final id = controller.symbolLoadProgress!.loadId;
      controller.applyBackendEvent(BackendEventType.symbolLoadProgress, {
        'loadId': 'old-load',
        'phase': 'debug',
        'current': 1,
        'total': 2,
      });
      expect(controller.symbolLoadProgress!.phase, 'check');
      controller.applyBackendEvent(BackendEventType.symbolLoadProgress, {
        'loadId': id,
        'phase': 'debug',
        'current': 96,
        'total': 160,
      });
      expect(controller.symbolLoadProgress!.fraction, 0.6);
      operation.complete();
      await loading;
      expect(controller.isSymbolLoading, isFalse);
      controller.applyBackendEvent(BackendEventType.symbolLoadProgress, {
        'loadId': id,
        'phase': 'debug',
        'current': 1,
        'total': 2,
      });
      expect(controller.symbolLoadProgress!.status, SymbolLoadStatus.complete);
    },
  );

  test(
    'detached progress patches preserve data and ignore stale completion order',
    () async {
      final operation = Completer<void>();
      final source = TakeALookController(
        backendCommand: (_, _) => operation.future,
      );
      final replica = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(source.dispose);
      addTearDown(replica.dispose);
      replica.applySnapshot({
        'symbolFile': 'previous.elf',
        'symbols': [_symbol],
      });
      final loading = source.loadSymbolsFromPath('next.elf');
      final first = source.symbolLoadProgress!.toJson();
      replica.applySnapshot({'symbolLoad': first});
      expect(replica.symbols.single.name, 'counter');
      expect(replica.isSymbolLoading, isTrue);
      operation.complete();
      await loading;
      replica.applySnapshot(source.stateSnapshot());
      replica.applySnapshot({'symbolLoad': first});
      expect(replica.isSymbolLoading, isFalse);
    },
  );

  for (final code in [
    'symbol_load_failed',
    'symbol_load_timeout',
    'process_exited',
  ]) {
    test('$code ends loading and preserves the previous data', () async {
      final controller = TakeALookController(
        backendCommand: (_, _) async => throw BackendException(code, '读取失败'),
      );
      addTearDown(controller.dispose);
      controller.applySnapshot({
        'symbolFile': 'previous.elf',
        'symbols': [_symbol],
      });
      await controller.loadSymbolsFromPath('invalid.elf');
      expect(controller.isSymbolLoading, isFalse);
      expect(controller.symbolFile, 'previous.elf');
      expect(controller.symbols.single.name, 'counter');
      expect(controller.lastBackendError?['code'], code);
    });
  }

  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode progress is real, cannot dismiss, freezes mode and closes after success',
      (tester) async {
        final operation = Completer<void>();
        final controller = TakeALookController(
          backendCommand: (_, _) => operation.future,
        );
        final inputMode = ValueNotifier(mode);
        addTearDown(controller.dispose);
        addTearDown(inputMode.dispose);
        await _loadFontsForCapture();
        await tester.pumpWidget(_harness(controller, inputMode));
        final loading = controller.loadSymbolsFromPath(
          r'C:\firmware\motor.elf',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('正在加载 ELF'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          isNull,
        );
        controller.applySymbolLoadProgress({
          'loadId': controller.symbolLoadProgress!.loadId,
          'phase': 'debug',
          'current': 96,
          'total': 160,
        });
        await tester.pump();
        await tester.pump();
        expect(find.text('60%'), findsOneWidget);
        expect(find.text('已处理 96 / 160'), findsOneWidget);
        expect(find.textContaining('本阶段'), findsNothing);
        expect(find.textContaining('编译单元'), findsNothing);
        final indicator = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        );
        expect(indicator.value, 0.6);
        expect(indicator.minHeight, mode == TalInputMode.touch ? 8 : 6);
        await tester.pump(const Duration(milliseconds: 250));
        await _capture(tester, mode.name);
        inputMode.value = mode == TalInputMode.touch
            ? TalInputMode.mouseKeyboard
            : TalInputMode.touch;
        await tester.pump();
        expect(
          TalUiTheme.of(
            tester.element(find.byType(TalProgressDialog)),
          ).inputMode,
          mode,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.binding.handlePopRoute();
        await tester.tapAt(const Offset(2, 2));
        await tester.pump();
        expect(find.byType(TalProgressDialog), findsOneWidget);
        controller.applySnapshot({
          'symbolFile': 'motor.elf',
          'symbols': [_symbol],
        });
        operation.complete();
        await loading;
        await tester.pumpAndSettle();
        expect(find.byType(TalProgressDialog), findsNothing);
        expect(controller.symbols.single.name, 'counter');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$mode failure closes progress before adaptive error feedback',
      (tester) async {
        final operation = Completer<void>();
        final controller = TakeALookController(
          backendCommand: (_, _) => operation.future,
        );
        final inputMode = ValueNotifier(mode);
        addTearDown(controller.dispose);
        addTearDown(inputMode.dispose);
        await tester.pumpWidget(_harness(controller, inputMode));
        final loading = controller.loadSymbolsFromPath('broken.elf');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        operation.completeError(
          const BackendException('symbol_load_failed', 'ELF 文件无效'),
        );
        await loading;
        await tester.pumpAndSettle();
        expect(find.byType(TalProgressDialog), findsNothing);
        expect(find.text('ELF 文件无效'), findsOneWidget);
        if (mode == TalInputMode.touch) {
          expect(find.byType(AlertDialog), findsOneWidget);
          final button = find.widgetWithText(TextButton, '确定');
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          await tester.tap(button);
          await tester.pumpAndSettle();
        } else {
          expect(find.byKey(const ValueKey('tal-error-popup')), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('touch progress fits a narrow screen and long filename', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final operation = Completer<void>();
    final controller = TakeALookController(
      backendCommand: (_, _) => operation.future,
    );
    final mode = ValueNotifier(TalInputMode.touch);
    addTearDown(controller.dispose);
    addTearDown(mode.dispose);
    await tester.pumpWidget(_harness(controller, mode));
    final loading = controller.loadSymbolsFromPath(
      'motor_control_with_a_long_firmware_file_name.axf',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    expect(find.byType(TalProgressDialog), findsOneWidget);
    operation.complete();
    await loading;
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

const _symbol = {
  'key': '20000000:counter',
  'source': 'main.c',
  'name': 'counter',
  'address': 0x20000000,
  'type': 'uint32_t',
  'size': 4,
};

Widget _harness(
  TakeALookController controller,
  ValueNotifier<TalInputMode> mode,
) => RepaintBoundary(
  key: const ValueKey('progress-capture'),
  child: ValueListenableBuilder<TalInputMode>(
    valueListenable: mode,
    builder: (context, value, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTalTheme(inputMode: value),
      themeAnimationDuration: Duration.zero,
      home: WorkbenchFeedback(
        controller: controller,
        child: const Scaffold(body: Center(child: Text('工作区'))),
      ),
    ),
  ),
);

Future<void> _loadFontsForCapture() async {
  if (Platform.environment['TAL_CAPTURE_PROGRESS'] != '1') return;
  final latin = FontLoader('JetBrains Mono')
    ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'));
  final chinese = FontLoader('MiSans')
    ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'));
  await Future.wait([latin.load(), chinese.load()]);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['TAL_CAPTURE_PROGRESS'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('progress-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/progress-dialog-captures')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
