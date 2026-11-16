import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

const _dialog = ValueKey('firmware-changed-dialog');

Map<String, dynamic> _firmware(String fingerprint, {bool pending = true}) => {
  'status': 'ready',
  'fingerprint': fingerprint,
  'requiresDownload': pending,
};

Widget _harness(
  TakeALookController controller, {
  bool showFirmwareChanges = true,
}) => MaterialApp(
  theme: buildTalTheme(),
  home: Scaffold(
    body: WorkbenchFeedback(
      controller: controller,
      showFirmwareChanges: showFirmwareChanges,
      child: const SizedBox.shrink(),
    ),
  ),
);

TakeALookController _controller({BackendCommand? command}) {
  final controller = TakeALookController(
    backendCommand: command ?? (_, _) async {},
  );
  controller.setPresentationActive(false);
  controller.applySnapshot({
    'connectionStatus': 'connected',
    'sourceProject': {'firmwarePath': 'C:/project/motor.axf'},
    'firmware': _firmware('old', pending: false),
  });
  return controller;
}

void main() {
  testWidgets(
    'requires both loaded symbols and a source root before prompting',
    (tester) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(controller));
      controller.applySnapshot({'firmware': _firmware('new')});
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(controller.firmwareNotice, contains('符号已自动刷新'));

      controller.applySnapshot({
        'sourceProject': {'sourceRoot': 'C:/project'},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(controller.firmwareRequiresDownload, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'prompts once per content change and never downloads automatically',
    (tester) async {
      final calls = <Object?>[];
      final controller = _controller(
        command: (command, args) async {
          expect(command, ControllerCommand.startSourceTask);
          calls.add(args);
        },
      );
      addTearDown(controller.dispose);
      controller.sourceProject.sourceRoot = 'C:/project';
      await tester.pumpWidget(_harness(controller));
      controller.applySnapshot({'firmware': _firmware('new')});
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();

      controller.applySnapshot({
        'firmware': {..._firmware('new'), 'revision': 99},
        'sourceTask': {'id': 'build', 'status': 'succeeded'},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      controller.applySnapshot({'firmware': _firmware('newer')});
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.text('重新下载'));
      await tester.pumpAndSettle();
      expect(calls, [
        {'kind': 'download'},
      ]);
      expect(find.byKey(_dialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'waits for build completion and skips successful build-and-download',
    (tester) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.sourceProject.sourceRoot = 'C:/project';
      await tester.pumpWidget(_harness(controller));
      controller.applySnapshot({
        'firmware': _firmware('new'),
        'sourceTask': {'id': 'build', 'status': 'running', 'phase': 'build'},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      controller.applySnapshot({
        'sourceTask': {'id': 'build', 'status': 'succeeded'},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();

      controller.applySnapshot({
        'firmware': _firmware('newer'),
        'sourceTask': {
          'id': 'build-download',
          'status': 'running',
          'phase': 'download',
        },
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      controller.applySnapshot({
        'firmware': _firmware('newer', pending: false),
        'sourceTask': {'id': 'build-download', 'status': 'succeeded'},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final kind in ['local', 'gdb']) {
    testWidgets('$kind download action follows live connection capabilities', (
      tester,
    ) async {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.sourceProject.sourceRoot = 'C:/project';
      controller.applySnapshot({
        'connectionKind': kind,
        'connectionStatus': 'disconnected',
        'firmware': _firmware('new'),
      });
      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();
      TalButton download() =>
          tester.widget<TalButton>(find.widgetWithText(TalButton, '重新下载'));
      expect(download().onPressed, isNull);
      controller.applySnapshot({'connectionStatus': 'connected'});
      await tester.pumpAndSettle();
      expect(download().onPressed != null, kind == 'local');
      controller.applySnapshot({'firmware': _firmware('new', pending: false)});
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('replaces an outdated reminder when another rebuild finishes', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.sourceProject.sourceRoot = 'C:/project';
    controller.applySnapshot({'firmware': _firmware('new')});
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    controller.applySnapshot({'firmware': _firmware('newer')});
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.applySnapshot({
      'sourceProject': {'firmwarePath': 'C:/other.axf'},
      'firmware': _firmware('other', pending: false),
    });
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detached windows leave the reminder to the main window', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.sourceProject.sourceRoot = 'C:/project';
    controller.applySnapshot({'firmware': _firmware('new')});
    await tester.pumpWidget(_harness(controller, showFirmwareChanges: false));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    expect(controller.firmwareRequiresDownload, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
