import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/freertos.dart';
import 'package:take_a_look_v2/src/panels/freertos_panel.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/ui_test/freertos_fixture.dart';

void main() {
  setUpAll(() async {
    for (final font in [
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
      ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('freertos-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/freertos_ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'task/object drill-down and display freeze never halt the target',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1180, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final commands = <ControllerCommand>[];
      final controller = TakeALookController(
        backendCommand: (command, _) async => commands.add(command),
      );
      addTearDown(controller.dispose);
      controller.setPresentationActive(false);
      controller.applySnapshot({
        'connectionStatus': 'connected',
        'freeRtos': freeRtosFixture(),
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('freertos-preview'),
              child: FreeRtosPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telemetry').first);
      await tester.pumpAndSettle();
      await capture(tester, 'desktop');
      expect(find.text('mutexLog'), findsOneWidget);
      await tester.tap(find.text('mutexLog'));
      await tester.pumpAndSettle();
      expect(controller.freeRtosSettings['page'], 'objects');
      await tester.tap(find.text('Logger').last);
      await tester.pumpAndSettle();
      expect(controller.freeRtosSettings['selectedTask'], 0x24001da0);
      await tester.tap(find.text('冻结显示'));
      await tester.pumpAndSettle();
      final next = freeRtosFixture(sequence: 1843);
      (next['tasks'] as List).removeLast();
      controller.applyBackendEvent(BackendEventType.freeRtos, next);
      await tester.pumpAndSettle();
      expect(find.text('7 个任务'), findsOneWidget);
      expect(commands, isNot(contains(ControllerCommand.debugControl)));
      await tester.tap(find.text('继续刷新'));
      await tester.pumpAndSettle();
      expect(find.text('6 个任务'), findsOneWidget);
      await tester.tap(find.text('内存'));
      await tester.pumpAndSettle();
      await capture(tester, 'memory');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('narrow layouts and unavailable data stay readable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(380, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.setPresentationActive(false);
    final data = freeRtosFixture();
    for (final task in data['tasks'] as List) {
      task['cpuPercent'] = null;
      task['stackBytes'] = null;
    }
    controller.applySnapshot({
      'connectionStatus': 'connected',
      'freeRtos': data,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('freertos-preview'),
            child: FreeRtosPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture(tester, 'narrow');
    expect(controller.freeRtos.tasks.first.number('cpuPercent'), isNull);
    controller.applyBackendEvent(BackendEventType.freeRtos, {
      ...data,
      'stale': true,
      'status': 'inconsistent',
      'message': '任务链表正在变化。',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('任务链表正在变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  test(
    'snapshot data and layout settings synchronize, only settings persist',
    () {
      final first = TakeALookController(backendCommand: (_, _) async {});
      final replica = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(first.dispose);
      addTearDown(replica.dispose);
      first.setFreeRtosSettings({
        'page': 'objects',
        'columns': {'tasks.name': 190.0},
        'rateHz': 5,
      });
      first.applyBackendEvent(BackendEventType.freeRtos, freeRtosFixture());
      replica.applySnapshot(first.snapshot(includeSamples: false));
      expect(replica.freeRtos.tasks.length, 7);
      expect(replica.freeRtosSettings['rateHz'], 5);
      final project = first.projectSettings();
      expect(project.containsKey('freeRtos'), isFalse);
      expect(project['freeRtosSettings'], containsPair('page', 'objects'));
      project.remove('freeRtosSettings');
      expect(
        () => TakeALookControllerProject.validateProjectSettings(project),
        throwsFormatException,
      );
      expect(FreeRtosSnapshot().number('nonIdlePercent'), isNull);
    },
  );
}
