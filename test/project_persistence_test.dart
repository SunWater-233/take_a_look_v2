import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/project_document.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';

void main() {
  testWidgets(
    'project round trip restores variables, drafts, settings and layout after restart',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('tal_project_');
      final file = File('${directory.path}/work.talproj');
      var controller = (await tester.runAsync(
        () async => TakeALookController(),
      ))!..loadDemoSymbols();
      var sync = MainWindowSync(controller);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await sync.dispose();
        controller.dispose();
        directory.deleteSync(recursive: true);
        await tester.binding.setSurfaceSize(null);
      });
      var picks = 0;
      Future<void> mount() async {
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(),
            home: MainWorkbench(
              controller: controller,
              windowSync: sync,
              layoutFile: File('${directory.path}/layout.json'),
              projectSavePathPicker: () async {
                picks++;
                return file.path;
              },
              projectOpenPathPicker: () async => file.path,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }

      DockingWorkspaceState workspace() =>
          tester.state(find.byType(DockingWorkspace));
      await mount();
      expect(controller.monitorRateHz, 10);
      controller.selectSymbols(demoSymbols.take(3).map((s) => s.key));
      controller.addSelectedToWatch();
      final keys = controller.watches.map((w) => w.symbol.key).toList();
      controller.reorderWatch(0, 2);
      controller.setWatchReadMode(keys[0], WatchReadMode.monitor);
      controller.setWatchMonitorRate(keys[0], 5);
      controller.setWatchColors([keys[1]], const Color(0xff12abcd));
      controller.toggleWatchPlot(keys[2], false);
      controller.watchInputDrafts[keys[0]] = '12.5';
      controller.compactWatchSelection = keys[0];
      controller.compactExpandedWatches.add(keys[0]);
      controller.sampleRateHz = 500;
      controller.sourceProject.buildCommand = 'make debug';
      controller.sourceProject.sourceRoot = directory.path;
      controller.debugState.requestedBreakpoints['main.c'] = {12, 24};
      controller.configurePlotView({
        'plotShowGrid': false,
        'plotVisibleWindowSeconds': 30,
      });
      controller.setUiScale(1.25);
      await workspace().activateWorkbenchView(WorkspacePanelId.analysis);
      await workspace().showPanel(WorkspacePanelId.registers);
      await workspace().toggleWorkbenchOutput();
      await tester.pumpAndSettle();
      final order = controller.watches.map((w) => w.symbol.key).toList();
      final layout = workspace().projectLayout().toJson();
      await tester.runAsync(workspace().saveProject);
      expect(file.existsSync(), isTrue);
      final document = await tester.runAsync(() => ProjectDocument.read(file));
      expect(document!.settings, isNot(contains('connectionStatus')));
      expect(document.settings, isNot(contains('rawRecording')));
      expect(
        (document.settings['watches'] as List).first,
        isNot(contains('value')),
      );
      // Ctrl+S updates the same file without another picker.
      controller.sourceProject.buildCommand = 'make release';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      for (
        var attempt = 0;
        attempt < 100 &&
            controller.logs
                    .where((e) => e.message.startsWith('项目已保存：'))
                    .length <
                2;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        controller.logs.where((e) => e.message.startsWith('项目已保存：')),
        hasLength(2),
      );
      expect(picks, 1);
      expect(
        (await tester.runAsync(
          () => ProjectDocument.read(file),
        ))!.settings['sourceProject'],
        containsPair('buildCommand', 'make release'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await sync.dispose();
      controller.dispose();
      controller = (await tester.runAsync(() async => TakeALookController()))!;
      sync = MainWindowSync(controller);
      await mount();
      await tester.runAsync(workspace().openProject);
      await tester.pumpAndSettle();
      expect(controller.watches.map((w) => w.symbol.key), order);
      expect(controller.watches.last.readMode, WatchReadMode.monitor);
      expect(controller.watches.last.monitorRateHz, 5);
      expect(controller.watches.first.color, const Color(0xff12abcd));
      expect(controller.watches[1].plotted, isFalse);
      expect(controller.watchInputDrafts[keys[0]], '12.5');
      expect(controller.compactWatchSelection, keys[0]);
      expect(controller.compactExpandedWatches, contains(keys[0]));
      expect(controller.sourceProject.buildCommand, 'make release');
      expect(controller.debugState.requestedBreakpoints['main.c'], {12, 24});
      expect(controller.sampleRateHz, 500);
      expect(controller.plotShowGrid, isFalse);
      expect(controller.uiScale, 1.25);
      expect(controller.connectionStatus, ConnectionStatus.disconnected);
      expect(workspace().outputDocked, isFalse);
      expect(workspace().projectLayout().toJson(), layout);
      expect(controller.watches.every((w) => w.samples.isEmpty), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid project is rejected before changing controller state', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {})
      ..loadDemoSymbols();
    addTearDown(controller.dispose);
    final settings = controller.projectSettings();
    settings['watches'] = [
      {'key': 'missing-symbol'},
    ];
    expect(
      () => ProjectDocument.fromJson({
        'format': 'take-a-look-project',
        'version': 1,
        'settings': settings,
        'layout': const WorkspaceLayoutSnapshot(
          groups: [],
          uiScale: 1,
        ).toJson(),
      }),
      throwsFormatException,
    );
    expect(controller.symbols, hasLength(demoSymbols.length));
    expect(controller.watches, isEmpty);
  });

  testWidgets(
    'project restoration awaits backend configuration and watches without writes or tasks',
    (tester) async {
      final file = File(
        '${Directory.systemTemp.path}/tal_symbols_${DateTime.now().microsecondsSinceEpoch}.elf',
      )..writeAsStringSync('fixture');
      addTearDown(() => file.deleteSync());
      final original = TakeALookController(backendCommand: (_, _) async {})
        ..loadDemoSymbols();
      addTearDown(original.dispose);
      original.selectSymbols([demoSymbols.first.key]);
      original.addSelectedToWatch();
      original.symbolFile = file.path;
      final settings = original.projectSettings();
      final commands = <ControllerCommand>[];
      final configurations = <Map>[];
      final catalogCalls = <String>[];
      late TakeALookController restored;
      restored = TakeALookController(
        targetCatalogRequest: (operation, args) async {
          catalogCalls.add(operation);
          return {};
        },
        backendCommand: (command, args) async {
          commands.add(command);
          if (command == ControllerCommand.configureProject) {
            configurations.add(args as Map);
          }
          if (command == ControllerCommand.loadSymbols) {
            restored.applySnapshot({
              'symbols': settings['symbols'],
              'watches': [],
            });
          }
          if (command == ControllerCommand.setWatches) {
            restored.applySnapshot({'watches': (args as Map)['watches']});
          }
        },
      );
      addTearDown(restored.dispose);
      await tester.runAsync(() => restored.restoreProjectSettings(settings));
      expect(restored.watches.single.symbol.key, demoSymbols.first.key);
      expect(
        commands,
        containsAllInOrder([
          ControllerCommand.configureProject,
          ControllerCommand.setSamplingPaused,
          ControllerCommand.clearSamples,
          ControllerCommand.setSourceProject,
          ControllerCommand.loadSymbols,
          ControllerCommand.setWatches,
        ]),
      );
      expect(commands, isNot(contains(ControllerCommand.writeWatch)));
      expect(commands, isNot(contains(ControllerCommand.startSourceTask)));
      for (final status in [
        ConnectionStatus.connected,
        ConnectionStatus.connecting,
      ]) {
        commands.clear();
        catalogCalls.clear();
        restored.applySnapshot({
          'connectionStatus': status.name,
          'probeType': 'J-Link',
          'targetName': 'stm32h743zitx',
          'targetPackId': 'live-pack',
          'swdClock': '4 MHz',
          'serialNumber': '63728607',
          'connectionKind': 'emberGdb',
          'remoteConfig': {'deviceId': 'live-device'},
        });
        final liveConnection = restored.snapshot();
        await tester.runAsync(() => restored.restoreProjectSettings(settings));
        expect(restored.connectionStatus, status);
        final after = restored.snapshot();
        for (final key in [
          'probeType',
          'targetName',
          'targetPackId',
          'swdClock',
          'serialNumber',
          'connectionKind',
          'remoteConfig',
        ]) {
          expect(after[key], liveConnection[key], reason: key);
          expect(configurations.last, isNot(contains(key)));
        }
        expect(catalogCalls, isEmpty);
        expect(commands, isNot(contains(ControllerCommand.toggleConnection)));
        expect(restored.watches.single.symbol.key, demoSymbols.first.key);
      }
    },
  );
}
