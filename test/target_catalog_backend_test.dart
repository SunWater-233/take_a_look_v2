import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;
  final runtimeOverride = Platform.environment['TAL_TARGET_TEST_BACKEND'];
  test('default checkout launch serves the current target catalog', () async {
    final client = BackendClient();
    addTearDown(() => client.close(force: true));
    await client.start();
    expect(client.isRunning, isTrue);
    final result = await client.targetCatalogRequest('listTargets', {});
    expect(result['targets'], isNotEmpty);
    expect((result['state'] as Map).containsKey('targetPackId'), isTrue);
  }, skip: !python.existsSync() ? 'Run tool/setup_backend first.' : false);
  test(
    'real stdio import, selection, process restart and missing-pack rejection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tal target catalog ',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pack = File('${directory.path}/User.Demo_DFP.1.0.0.pack');
      final created = await Process.run(python.path, [
        '-c',
        """
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    archive.writestr('User.Demo_DFP.pdsc', '''<package schemaVersion="1.7.7">
<vendor>User</vendor><name>Demo_DFP</name><releases><release version="1.0.0">test</release></releases>
<devices><family Dvendor="User:999" Dfamily="Demo"><processor Dcore="Cortex-M4" Dclock="64000000"/>
<memory id="IRAM1" start="0x20000000" size="0x10000" access="rwx"/>
<device Dname="USER_DEMO100"/></family></devices></package>''')
""",
        pack.path,
      ]);
      expect(created.exitCode, 0, reason: '${created.stderr}');

      BackendClient createClient() => BackendClient(
        processStarter: () => Process.start(
          runtimeOverride ?? python.path,
          runtimeOverride == null
              ? ['-u', '-m', 'take_a_look_backend.stdio']
              : const [],
          workingDirectory: Directory('backend').absolute.path,
          environment: {
            ...Platform.environment,
            'PYTHONPATH': Directory('backend').absolute.path,
            'PYTHONUTF8': '1',
            'TAL_PACKS_DIR': '${directory.path}/library',
            'TAL_RECORDINGS_DIR': '${directory.path}/recordings',
          },
        ),
      );

      final first = createClient();
      final controller = TakeALookController(
        backendCommand: first.command,
        targetCatalogRequest: first.targetCatalogRequest,
      );
      first.eventHandler = controller.applyBackendEvent;
      addTearDown(() async {
        first.eventHandler = null;
        await first.close(force: true);
        controller.dispose();
      });
      await first.start();
      expect(first.isRunning, isTrue, reason: '${controller.lastBackendError}');
      final catalog = await controller.requestTargetCatalog('listTargets');
      expect((catalog['targets'] as List).length, greaterThan(100));
      final preview = await controller.requestTargetCatalog(
        'inspectTargetPack',
        {'path': pack.path},
      );
      expect(preview['targetCount'], 1);
      final imported = await controller.requestTargetCatalog(
        'importTargetPack',
        {'previewId': preview['previewId']},
      );
      final packId = imported['packId'];
      await controller.requestTargetCatalog('selectTarget', {
        'name': 'user_demo100',
        'packId': packId,
      });
      expect(controller.targetName, 'user_demo100');
      expect(controller.targetPackId, packId);
      expect(controller.targetPackLabel, 'User.Demo_DFP 1.0.0');
      await pack.delete();
      first.eventHandler = null;
      await first.close();

      final second = createClient();
      final restored = TakeALookController(
        backendCommand: second.command,
        targetCatalogRequest: second.targetCatalogRequest,
      );
      second.eventHandler = restored.applyBackendEvent;
      addTearDown(() async {
        second.eventHandler = null;
        await second.close(force: true);
        restored.dispose();
      });
      await second.start();
      expect(restored.targetPackId, packId);
      expect(restored.targetPartNumber, 'USER_DEMO100');
      await restored.requestTargetCatalog('removeTargetPack', {
        'packId': packId,
      });
      expect(restored.targetPackMissing, isTrue);
      await expectLater(
        second.request(BackendMethod.connect),
        throwsA(
          isA<BackendException>().having(
            (error) => error.code,
            'code',
            'target_pack_missing',
          ),
        ),
      );
      expect(restored.targetName, 'user_demo100');
      second.eventHandler = null;
      await second.close();
    },
    skip: !python.existsSync() ? 'Run tool/setup_backend first.' : false,
  );
}
