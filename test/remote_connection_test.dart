import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

void main() {
  testWidgets(
    'remote connection fields switch, edit and lock after connecting',
    (tester) async {
      final controller = TakeALookController();
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 330,
              child: buildWorkspacePanel(
                WorkspacePanelId.connection,
                controller,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('connection-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('EmberMobile + GDB').last);
      await tester.pumpAndSettle();
      expect(controller.connectionKind, 'emberGdb');
      expect(find.text('访问令牌'), findsOneWidget);
      expect(find.text('GDB 程序'), findsOneWidget);
      expect(find.text('SWD 时钟'), findsNothing);

      Finder input(String name) => find.descendant(
        of: find.byKey(ValueKey('remote-$name')),
        matching: find.byType(TextField),
      );
      await tester.enterText(input('host'), '192.168.1.49');
      await tester.enterText(input('token'), 'session-token');
      expect(controller.remoteConfig['host'], '192.168.1.49');
      expect(controller.remoteConfig['token'], 'session-token');
      expect(tester.widget<TextField>(input('token')).obscureText, isTrue);
      controller.applyBackendEvent(BackendEventType.state, {
        'connectionStatus': 'connected',
      });
      await tester.pump();
      expect(tester.widget<TextField>(input('host')).enabled, isFalse);
      controller.setConnectionKind('local');
      expect(controller.connectionKind, 'emberGdb');
      expect(tester.takeException(), isNull);
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    },
  );

  test(
    'remote configuration routes to backend and survives window snapshots',
    () {
      final calls = <(ControllerCommand, Object?)>[];
      final main = TakeALookController(
        backendCommand: (command, args) async {
          calls.add((command, args));
        },
      );
      final detached = TakeALookController();
      addTearDown(main.dispose);
      addTearDown(detached.dispose);
      main.setConnectionKind('ember');
      main.setRemoteConfig({'host': 'phone.local', 'gatewayPort': '4242'});
      final kindCall = BackendCommandMapper.translate(
        calls[0].$1,
        calls[0].$2,
        {},
      );
      expect(kindCall!.method, BackendMethod.setConfig);
      expect(kindCall.params, {'connectionKind': 'ember'});
      final configCall = BackendCommandMapper.translate(
        calls[1].$1,
        calls[1].$2,
        {},
      );
      expect(configCall!.params, {
        'remoteConfig': {'host': 'phone.local', 'gatewayPort': '4242'},
      });
      main.applyBackendEvent(BackendEventType.state, {
        'connectionKind': 'ember',
        'remoteConfig': {'host': 'phone.local', 'token': 'session-token'},
      });
      expect(main.supportsMemoryWrite, isFalse);
      detached.applySnapshot(main.snapshot(includeSamples: false));
      expect(detached.connectionKind, 'ember');
      expect(detached.remoteConfig['host'], 'phone.local');
      expect(detached.remoteConfig['token'], 'session-token');
      expect(detached.connectionStatus, ConnectionStatus.disconnected);
    },
  );
}
