import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';

void main() {
  testWidgets(
    'update snapshot restores unsaved changes and original project path without connecting hardware',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('tal-update-workspace-');
      final session = File('${root.path}/session.json');
      final project = File('${root.path}/original.talproj');
      var controller = (await tester.runAsync(
        () async => TakeALookController(),
      ))!..loadDemoSymbols();
      var sync = MainWindowSync(controller);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await sync.dispose();
        controller.dispose();
        root.deleteSync(recursive: true);
        await tester.binding.setSurfaceSize(null);
      });
      Future<void> mount({File? recovery}) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(),
            home: MainWorkbench(
              controller: controller,
              windowSync: sync,
              layoutFile: File('${root.path}/layout.json'),
              projectSavePathPicker: () async => project.path,
              updateSession: recovery,
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (recovery == null ||
              controller.logs.any(
                (log) => log.message.startsWith('更新前的工作区已恢复'),
              )) {
            break;
          }
        }
        await tester.pumpAndSettle();
      }

      await mount();
      var workspace = tester.state<DockingWorkspaceState>(
        find.byType(DockingWorkspace),
      );
      await tester.runAsync(workspace.saveProject);
      final originalContents = project.readAsStringSync();
      controller.selectSymbols([demoSymbols.first.key]);
      controller.addSelectedToWatch();
      controller.watchInputDrafts[demoSymbols.first.key] = '123.456';
      controller.sampleRateHz = 500;
      var saved = false;
      final saving = workspace
          .saveUpdateSession(session)
          .then((_) => saved = true);
      for (var i = 0; i < 100 && !saved; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(saved, isTrue);
      await saving;
      expect(project.readAsStringSync(), originalContents);
      await tester.pumpWidget(const SizedBox.shrink());
      await sync.dispose();
      controller.dispose();
      final commands = <ControllerCommand>[];
      controller = TakeALookController(
        backendCommand: (command, arguments) async {
          commands.add(command);
          if (command == ControllerCommand.setSourceProject) {
            controller.applySnapshot({
              'sourceProject': arguments,
              'firmware': {'status': 'ready'},
              'symbols': [for (final symbol in demoSymbols) symbol.toJson()],
            });
          }
        },
      );
      sync = MainWindowSync(controller);
      await mount(recovery: session);
      workspace = tester.state<DockingWorkspaceState>(
        find.byType(DockingWorkspace),
      );
      expect(
        workspace.projectPath,
        project.path,
        reason: controller.logs.map((log) => log.message).join('\n'),
      );
      expect(controller.watches.single.symbol.key, demoSymbols.first.key);
      expect(controller.watchInputDrafts[demoSymbols.first.key], '123.456');
      expect(controller.sampleRateHz, 500);
      expect(controller.connectionStatus, ConnectionStatus.disconnected);
      expect(commands, isNot(contains(ControllerCommand.toggleConnection)));
      expect(commands, isNot(contains(ControllerCommand.writeWatch)));
      expect(commands, isNot(contains(ControllerCommand.startSourceTask)));
    },
  );
}
