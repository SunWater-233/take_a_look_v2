import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;
  final fixture = File('test/fixtures/symbol_load_backend.py').absolute;
  final skip = !python.existsSync() ? 'Run tool/setup_backend first.' : false;

  BackendClient client({Duration loadTimeout = const Duration(seconds: 6)}) =>
      BackendClient(
        commandTimeout: const Duration(seconds: 3),
        symbolLoadTimeout: loadTimeout,
        processStarter: () => Process.start(python.path, ['-u', fixture.path]),
      );

  test(
    'load RPC has its own timeout and delivers progress before completion',
    () async {
      final backend = client();
      final controller = TakeALookController(backendCommand: backend.command);
      backend.eventHandler = controller.applyBackendEvent;
      addTearDown(() async {
        backend.eventHandler = null;
        await backend.close(force: true);
        controller.dispose();
      });
      final progress = <SymbolLoadProgress>[];
      controller.symbolLoadChanges.addListener(
        () => progress.add(controller.symbolLoadProgress!),
      );
      await backend.start();
      expect(backend.isRunning, isTrue);
      await controller.loadSymbolsFromPath('slow.elf');
      expect(controller.lastBackendError, isNull);
      expect(controller.symbolFile, 'slow.elf');
      expect(controller.debugState.sourceFiles, ['main.c']);
      expect(progress.any((p) => p.fraction == 0.6 && p.isLoading), isTrue);
      expect(progress.last.status, SymbolLoadStatus.complete);
      await expectLater(
        backend.request(BackendMethod.getState),
        throwsA(
          isA<BackendException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
    },
    skip: skip,
  );

  for (final entry in {
    'broken.elf': 'protocol_error',
    'exit.elf': 'process_exited',
    'slow.elf': 'timeout',
  }.entries) {
    test(
      '${entry.value} clears load state without waiting for the full load timeout',
      () async {
        final backend = client(loadTimeout: const Duration(milliseconds: 300));
        final controller = TakeALookController(backendCommand: backend.command);
        backend.eventHandler = controller.applyBackendEvent;
        addTearDown(() async {
          backend.eventHandler = null;
          await backend.close(force: true);
          controller.dispose();
        });
        await backend.start();
        expect(
          backend.isRunning,
          isTrue,
          reason: '${controller.lastBackendError}',
        );
        await controller.loadSymbolsFromPath(entry.key);
        expect(controller.isSymbolLoading, isFalse);
        expect(controller.symbolLoadProgress!.status, SymbolLoadStatus.failed);
        expect(controller.lastBackendError?['code'], entry.value);
      },
      skip: skip,
    );
  }

  final realElf = Platform.environment['TAL_TEST_ELF'];
  final packagedBackend = Platform.environment['TAL_TEST_BACKEND'];
  final expectedDefinition = Platform.environment['TAL_TEST_DEFINITION'];
  test(
    'packaged backend loads a real ELF through the application controller',
    () async {
      final backend = BackendClient(
        processStarter: packagedBackend == null
            ? null
            : () => Process.start(
                packagedBackend,
                const [],
                workingDirectory: Directory.systemTemp.path,
              ),
      );
      final controller = TakeALookController(backendCommand: backend.command);
      backend.eventHandler = controller.applyBackendEvent;
      addTearDown(() async {
        backend.eventHandler = null;
        await backend.close(force: true);
        controller.dispose();
      });
      final phases = <String>[];
      controller.symbolLoadChanges.addListener(() {
        final phase = controller.symbolLoadProgress!.phase;
        if (phases.isEmpty || phases.last != phase) phases.add(phase);
      });
      await backend.start();
      expect(backend.isRunning, isTrue);
      await controller.loadSymbolsFromPath(realElf!);
      expect(controller.lastBackendError, isNull);
      expect(controller.symbols, isNotEmpty);
      expect(controller.debugState.sourceFiles, isNotEmpty);
      expect(controller.debugState.hasSourceDefinitionIndex, isTrue);
      expect(controller.debugState.sourceDefinitions, isNotEmpty);
      if (expectedDefinition != null) {
        final definitions = findSourceDefinitions(
          controller.debugState.sourceDefinitions,
          expectedDefinition,
          isCurrentFile: (_) => false,
        );
        expect(definitions, isNotEmpty);
        expect(definitions.first.isDeclaration, isFalse);
      }
      expect(controller.symbolLoadProgress!.status, SymbolLoadStatus.complete);
      expect(
        phases,
        containsAllInOrder([
          'check',
          'debug',
          'scan',
          'variables',
          'source',
          'ui',
        ]),
      );
    },
    skip: realElf == null
        ? 'Set TAL_TEST_ELF to validate an actual firmware file.'
        : false,
  );
}
