import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/source_tools.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

void main() {
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
