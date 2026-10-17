import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/ui_test/ui_test_session.dart';

void main() {
  UiTestSession session() {
    final directory = Directory.systemTemp.createTempSync(
      'tal_session_recording_',
    );
    final lab = UiTestSession(
      sourcePath: 'test/fixtures/debug_source.c',
      stepDelay: const Duration(milliseconds: 10),
      recordingDirectory: directory,
    );
    addTearDown(() {
      lab.dispose();
      directory.deleteSync(recursive: true);
    });
    return lab;
  }

  testWidgets('sampling respects pause, per-watch enable, rate and writes', (
    tester,
  ) async {
    final lab = session();
    addTearDown(lab.dispose);
    final controller = lab.controller;
    final watch = controller.watches.first;
    final initial = watch.totalSampleCount;
    await tester.pump(const Duration(milliseconds: 100));
    expect(watch.totalSampleCount, initial + 10);
    controller.toggleSampling();
    await tester.pump(const Duration(milliseconds: 100));
    expect(watch.totalSampleCount, initial + 10);
    controller.toggleSampling();
    controller.toggleWatchSampling(watch.symbol.key, false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(watch.totalSampleCount, initial + 10);
    controller.toggleWatchSampling(watch.symbol.key, true);
    expect(await controller.writeWatch(watch.symbol.key, '42.5'), isTrue);
    controller.setSampleRate(1000);
    final before = watch.totalSampleCount;
    await tester.pump(const Duration(milliseconds: 100));
    expect(watch.totalSampleCount, before + 100);
    expect(watch.value, 42.5);
    expect(await controller.writeWatch(watch.symbol.key, 'NaN'), isFalse);
    expect(controller.lastBackendError?['code'], 'ui_test_write_failed');
    controller.clearSamples();
    expect(watch.totalSampleCount, 0);
    expect(watch.samples, isEmpty);
    lab.dispose();
  });

  testWidgets('disconnect and source control stop and restore samples', (
    tester,
  ) async {
    final lab = session();
    addTearDown(lab.dispose);
    final controller = lab.controller;
    controller.haltTarget();
    final count = controller.watches.first.totalSampleCount;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.watches.first.totalSampleCount, count);
    expect(controller.debugState.currentLine, 10);
    controller.stepTarget();
    expect(controller.debugState.currentLine, 11);
    controller.toggleBreakpoint(lab.sourcePath, 12);
    expect(controller.debugState.resolvedBreakpoints.single.verified, isTrue);
    controller.resumeTarget();
    await tester.pump(const Duration(milliseconds: 40));
    expect(controller.watches.first.totalSampleCount, greaterThan(count));
    lab.injectDisconnect();
    expect(controller.connectionStatus, ConnectionStatus.disconnected);
    expect(controller.lastBackendError?['code'], 'ui_test_disconnect');
    controller.toggleConnection();
    expect(controller.connectionStatus, ConnectionStatus.connecting);
    await tester.pump(const Duration(milliseconds: 10));
    expect(controller.connectionStatus, ConnectionStatus.connected);
    expect(controller.lastBackendError, isNull);
    lab.dispose();
  });

  testWidgets(
    'failed load preserves data and successful load finishes progress',
    (tester) async {
      final lab = session();
      addTearDown(lab.dispose);
      final controller = lab.controller;
      final watchedKeys = controller.watches
          .map((watch) => watch.symbol.key)
          .toList();
      final failure = lab.simulateLoad(fail: true);
      expect(controller.isSymbolLoading, isTrue);
      lab.reset(UiTestScenario.empty);
      expect(lab.scenario, UiTestScenario.live);
      for (var index = 0; index < 4; index++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await failure;
      expect(controller.symbolLoadProgress!.status, SymbolLoadStatus.failed);
      expect(controller.watches.map((watch) => watch.symbol.key), watchedKeys);
      final success = lab.simulateLoad();
      for (var index = 0; index < 6; index++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await success;
      expect(controller.symbolLoadProgress!.status, SymbolLoadStatus.complete);
      expect(controller.lastBackendError, isNull);
      lab.dispose();
    },
  );

  testWidgets(
    'scenario reset cancels an old connect and isolates stress data',
    (tester) async {
      final lab = session();
      addTearDown(lab.dispose);
      lab.reset(UiTestScenario.disconnected);
      lab.controller.toggleConnection();
      lab.reset(UiTestScenario.empty);
      await tester.pump(const Duration(milliseconds: 20));
      expect(lab.controller.connectionStatus, ConnectionStatus.disconnected);
      expect(lab.controller.symbols, isEmpty);
      expect(lab.controller.watches, isEmpty);
      lab.reset(UiTestScenario.dense);
      expect(lab.controller.symbols.length, 512);
      expect(lab.controller.watches.length, 32);
      lab.reset(UiTestScenario.live);
      expect(lab.controller.symbols.length, 12);
      expect(lab.controller.watches.length, 6);
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      detached.applySnapshot(lab.controller.snapshot());
      expect(detached.watches.length, 6);
      expect(detached.watches.first.samples, isNotEmpty);
      lab.controller.setRemoteConfig({'token': 'test-secret'});
      expect(lab.diagnostics().toString(), isNot(contains('test-secret')));
      detached.dispose();
      lab.dispose();
    },
  );

  testWidgets('disposing during load or connect does not emit late events', (
    tester,
  ) async {
    final lab = session();
    final load = lab.simulateLoad();
    lab.dispose();
    await tester.pump(const Duration(milliseconds: 20));
    await load;
    expect(tester.takeException(), isNull);
  });

  test(
    'exported fixture samples can be imported by the real analysis parser',
    () async {
      final directory = Directory.systemTemp.createTempSync('tal_ui_csv_');
      final lab = session();
      addTearDown(() {
        lab.dispose();
        directory.deleteSync(recursive: true);
      });
      lab.controller.toggleSampling();
      final file = File('${directory.path}/samples.csv');
      await lab.controller.backendCommand!(
        ControllerCommand.exportCsv,
        file.path,
      );
      final series = parseAnalysisCsv(
        await file.readAsString(),
        colors: seriesColors,
      );
      expect(series.map((item) => item.name), contains('iq_ref'));
      expect(series.first.points.length, 400);
    },
  );
}
