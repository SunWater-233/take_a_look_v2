import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_chrome.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode probe loss stops capture and updates connection feedback',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final commands = <ControllerCommand>[];
        final controller = TakeALookController(
          backendCommand: (command, _) async => commands.add(command),
        );
        addTearDown(controller.dispose);
        controller.applySnapshot({
          'connectionStatus': 'connected',
          'samplingPaused': false,
          'rttEnabled': true,
          'debug': {'executionState': 'running'},
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: Scaffold(
              body: WorkbenchFeedback(
                controller: controller,
                child: WorkbenchToolbar(controller: controller),
              ),
            ),
          ),
        );
        controller.applyBackendEvent(BackendEventType.state, {
          'connectionStatus': 'disconnected',
          'samplingPaused': true,
          'rttEnabled': false,
          'debug': {'executionState': 'unavailable'},
        });
        controller.applyBackendEvent(BackendEventType.error, {
          'code': 'probe_disconnected',
          'message': '本地调试探针连接已中断，已停止采样；请重新连接探针。',
        });
        await tester.pumpAndSettle();
        expect(controller.connectionStatus, ConnectionStatus.disconnected);
        expect(controller.samplingPaused, isTrue);
        expect(controller.rttEnabled, isFalse);
        expect(find.text('探针连接已中断'), findsOneWidget);
        expect(
          tester
              .widget<TalButton>(
                find.byKey(const ValueKey('workbench-disconnect')),
              )
              .onPressed,
          isNull,
        );
        expect(commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('$mode toolbar disconnect follows connection state', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final commands = <ControllerCommand>[];
      late TakeALookController controller;
      controller = TakeALookController(
        backendCommand: (command, _) async {
          commands.add(command);
          if (command == ControllerCommand.toggleConnection) {
            controller.applySnapshot({'connectionStatus': 'disconnected'});
          }
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: Scaffold(body: WorkbenchToolbar(controller: controller)),
        ),
      );

      final disconnect = find.byKey(const ValueKey('workbench-disconnect'));
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      controller.applySnapshot({'connectionStatus': 'connecting'});
      await tester.pump();
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      expect(commands, isEmpty);

      controller.applySnapshot({'connectionStatus': 'connected'});
      await tester.pump();
      expect(tester.widget<TalButton>(disconnect).onPressed, isNotNull);
      expect(
        tester.getRect(disconnect).left,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('workbench-target'))).right,
        ),
      );
      expect(
        tester.getRect(disconnect).right,
        lessThan(tester.getRect(find.text('复位')).left),
      );

      await tester.tap(disconnect);
      await tester.pumpAndSettle();
      expect(commands, [ControllerCommand.toggleConnection]);
      expect(controller.connectionStatus, ConnectionStatus.disconnected);
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$mode connection dialog fits content and scrolls remote fields',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = TakeALookController(backendCommand: (_, _) async {});
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: Scaffold(body: WorkbenchToolbar(controller: controller)),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('workbench-connection')));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final surface = find
            .descendant(of: dialog, matching: find.byType(Material))
            .first;
        final localHeight = tester.getSize(surface).height;
        expect(localHeight, lessThan(500));
        expect(find.text('序列号').hitTestable(), findsOneWidget);
        expect(find.text('连接探针').hitTestable(), findsOneWidget);

        controller.applySnapshot({'connectionKind': 'emberGdb'});
        await tester.pumpAndSettle();
        expect(tester.getSize(surface).height, greaterThan(localHeight));

        await tester.binding.setSurfaceSize(const Size(1280, 400));
        await tester.pumpAndSettle();
        expect(find.text('关闭').hitTestable(), findsOneWidget);
        final scroll = find.descendant(
          of: dialog,
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(scroll, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('remote-gdbPath')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
      },
    );
  }
}
