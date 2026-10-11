import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/downsampling.dart';
import 'package:take_a_look_v2/src/chart/viewport.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';
import 'package:take_a_look_v2/src/telemetry/raw_recording.dart';

void main() {
  test(
    'write readbacks are recorded without merging equal timestamps',
    () async {
      final directory = Directory.systemTemp.createTempSync('tal_readback_');
      final lab = UiTestSession(
        sourcePath: 'fixture.c',
        recordingDirectory: directory,
      );
      addTearDown(() {
        lab.dispose();
        directory.deleteSync(recursive: true);
      });
      final controller = lab.controller;
      controller.toggleSampling();
      final watch = controller.watches.first;
      controller.writeWatch(watch.symbol.key, '42.5');
      expect(watch.totalSampleCount, 401);
      expect(lab.recording.sampleCount, 401);
      controller.toggleWatchSampling(watch.symbol.key, false);
      controller.writeWatch(watch.symbol.key, '8.5');
      expect(watch.value, 8.5);
      expect(lab.recording.sampleCount, 401);
      final csv = File('${directory.path}/readbacks.csv');
      expect(await lab.recording.exportCsv(csv.path), 401);
      final lines = await csv.readAsLines();
      expect(lines.length, 402);
      final finalRow = lines.last.split(',');
      expect(finalRow.first, '4.000000000');
      expect(finalRow[1], '"42.5"');
      expect(finalRow.skip(2).every((value) => value.isEmpty), isTrue);
    },
  );

  testWidgets(
    '32-channel stress keeps the viewport and exports all history after rollover',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('tal_retention_');
      final lab = UiTestSession(
        sourcePath: 'fixture.c',
        recordingDirectory: directory,
      );
      addTearDown(() {
        lab.dispose();
        directory.deleteSync(recursive: true);
      });
      lab.reset(UiTestScenario.dense);
      final controller = lab.controller;
      final first = controller.watches.first.samples.first;
      expect(controller.watches.first.samples.capacity, 60001);
      await tester.pump(const Duration(milliseconds: 3800));
      final watch = controller.watches.first;
      expect(watch.totalSampleCount, 4200);
      expect(watch.samples.length, 4200);
      expect(watch.samples.first, first);
      final viewport = telemetryViewport(controller, const Size(1547, 510));
      final reduced = downsampleTelemetrySamples(
        watch.samples,
        xMin: viewport.xMin,
        xMax: viewport.xMax,
        pixelWidth: 500,
      );
      expect(viewport.xMin, 0);
      expect(viewport.xMax, closeTo(7.8, 1e-8));
      expect(reduced.first, first);
      expect(reduced.length, lessThanOrEqualTo(1002));

      controller.configurePlotView({'plotRetentionSeconds': 10});
      await tester.pump(const Duration(seconds: 10));
      controller.toggleSampling();
      expect(watch.totalSampleCount, 14200);
      expect(watch.samples.length, 10001);
      expect(watch.samples.first.dx, closeTo(7.8, 1e-8));
      expect(watch.samples.last.dx, closeTo(17.8, 1e-8));
      expect(lab.recording.sampleCount, 14200);

      final detached = TakeALookController(remoteCommand: (_, _) async {});
      detached.applySnapshot(controller.snapshot());
      expect(detached.plotRetentionSeconds, 10);
      expect(detached.watches.first.samples.toList(), watch.samples.toList());
      expect(detached.telemetrySnapshot()['watches'], isNotEmpty);
      detached.dispose();

      final originalPath = lab.recording.path!;
      await tester.runAsync(() async {
        final csv = File('${directory.path}/full.csv');
        final export = lab.recording.exportCsv(csv.path);
        // Clearing while CSV conversion runs must keep the captured file intact.
        controller.clearSamples();
        expect(lab.recording.sampleCount, 0);
        expect(watch.samples, isEmpty);
        expect(await export, 14200);
        final lines = await csv.readAsLines();
        expect(lines.length, 14201);
        expect(lines.first.split(','), hasLength(33));
        expect(double.parse(lines[1].split(',').first), first.dx);
        expect(
          double.parse(lines[1].split(',')[1].replaceAll('"', '')),
          first.dy,
        );
        expect(double.parse(lines.last.split(',').first), closeTo(17.8, 1e-8));
        expect(File(originalPath).existsSync(), isTrue);
        expect(
          await exportRawRecordingCsv(
            originalPath,
            '${directory.path}/reopened.csv',
          ),
          14200,
        );
      });
      lab.dispose();
    },
  );

  testWidgets('recording errors stop sampling and are explicit', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'tal_recording_error_',
    );
    final blocked = File('${directory.path}/blocked')
      ..writeAsStringSync('file');
    final lab = UiTestSession(
      sourcePath: 'fixture.c',
      recordingDirectory: Directory(blocked.path),
    );
    addTearDown(() {
      lab.dispose();
      directory.deleteSync(recursive: true);
    });
    expect(lab.controller.samplingPaused, isTrue);
    expect(lab.controller.lastBackendError?['code'], 'raw_recording_failed');
    lab.controller.toggleSampling();
    await tester.pump(const Duration(milliseconds: 100));
    expect(lab.controller.samplingPaused, isTrue);
    expect(lab.recording.sampleCount, 0);
    expect(lab.controller.watches.first.samples, isEmpty);
    lab.dispose();
  });

  test(
    'raw records preserve duplicates, sparse channels and export snapshots',
    () async {
      final directory = Directory.systemTemp.createTempSync('tal_raw_');
      final recording = RawSampleRecording(directory);
      addTearDown(() {
        recording.close();
        directory.deleteSync(recursive: true);
      });
      recording.append(
        [
          {
            'elapsed': 1.0,
            'values': <String, double>{'a': 1},
          },
          {
            'elapsed': 1.0,
            'values': <String, double>{'a': 2},
          },
        ],
        {'a': 'a,"标量"'},
      );
      final csv = File('${directory.path}/snapshot.csv');
      final exporting = recording.exportCsv(csv.path);
      recording.append(
        [
          {
            'elapsed': 2.0,
            'values': <String, double>{'b': 3},
          },
        ],
        {'b': 'b'},
      );
      expect(await exporting, 2);
      final snapshot = await csv.readAsLines();
      expect(snapshot.first, 'elapsed_seconds,"a,""标量"""');
      expect(snapshot[1], '1.000000000,"1.0"');
      expect(snapshot[2], '1.000000000,"2.0"');
      final path = recording.path!;
      recording.close();
      expect(await exportRawRecordingCsv(path, '${directory.path}/all.csv'), 3);
      expect(await File('${directory.path}/all.csv').readAsLines(), [
        'elapsed_seconds,"a,""标量""","b"',
        '1.000000000,"1.0",',
        '1.000000000,"2.0",',
        '2.000000000,,"3.0"',
      ]);
    },
  );
}
