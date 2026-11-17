import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/telemetry/numeric_history.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

const oldKey = '20000004:motor.old';
const keptKey = '20000008:motor.kept';
Map<String, dynamic> definition(
  String name,
  String key,
  int address, {
  bool missing = false,
}) => {
  'source': 'motor.c',
  'name': name,
  'key': key,
  'address': address,
  'size': 4,
  'type': 'float',
  'section': '.data',
  'encoding': 'float',
  'missing': missing,
  'writable': !missing,
};

Map<String, dynamic> snapshot({bool missing = false}) => {
  'rawRecording': {'historyPath': 'old/history'},
  'symbols': [
    definition('motor.old', oldKey, 0x20000004, missing: missing),
    definition('motor.kept', keptKey, 0x20000008),
  ],
  'watches': [
    for (final key in [oldKey, keptKey])
      {'key': key, 'readMode': 'capture', 'plotted': true, 'color': '#123456'},
  ],
};

Widget harness(TakeALookController c, TalInputMode mode) => MaterialApp(
  theme: buildTalTheme().copyWith(extensions: [TalUiTheme(inputMode: mode)]),
  home: Scaffold(
    body: WorkbenchFeedback(
      controller: c,
      showFirmwareChanges: false,
      child: const Align(
        alignment: Alignment.topLeft,
        child: Text('workbench'),
      ),
    ),
  ),
);

void main() {
  for (final mode in TalInputMode.values) {
    testWidgets('$mode missing members use a yellow non-modal warning once', (
      tester,
    ) async {
      final c = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(c.dispose);
      c.applySnapshot(snapshot());
      await tester.pumpWidget(harness(c, mode));
      final barriers = find.byType(ModalBarrier).evaluate().length;
      c.applySnapshot(snapshot(missing: true));
      await tester.pumpAndSettle();
      final popup = find.byKey(const ValueKey('tal-warning-popup'));
      expect(popup, findsOneWidget);
      expect(find.byKey(const ValueKey('tal-error-popup')), findsNothing);
      expect(find.byType(ModalBarrier), findsNWidgets(barriers));
      final material = tester.widget<Material>(popup);
      expect(
        (material.shape! as RoundedRectangleBorder).side.color,
        TalColors.warning,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded)).color,
        TalColors.warning,
      );
      expect(c.lastBackendError, isNull);
      expect(c.logs.last.level, LogLevel.warning);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('motor.old（motor.c）'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      final warning = c.watchRefreshWarning;
      c.applySnapshot(snapshot(missing: true));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(c.watchRefreshWarning, same(warning));
      // A later disappearance after recovery is a new warning.
      c.applySnapshot(snapshot());
      c.applySnapshot(snapshot(missing: true));
      await tester.pumpAndSettle();
      expect(popup, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'missing curves survive refresh, recording rotation and detached sync',
    (tester) async {
      final reads = <HistoryRequest>[];
      final commands = <ControllerCommand>[];
      final c = TakeALookController(
        backendCommand: (command, _) async => commands.add(command),
        historyReader: (request) async {
          reads.add(request);
          return HistoryWindow(
            request: request,
            reduced: false,
            series: {
              oldKey: Float64List.fromList([1, 11, 75, 22]),
            },
          );
        },
      );
      addTearDown(c.dispose);
      c.applySnapshot(snapshot());
      c.configurePlotView({'plotRetentionSeconds': 1});
      c.applyBackendSamples({
        'captureOnly': true,
        'frames': [
          {
            'elapsed': 1.0,
            'values': {oldKey: 11.0, keptKey: 1.0},
          },
          {
            'elapsed': 75.0,
            'values': {oldKey: 22.0, keptKey: 2.0},
          },
        ],
      });
      c.watchInputDrafts[oldKey] = '42';
      c.applySnapshot(snapshot(missing: true));
      final missing = c.watches.first;
      expect(missing.symbol.missing, isTrue);
      expect(missing.valueLabel, '新固件中不存在');
      expect(missing.plotted, isTrue);
      expect(missing.samples.last.dy, 22);
      expect(c.watchInputDrafts[oldKey], '42');
      final before = commands.length;
      c.readWatch(oldKey);
      expect(await c.writeWatch(oldKey, '100'), isFalse);
      expect(commands.length, before);
      c.applyBackendSamples({
        'captureOnly': true,
        'frames': [
          {
            'elapsed': 76.0,
            'values': {oldKey: 99.0},
          },
        ],
      });
      expect(missing.samples.last.dy, 22);
      c.applyBackendEvent(BackendEventType.samplesCleared, {
        'preserveMissing': true,
      });
      expect(missing.samples.last.dy, 22);
      expect(c.watches.last.samples, isEmpty);
      expect(missing.archivedHistoryPath, 'old/history');
      c.applySnapshot({
        'rawRecording': {'historyPath': 'new/history'},
      });
      c.showAllPlotSamples();
      c.preparePlotHistory(pixelWidth: 800);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(
        reads.any((r) => r.path == 'old/history' && r.keys.contains(oldKey)),
        isTrue,
      );
      expect(c.plotSamplesFor(missing).map((p) => p.dy), [11, 22]);
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(detached.dispose);
      detached.applySnapshot(c.snapshot());
      expect(detached.watches.first.symbol.missing, isTrue);
      expect(detached.watches.first.samples.last.dy, 22);
      expect(detached.watches.first.archivedHistoryPath, 'old/history');
      expect(detached.watchRefreshWarning, isNull);
      // Explicit clear remains an intentional clear of all curves.
      c.applyBackendSamplesCleared();
      expect(c.watches.first.samples, isEmpty);
      expect(c.watches.first.archivedHistoryPath, isNull);
      c.setPresentationActive(false);
      detached.setPresentationActive(false);
      detached.preparePlotHistory();
      c.preparePlotHistory();
    },
  );
}
