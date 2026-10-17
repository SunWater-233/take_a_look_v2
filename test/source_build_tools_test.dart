import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/source_tools.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

void main() {
  test(
    'async task failures report errors once and sync to detached windows',
    () {
      final controller = TakeALookController();
      final detached = TakeALookController();
      addTearDown(controller.dispose);
      addTearDown(detached.dispose);
      controller.applySourceTask({
        'id': 'download-1',
        'status': 'running',
        'phase': 'download',
      });
      expect(controller.lastBackendError, isNull);
      final failure = {
        'id': 'download-1',
        'status': 'failed',
        'phase': 'download',
        'message': '固件写后校验失败：地址 0x08000000',
      };
      controller.applyBackendEvent(BackendEventType.sourceTask, failure);
      final error = controller.lastBackendError;
      expect(error?['code'], 'source_task_failed');
      expect(error?['operation'], 'sourceTask');
      expect(error?['message'], failure['message']);
      final logCount = controller.logs.length;
      controller.applySourceTask(failure);
      expect(identical(error, controller.lastBackendError), isTrue);
      expect(controller.logs.length, logCount);
      detached.applySnapshot(controller.stateSnapshot());
      expect(detached.lastBackendError, error);
      expect(detached.sourceTask.status, 'failed');
      controller.applySourceTask({...failure, 'id': 'download-2'});
      expect(controller.logs.length, logCount + 1);
    },
  );

  test('rejected task starts preserve backend error details', () async {
    final controller = TakeALookController(
      backendCommand: (_, _) async => throw const BackendException(
        'firmware_missing',
        '下载文件不存在',
        'app.axf',
      ),
    );
    addTearDown(controller.dispose);
    await controller.startSourceTask('download');
    expect(controller.lastBackendError?['code'], 'firmware_missing');
    expect(controller.lastBackendError?['message'], '下载文件不存在');
    expect(controller.lastBackendError?['details'], 'app.axf');
  });

  testWidgets('download failures show feedback without an output panel', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: WorkbenchFeedback(
            controller: controller,
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    controller.applySourceTask({
      'id': 'download',
      'status': 'failed',
      'message': '固件写后校验失败',
    });
    await tester.pumpAndSettle();
    expect(find.text('编译 / 下载失败'), findsOneWidget);
    expect(find.text('固件写后校验失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('source task snapshots retain output and clearing across windows', () {
    final main = TakeALookController();
    final detached = TakeALookController();
    main.applyBackendEvent(BackendEventType.sourceTask, {
      'id': 'a',
      'status': 'running',
      'phase': 'build',
      'canCancel': true,
      'lines': [
        {'seq': 1, 'text': '编译输出', 'stream': 'stdout'},
      ],
    });
    detached.applySnapshot(main.stateSnapshot());
    expect(detached.sourceTask.running, isTrue);
    expect(detached.sourceTask.lines.single['text'], '编译输出');
    main.clearSourceOutput();
    main.applySourceTask({
      'id': 'a',
      'replaceOutput': true,
      'lines': [
        {'seq': 1, 'text': 'old'},
        {'seq': 2, 'text': 'new'},
      ],
    });
    expect(main.sourceTask.lines.single['text'], 'new');
    main.dispose();
    detached.dispose();
  });

  test('default shell matches the local platform', () {
    expect(
      SourceProjectConfig().shell,
      Platform.isWindows
          ? 'powershell'
          : Platform.isMacOS
          ? 'zsh'
          : 'bash',
    );
  });

  testWidgets('settings and build do not require loading an ELF first', (
    tester,
  ) async {
    final commands = <ControllerCommand>[];
    final controller = TakeALookController(
      backendCommand: (command, args) async {
        commands.add(command);
      },
    );
    controller.applySnapshot({
      'sourceProject': {
        'sourceRoot': Directory.current.path,
        'buildCommand': 'cmake --build build',
        'firmwarePath': '',
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildWorkspacePanelBody(
            WorkspacePanelId.sourceDebug,
            controller,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('source-build')));
    await tester.pump();
    expect(commands, contains(ControllerCommand.startSourceTask));
    await tester.tap(find.byKey(const ValueKey('source-project-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-project-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-project-shell')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('saving a picked firmware loads symbols into both panels', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'tal-project-symbols-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final firmware = File('${directory.path}/motor.axf')
      ..writeAsStringSync('fixture');
    final loaded = Completer<void>();
    final requests = <String>[];
    late final TakeALookController controller;
    controller = TakeALookController(
      symbolFilePicker: () async => firmware.path,
      backendCommand: (command, arguments) async {
        if (command == ControllerCommand.setSourceProject) {
          controller.applyBackendEvent(BackendEventType.state, {
            'sourceProject': arguments,
          });
        } else if (command == ControllerCommand.loadSymbols) {
          final path = (arguments! as Map)['path'] as String;
          requests.add(path);
          await loaded.future;
          controller.applyBackendEvent(BackendEventType.state, {
            'symbolFile': path,
            'symbols': [_projectSymbol],
            'debug': {
              'sourceRoot': directory.path,
              'sourceFiles': ['${directory.path}/motor.c'],
            },
          });
        }
      },
    );
    addTearDown(controller.dispose);
    controller.sourceProject.sourceRoot = directory.path;
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_projectSettingsHarness(controller));
    await tester.tap(find.byKey(const ValueKey('source-project-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('浏览固件文件'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);

    await tester.tap(find.byKey(const ValueKey('source-project-save')));
    for (var attempt = 0; attempt < 20 && requests.isEmpty; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(requests, hasLength(1));
    await tester.pump(const Duration(milliseconds: 350));
    expect(File(requests.single).absolute.uri, firmware.absolute.uri);
    expect(controller.isSymbolLoading, isTrue);
    expect(find.byKey(const ValueKey('source-project-save')), findsNothing);
    expect(find.text('正在加载 ELF'), findsOneWidget);
    expect(find.text('打开符号文件'), findsOneWidget);
    expect(find.text('符号文件已打开'), findsNothing);

    await tester.runAsync(() async {
      loaded.complete();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(controller.isSymbolLoading, isFalse);
    expect(find.text('正在加载 ELF'), findsNothing);
    expect(controller.symbols.single.name, 'counter');
    expect(controller.debugState.sourceFiles, ['${directory.path}/motor.c']);
    expect(find.text('符号文件已打开'), findsOneWidget);
    expect(find.text('尚未读取 .elf / .axf'), findsNothing);
    expect(find.text(requests.single), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'project symbols resolve relative paths and skip loaded or missing files',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tal-project-relative-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final firmware = File('${directory.path}/build/motor.axf');
      firmware.parent.createSync();
      firmware.writeAsStringSync('fixture');
      final requests = <String>[];
      late final TakeALookController controller;
      controller = TakeALookController(
        backendCommand: (command, arguments) async {
          expect(command, ControllerCommand.loadSymbols);
          final path = (arguments! as Map)['path'] as String;
          requests.add(path);
          controller.applyBackendEvent(BackendEventType.state, {
            'symbolFile': path,
          });
        },
      );
      addTearDown(controller.dispose);
      controller.sourceProject.applyJson({
        'sourceRoot': directory.path,
        'firmwarePath': 'build/../build/motor.axf',
      });
      await controller.loadSourceProjectSymbols();
      expect(File(requests.single).absolute.uri, firmware.absolute.uri);

      controller.sourceProject.firmwarePath = firmware.absolute.path;
      await controller.loadSourceProjectSymbols();
      controller.sourceProject.firmwarePath = 'build/not-built-yet.axf';
      await controller.loadSourceProjectSymbols();
      controller.sourceProject.firmwarePath = '';
      await controller.loadSourceProjectSymbols();
      expect(requests, hasLength(1));
      expect(controller.symbolFile, requests.single);
    },
  );

  test(
    'failed project symbol loading preserves the previously loaded file',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tal-project-invalid-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final firmware = File('${directory.path}/invalid.axf')
        ..writeAsStringSync('fixture');
      final controller = TakeALookController(
        backendCommand: (_, _) async =>
            throw const BackendException('symbol_load_failed', '无法解析符号文件'),
      );
      addTearDown(controller.dispose);
      controller.applySnapshot({
        'symbolFile': '${directory.path}/previous.axf',
        'symbols': [_projectSymbol],
        'sourceProject': {
          'sourceRoot': directory.path,
          'firmwarePath': firmware.path,
        },
      });
      await controller.loadSourceProjectSymbols();
      expect(controller.symbolFile, '${directory.path}/previous.axf');
      expect(controller.symbols.single.name, 'counter');
      expect(controller.lastBackendError?['code'], 'symbol_load_failed');
      expect(controller.isSymbolLoading, isFalse);
    },
  );

  for (final failSave in [false, true]) {
    testWidgets(
      '${failSave ? 'failed' : 'cancelled'} settings do not load firmware',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'tal-project-cancel-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final firmware = File('${directory.path}/motor.axf')
          ..writeAsStringSync('fixture');
        final commands = <ControllerCommand>[];
        final controller = TakeALookController(
          symbolFilePicker: () async => firmware.path,
          backendCommand: (command, _) async {
            commands.add(command);
            if (command == ControllerCommand.setSourceProject) {
              throw const BackendException('save_failed', '无法保存工程设置');
            }
          },
        );
        addTearDown(controller.dispose);
        controller.sourceProject.sourceRoot = directory.path;
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_projectSettingsHarness(controller));
        await tester.tap(find.byKey(const ValueKey('source-project-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('浏览固件文件'));
        await tester.pumpAndSettle();
        await tester.tap(
          failSave
              ? find.byKey(const ValueKey('source-project-save'))
              : find.text('取消'),
        );
        await tester.pumpAndSettle();
        expect(commands, isNot(contains(ControllerCommand.loadSymbols)));
        expect(controller.symbolFile, isEmpty);
        expect(controller.isSymbolLoading, isFalse);
        if (failSave) {
          expect(commands, [ControllerCommand.setSourceProject]);
          expect(find.textContaining('无法保存工程设置'), findsOneWidget);
        } else {
          expect(
            find.byKey(const ValueKey('source-project-save')),
            findsNothing,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final size in [const Size(320, 420), const Size(300, 180)]) {
    testWidgets('source build tools fit ${size.width} x ${size.height}', (
      tester,
    ) async {
      final controller = TakeALookController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: buildWorkspacePanelBody(
                  WorkspacePanelId.sourceDebug,
                  controller,
                ),
              ),
            ),
          ),
        ),
      );
      controller.applySourceTask({
        'id': 'build',
        'status': 'running',
        'phase': 'build',
        'canCancel': true,
        'message': '正在编译…',
        'lines': [
          {'seq': 1, 'text': 'working', 'stream': 'stdout'},
        ],
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('source-build-cancel')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}

Widget _projectSettingsHarness(TakeALookController controller) => MaterialApp(
  theme: buildTalTheme(),
  home: Scaffold(
    body: WorkbenchFeedback(
      controller: controller,
      child: Row(
        children: [
          SizedBox(
            width: 320,
            child: buildWorkspacePanelBody(
              WorkspacePanelId.symbols,
              controller,
            ),
          ),
          Expanded(
            child: buildWorkspacePanelBody(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ],
      ),
    ),
  ),
);

const _projectSymbol = {
  'key': '20000000:counter',
  'source': 'motor.c',
  'name': 'counter',
  'address': 0x20000000,
  'type': 'uint32_t',
  'size': 4,
};
