import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final packPath = Platform.environment['TAL_TEST_PACK'];
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;
  final runtime = Platform.environment['TAL_TARGET_TEST_BACKEND'];

  test(
    'real pack import tolerates a catalog refresh from a state event',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tal-pack-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final client = BackendClient(
        processStarter: () => Process.start(
          runtime ?? python.path,
          runtime == null ? ['-u', '-m', 'take_a_look_backend.stdio'] : [],
          workingDirectory: Directory('backend').absolute.path,
          environment: {
            ...Platform.environment,
            'PYTHONUTF8': '1',
            'TAL_PACKS_DIR': '${directory.path}/packs',
            'TAL_RECORDINGS_DIR': '${directory.path}/recordings',
            'TAL_SOURCE_SETTINGS': '${directory.path}/source.json',
          },
        ),
      );
      final controller = TakeALookController(
        backendCommand: client.command,
        targetCatalogRequest: client.targetCatalogRequest,
      );
      client.eventHandler = controller.applyBackendEvent;
      addTearDown(() async {
        client.eventHandler = null;
        await client.close(force: true);
        controller.dispose();
      });
      await client.start();
      expect(client.isRunning, isTrue);
      final initial = await controller.requestTargetCatalog('listTargets');
      final preview = await controller.requestTargetCatalog(
        'inspectTargetPack',
        {'path': packPath},
      );
      expect(preview['targetCount'], greaterThan(0));
      Future<JsonObject>? automaticRefresh;
      controller.targetCatalogChanges.addListener(() {
        automaticRefresh = controller.requestTargetCatalog('listTargets');
      });
      await controller.requestTargetCatalog('importTargetPack', {
        'previewId': preview['previewId'],
      });
      final explicitRefresh = controller.requestTargetCatalog('listTargets');
      expect(automaticRefresh, isNotNull);
      final catalogs = await Future.wait([
        automaticRefresh!,
        explicitRefresh,
      ]).timeout(const Duration(seconds: 5));
      for (final catalog in catalogs) {
        expect(
          (catalog['targets'] as List).length,
          (initial['targets'] as List).length + (preview['targetCount'] as int),
        );
        expect((catalog['packs'] as List).single['id'], preview['id']);
      }
      expect(controller.lastBackendError, isNull);
    },
    skip: packPath == null
        ? 'Set TAL_TEST_PACK to validate a local .pack with the real backend.'
        : runtime == null && !python.existsSync()
        ? 'Run tool/setup_backend first.'
        : false,
  );
}
