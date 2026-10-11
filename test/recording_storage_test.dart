import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/telemetry/raw_recording.dart';
import 'package:take_a_look_v2/src/telemetry/recording_storage.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

const _noticeKey = ValueKey('tal-notice-popup');
const _limit = RecordingStorage.warningThresholdBytes;

void main() {
  test(
    'scan counts all nested records without changing their contents',
    () async {
      final root = _temporaryDirectory();
      final recordings = Directory('${root.path}/recordings');
      final nested = Directory('${recordings.path}/imported/old-session')
        ..createSync(recursive: true);
      final first = File('${recordings.path}/samples.talraw')
        ..writeAsStringSync('原始记录');
      final second = File('${nested.path}/samples.talraw')
        ..writeAsBytesSync(List.filled(4096, 42));
      final metadata = File('${nested.path}/metadata.json')
        ..writeAsStringSync('{}');
      File('${root.path}/outside.talraw').writeAsStringSync('not a recording');
      final storage = RecordingStorage(directory: recordings);
      final expected =
          first.lengthSync() + second.lengthSync() + metadata.lengthSync();
      expect(await storage.totalBytes(), expected);
      expect(first.readAsStringSync(), '原始记录');
      expect(second.readAsBytesSync(), everyElement(42));
      expect(await storage.totalBytes(), expected);
    },
  );

  test(
    'missing recording directory is empty and is not created by scanning',
    () async {
      final missing = Directory('${_temporaryDirectory().path}/missing');
      expect(await RecordingStorage(directory: missing).totalBytes(), 0);
      expect(missing.existsSync(), isFalse);
      expect(
        RecordingStorage().directory.path,
        RawSampleRecording.defaultDirectory.path,
      );
      final configured = Platform.environment['TAL_RECORDINGS_DIR'];
      if (configured != null && configured.isNotEmpty) {
        expect(RawSampleRecording.defaultDirectory.path, configured);
      } else {
        expect(
          RawSampleRecording.defaultDirectory.parent.absolute.path,
          File(Platform.resolvedExecutable).parent.absolute.path,
        );
      }
    },
  );

  for (final bytes in [0, _limit - 1, _limit, _limit + 1]) {
    testWidgets('startup threshold is strictly greater than 500 MB: $bytes', (
      tester,
    ) async {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(controller.dispose);
      final storage = _FakeStorage(bytes: bytes);
      await tester.pumpWidget(_harness(controller, storage));
      await tester.pumpAndSettle();
      expect(
        find.byKey(_noticeKey),
        bytes > _limit ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(_harness(controller, storage));
      await tester.pumpAndSettle();
      expect(storage.scans, 1);
      expect(storage.opens, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode notice slides in at bottom right and its body opens the folder',
      (tester) async {
        final controller = TakeALookController(backendCommand: (_, _) async {});
        addTearDown(controller.dispose);
        final storage = _FakeStorage();
        var presses = 0;
        await tester.pumpWidget(
          _harness(
            controller,
            storage,
            mode: mode,
            onContinue: () => presses++,
          ),
        );
        await tester.pump();
        await tester.pump();
        final entering = tester.getRect(find.byKey(_noticeKey));
        await tester.pumpAndSettle();
        final settled = tester.getRect(find.byKey(_noticeKey));
        expect(entering.left, greaterThan(settled.left));
        expect(settled.right, lessThanOrEqualTo(800));
        expect(settled.bottom, lessThanOrEqualTo(600));
        expect(settled.center.dx, greaterThan(400));
        expect(settled.center.dy, greaterThan(300));
        expect(find.byType(TalDialog), findsNothing);
        await tester.tap(find.text('继续操作'));
        await tester.pumpAndSettle();
        expect(presses, 1);
        await tester.tap(find.textContaining('已保存的记录共'));
        await tester.pumpAndSettle();
        expect(storage.opens, 1);
        expect(find.byKey(_noticeKey), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'open button ignores repeated clicks while the file manager is launching',
    (tester) async {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(controller.dispose);
      final gate = Completer<void>();
      final storage = _FakeStorage(openGate: gate);
      await tester.pumpWidget(_harness(controller, storage));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开记录文件夹'));
      await tester.tap(find.text('打开记录文件夹'));
      await tester.pump();
      expect(storage.opens, 1);
      expect(find.text('正在打开…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_noticeKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dismissal does not open the folder or repeat after a rebuild', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    final storage = _FakeStorage();
    await tester.pumpWidget(_harness(controller, storage));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_harness(controller, storage));
    await tester.pumpAndSettle();
    expect(find.byKey(_noticeKey), findsNothing);
    expect(storage.scans, 1);
    expect(storage.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup errors stay visible before the cleanup reminder', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.applyBackendEvent(BackendEventType.error, {
      'code': 'startup_failed',
      'message': '连接测试错误',
    });
    await tester.pumpWidget(_harness(controller, _FakeStorage()));
    await tester.pumpAndSettle();
    expect(find.text('连接测试错误'), findsOneWidget);
    expect(find.byKey(_noticeKey), findsNothing);
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tal-error-popup')), findsNothing);
    expect(find.byKey(_noticeKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late scan results are ignored after the window closes', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    final gate = Completer<int>();
    await tester.pumpWidget(_harness(controller, _FakeStorage(scanGate: gate)));
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(_limit + 1);
    await tester.pumpAndSettle();
    expect(find.byKey(_noticeKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scan failure is logged and folder launch failure shows its path',
    (tester) async {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(controller.dispose);
      final scanError = _FakeStorage(
        scanError: const FileSystemException('access denied'),
      );
      await tester.pumpWidget(_harness(controller, scanError));
      await tester.pumpAndSettle();
      expect(find.byKey(_noticeKey), findsNothing);
      expect(
        controller.logs.any((log) => log.message.contains('检查记录文件夹大小失败')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      final openError = _FakeStorage(
        openError: const ProcessException('explorer.exe', [], 'unavailable'),
      );
      await tester.pumpWidget(_harness(controller, openError));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开记录文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开记录文件夹'), findsOneWidget);
      expect(find.text('请手动打开：${openError.directory.path}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Directory _temporaryDirectory() {
  final parent = Directory(
    '${Directory.current.path}/build/recording_storage_test',
  )..createSync(recursive: true);
  final directory = parent.createTempSync('scan-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

Widget _harness(
  TakeALookController controller,
  RecordingStorage storage, {
  TalInputMode mode = TalInputMode.mouseKeyboard,
  VoidCallback? onContinue,
}) => MaterialApp(
  theme: buildTalTheme(inputMode: mode),
  home: WorkbenchFeedback(
    controller: controller,
    recordingStorage: storage,
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: TalButton(
          onPressed: onContinue ?? () {},
          child: const Text('继续操作'),
        ),
      ),
    ),
  ),
);

class _FakeStorage extends RecordingStorage {
  _FakeStorage({
    this.bytes = _limit + RecordingStorage.bytesPerMb,
    this.scanGate,
    this.openGate,
    this.scanError,
    this.openError,
  }) : super(directory: Directory(r'D:\Portable App\recordings'));

  final int bytes;
  final Completer<int>? scanGate;
  final Completer<void>? openGate;
  final Object? scanError;
  final Object? openError;
  int scans = 0;
  int opens = 0;

  @override
  Future<int> totalBytes() async {
    scans++;
    if (scanError != null) throw scanError!;
    return scanGate?.future ?? bytes;
  }

  @override
  Future<void> openDirectory() async {
    opens++;
    if (openError != null) throw openError!;
    await openGate?.future;
  }
}
