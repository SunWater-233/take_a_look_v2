import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/workspace/project_document.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';

void main() {
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;

  test(
    'one firmware path survives settings, windows and project restoration',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tal_firmware_context_',
      );
      final backend = BackendClient(
        processStarter: () => Process.start(
          python.path,
          [
            '-u',
            File('test/fixtures/firmware_context_backend.py').absolute.path,
            directory.path,
          ],
          environment: {
            'PYTHONPATH': Directory('backend').absolute.path,
            'PYTHONUTF8': '1',
          },
        ),
      );
      final controller = TakeALookController(
        backendCommand: backend.command,
        projectBackendCommand: backend.projectCommand,
      );
      backend.eventHandler = controller.applyBackendEvent;
      late final TakeALookController detached;
      detached = TakeALookController(
        remoteCommand: (command, args) async {
          detached.applySnapshot(await controller.handleCommand(command, args));
        },
      );
      addTearDown(() async {
        backend.eventHandler = null;
        await backend.close(force: true);
        detached.dispose();
        controller.dispose();
        directory.deleteSync(recursive: true);
      });
      await backend.start();
      expect(backend.isRunning, isTrue);
      final image = File.fromUri(directory.uri.resolve('motor.axf'))
        ..writeAsStringSync('A');

      await detached.loadFirmware(image.path);
      expect(detached.firmwarePath, image.path);
      expect(controller.firmwarePath, image.path);
      final fingerprint = controller.state.firmware['fingerprint'];
      expect(controller.symbols.single.address, 0x20000001);

      image.writeAsStringSync('new build');
      await detached.saveSourceProject({
        'sourceRoot': directory.path,
        'firmwarePath': './build/../motor.axf',
      });
      expect(controller.firmwarePath, image.path);
      expect(detached.firmwarePath, image.path);
      expect(controller.state.firmware['fingerprint'], isNot(fingerprint));
      expect(detached.symbols.single.address, 0x20000009);

      final otherRoot = Directory('${directory.path}/other')..createSync();
      await controller.setSourceRoot(otherRoot.path);
      expect(controller.firmwarePath, image.path);

      await controller.saveSourceProject({'firmwarePath': 'not-built-yet.axf'});
      final pending = controller.firmwarePath;
      expect(controller.symbols, isEmpty);
      expect(controller.state.firmware['status'], 'missing');
      final document = ProjectDocument(
        settings: controller.projectSettings(),
        layout: const WorkspaceLayoutSnapshot(groups: [], uiScale: 1),
      );
      expect(document.settings, isNot(contains('symbolFile')));
      expect(document.settings, isNot(contains('sourceRoot')));
      final projectFile = File('${directory.path}/work.talproj');
      await document.write(projectFile);
      final saved = await ProjectDocument.read(projectFile);
      expect(saved.toJson()['version'], 2);
      expect(
        () => ProjectDocument.fromJson({...saved.toJson(), 'version': 1}),
        throwsFormatException,
      );

      await controller.loadFirmware(image.path);
      expect(controller.symbols, isNotEmpty);
      await controller.restoreProjectSettings(saved.settings);
      final result = await backend.request(BackendMethod.getState);
      final state = result['state'] as Map;
      expect(controller.firmwarePath, pending);
      expect((state['sourceProject'] as Map)['firmwarePath'], pending);
      expect(controller.symbols, isEmpty);
      expect(state['symbols'], isEmpty);
      expect(controller.state.firmware['status'], 'missing');
      detached.applySnapshot(controller.stateSnapshot());
      expect(detached.firmwarePath, pending);
      expect(detached.symbols, isEmpty);
    },
    skip: !python.existsSync() ? 'Run tool/setup_backend first.' : false,
  );
}
