import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend_client.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/models.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  test(
    'fragmented stderr keeps pyOCD levels without guessing from text',
    () async {
      final wire = utf8.encode(
        '[WARNING] Invalid coresight component, cidr=0x0\r\n'
        '[INFO] No memory transfer errors\n'
        '[ERROR] Error attempting to probe CoreSight component: FAULT ACK\n'
        '[DEBUG] 扫描 ROM table\n'
        '[CRITICAL] Probe unavailable\n'
        'Traceback (most recent call last):\n'
        '\n',
      );
      final logs =
          await Stream<List<int>>.fromIterable([
                for (var offset = 0; offset < wire.length; offset += 7)
                  wire.sublist(offset, (offset + 7).clamp(0, wire.length)),
              ])
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .map(decodeBackendStderrLine)
              .where((log) => log != null)
              .map((log) => log!)
              .toList();

      expect(logs.map((log) => log.level), [
        'warning',
        'info',
        'error',
        'debug',
        'critical',
        'error',
      ]);
      expect(logs.first.message, 'Invalid coresight component, cidr=0x0');
      expect(logs[3].message, '扫描 ROM table');
      expect(decodeBackendStderrLine(' [WARNING]  '), isNull);
    },
  );

  test(
    'log levels survive window snapshots and older logs default to info',
    () {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      final replica = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(controller.dispose);
      addTearDown(replica.dispose);
      controller.clearLogs();
      controller.applyBackendEvent(BackendEventType.log, {
        'level': 'warning',
        'message': 'Invalid coresight component, cidr=0x0',
      });
      controller.applyBackendEvent(BackendEventType.error, {
        'code': 'connect_failed',
        'message': '连接调试探针失败',
      });
      replica.applySnapshot(controller.snapshot(includeSamples: false));

      expect(replica.logs.map((log) => log.level), [
        LogLevel.warning,
        LogLevel.error,
      ]);
      expect(
        LogEntry.fromJson({'timestamp': 0, 'message': 'legacy log'}).level,
        LogLevel.info,
      );
    },
  );

  testWidgets('stderr warnings, errors, and connection info remain distinct', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.clearLogs();
    for (final line in [
      '[WARNING] Invalid coresight component, cidr=0x0',
      '[ERROR] Error attempting to probe CoreSight component: FAULT ACK',
    ]) {
      final log = decodeBackendStderrLine(line)!;
      controller.applyBackendEvent(BackendEventType.log, {
        'level': log.level,
        'message': '后端：${log.message}',
      });
    }
    controller.applyBackendEvent(BackendEventType.log, {
      'level': 'info',
      'message': '已连接 pyOCD 调试探针。',
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.log, controller),
        ),
      ),
    );
    final warning = find.textContaining('[WARNING] 后端：Invalid coresight');
    final error = find.textContaining('[ERROR] 后端：Error attempting');
    final info = find.textContaining('[INFO] 已连接 pyOCD 调试探针。');
    expect(tester.widget<Text>(warning).style?.color, TalColors.amber);
    expect(tester.widget<Text>(error).style?.color, TalColors.accent);
    expect(tester.widget<Text>(info).style?.color, TalColors.text);
    expect(controller.lastBackendError, isNull);
  });
}
