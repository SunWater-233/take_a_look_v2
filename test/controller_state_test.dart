import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/models/models.dart';

void main() {
  testWidgets(
    'sample bursts keep data immediately but coalesce all display notifications',
    (tester) async {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      controller.loadDemoSymbols();
      controller.toggleSymbol(demoSymbols.first.key);
      controller.addSelectedToWatch();
      controller.applySnapshot({
        'connectionStatus': 'connected',
        'displayRefreshMode': 'standard',
      });
      final key = controller.watches.single.symbol.key;
      var general = 0;
      var telemetry = 0;
      var sync = 0;
      controller.addListener(() => general++);
      controller.telemetryChanges.addListener(() => telemetry++);
      controller.telemetrySyncChanges.addListener(() => sync++);
      for (var i = 0; i < 100; i++) {
        controller.applyBackendSamples({
          'frames': [
            {
              'elapsed': i / 10000,
              'values': {key: i.toDouble()},
            },
          ],
        });
      }
      expect(controller.watches.single.totalSampleCount, 100);
      expect(controller.watches.single.value, 99);
      expect(general, lessThanOrEqualTo(1));
      await tester.pump(const Duration(milliseconds: 17));
      expect(general, greaterThan(0));
      expect(general, lessThanOrEqualTo(2));
      expect(telemetry, general);
      expect(sync, general);
      await tester.pump(const Duration(milliseconds: 17));
      final settled = general;
      await tester.pump(const Duration(milliseconds: 50));
      expect(general, settled);
      controller.dispose();
    },
  );

  test('controller emits only the state domains affected by a command', () {
    final controller = TakeALookController();
    var connectionEvents = 0;
    var samplingEvents = 0;
    var telemetryEvents = 0;
    var symbolEvents = 0;
    var stateSyncEvents = 0;
    controller.connectionChanges.addListener(() => connectionEvents += 1);
    controller.samplingChanges.addListener(() => samplingEvents += 1);
    controller.telemetryChanges.addListener(() => telemetryEvents += 1);
    controller.symbolChanges.addListener(() => symbolEvents += 1);
    controller.stateSyncChanges.addListener(() => stateSyncEvents += 1);

    controller.setSerialNumber('probe-01');
    expect(connectionEvents, 1);
    expect(samplingEvents, 0);
    expect(telemetryEvents, 0);
    expect(symbolEvents, 0);
    expect(stateSyncEvents, 1);

    controller.setSampleRate(200);
    expect(connectionEvents, 1);
    expect(samplingEvents, 1);
    expect(telemetryEvents, 0);
    expect(symbolEvents, 0);
    expect(stateSyncEvents, 2);

    controller.dispose();
  });

  test('plot refresh mode is independent and synchronized in snapshots', () {
    final source = TakeALookController();
    final originalSampleRate = source.sampleRateHz;

    source.setDisplayRefreshMode('high');
    expect(source.displayRefreshMode, 'high');
    expect(source.plotRefreshRateHz, 120);
    expect(source.sampleRateHz, originalSampleRate);
    expect(source.logs.last.message, contains('高频模式（120 Hz）'));

    final target = TakeALookController()..applySnapshot(source.stateSnapshot());
    expect(target.displayRefreshMode, 'high');

    source.setSampleRate(25);
    source.setDisplayRefreshMode('realtime');
    expect(source.plotRefreshRateHz, 25);
    source.setSampleRate(1000);
    expect(source.plotRefreshRateHz, 120);

    expect(() => source.setDisplayRefreshMode('invalid'), throwsArgumentError);
    source.dispose();
    target.dispose();
  });

  test('source root and executable lines are synchronized in snapshots', () {
    const sourcePath = 'C:/build/src/main.c';
    final source = TakeALookController()..setSourceRoot('D:/firmware');
    source.applyDebugState({
      'sourceFiles': [sourcePath],
      'executableLines': {
        sourcePath: [10, 12],
      },
    });

    source.toggleBreakpoint(sourcePath, 11);
    expect(source.debugState.requestedBreakpoints[sourcePath], isNull);
    source.toggleBreakpoint(sourcePath, 12);
    expect(source.debugState.requestedBreakpoints[sourcePath], {12});
    expect(source.executableLinesFor('D:/checkout/src/main.c'), {10, 12});

    final target = TakeALookController()..applySnapshot(source.stateSnapshot());
    expect(target.debugState.sourceRoot, 'D:/firmware');
    expect(target.debugState.executableLines[sourcePath], {10, 12});
    expect(target.debugState.requestedBreakpoints[sourcePath], {12});

    source.dispose();
    target.dispose();
  });

  test('partial backend state only notifies the affected UI domain', () {
    final controller = TakeALookController();
    controller.connectionStatus = ConnectionStatus.connected;
    controller.loadDemoSymbols();
    controller.toggleSymbol(demoSymbols.first.key);
    controller.addSelectedToWatch();
    final symbolRevision = controller.symbolRevision;
    var samplingEvents = 0;
    var symbolEvents = 0;
    var watchEvents = 0;
    var telemetryEvents = 0;
    var plotEvents = 0;
    controller.samplingChanges.addListener(() => samplingEvents += 1);
    controller.symbolChanges.addListener(() => symbolEvents += 1);
    controller.watchChanges.addListener(() => watchEvents += 1);
    controller.telemetryChanges.addListener(() => telemetryEvents += 1);
    controller.plotChanges.addListener(() => plotEvents += 1);

    controller.applySnapshot({'samplingPaused': true});

    expect(controller.connectionStatus, ConnectionStatus.connected);
    expect(controller.symbolRevision, symbolRevision);
    expect(controller.symbols, hasLength(demoSymbols.length));
    expect(controller.watches, hasLength(1));
    expect(samplingEvents, 1);
    expect(symbolEvents, 0);
    expect(watchEvents, 0);
    expect(telemetryEvents, 0);
    expect(plotEvents, 0);
    controller.dispose();
  });

  testWidgets('sampling clock is smooth and plot clock honors refresh mode', (
    tester,
  ) async {
    final controller = TakeALookController();
    controller.loadDemoSymbols();
    controller.toggleSymbol(demoSymbols.first.key);
    controller.addSelectedToWatch();
    controller.setAllWatchesPlotted(true);
    controller.applySnapshot({
      'connectionStatus': 'connected',
      'samplingPaused': false,
    });
    var clockEvents = 0;
    var plotEvents = 0;
    controller.clockChanges.addListener(() => clockEvents += 1);
    controller.plotChanges.addListener(() => plotEvents += 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(clockEvents, inInclusiveRange(9, 11));
    expect(plotEvents, inInclusiveRange(5, 7));

    controller.setDisplayRefreshMode('high');
    plotEvents = 0;
    await tester.pump(const Duration(milliseconds: 100));
    expect(plotEvents, inInclusiveRange(11, 13));

    controller.toggleSampling();
    final pausedElapsed = controller.samplingElapsedSeconds;
    clockEvents = 0;
    await tester.pump(const Duration(milliseconds: 40));
    expect(clockEvents, 0);
    expect(controller.samplingElapsedSeconds, closeTo(pausedElapsed, 0.001));
    controller.dispose();
  });

  test('follow-latest freezes only the viewport while pause freezes data', () {
    final controller = TakeALookController();
    controller.loadDemoSymbols();
    controller.toggleSymbol(demoSymbols.first.key);
    controller.addSelectedToWatch();
    controller.setAllWatchesPlotted(true);
    final key = controller.watches.single.symbol.key;
    controller.applyTelemetrySnapshot({
      'elapsedSeconds': 10,
      'watches': [
        {
          'key': key,
          'value': 1,
          'samples': [
            [9, 0.5],
            [10, 1],
          ],
        },
      ],
    });

    var plotEvents = 0;
    controller.plotChanges.addListener(() => plotEvents += 1);
    controller.toggleFollowLatest();
    expect(controller.followLatest, isFalse);
    expect(controller.plotWindowEndSeconds, 10);
    expect(plotEvents, 1);

    controller.applyTelemetrySnapshot({
      'elapsedSeconds': 20,
      'watches': [
        {
          'key': key,
          'value': 2,
          'samples': [
            [19, 1.5],
            [20, 2],
          ],
        },
      ],
    });
    expect(controller.plotWindowEndSeconds, 10);
    expect(controller.plotSamplesFor(controller.watches.single).last.dx, 20);
    expect(plotEvents, 2);

    controller.toggleFollowLatest();
    expect(controller.plotWindowEndSeconds, 20);
    expect(plotEvents, 3);
    controller.togglePlotting();
    expect(controller.plottingPaused, isTrue);
    expect(controller.plotWindowEndSeconds, 20);
    expect(plotEvents, 4);

    controller.applyTelemetrySnapshot({
      'elapsedSeconds': 30,
      'watches': [
        {
          'key': key,
          'value': 3,
          'samples': [
            [29, 2.5],
            [30, 3],
          ],
        },
      ],
    });
    expect(controller.plotWindowEndSeconds, 20);
    expect(plotEvents, 4);

    controller.togglePlotting();
    expect(controller.plotWindowEndSeconds, 30);
    expect(plotEvents, 5);

    controller.toggleFollowLatest();
    controller.togglePlotting();
    controller.togglePlotting();
    controller.applyTelemetrySnapshot({
      'elapsedSeconds': 40,
      'watches': [
        {
          'key': key,
          'value': 4,
          'samples': [
            [39, 3.5],
            [40, 4],
          ],
        },
      ],
    });
    controller.togglePlotting();
    expect(controller.plotSamplesFor(controller.watches.single).last.dx, 40);
    controller.dispose();
  });

  test('lightweight state snapshots preserve existing telemetry samples', () {
    final source = TakeALookController();
    source.loadDemoSymbols();
    source.toggleSymbol(demoSymbols.first.key);
    source.addSelectedToWatch();
    const customColor = Color(0xFF35A1D2);
    source.watches.single.color = customColor;
    final key = source.watches.single.symbol.key;
    source.applyTelemetrySnapshot({
      'elapsedSeconds': 2,
      'watches': [
        {
          'key': key,
          'value': 4,
          'samples': [
            [1, 3],
            [2, 4],
          ],
        },
      ],
    });

    final lightweight = source.stateSnapshot();
    final watchState = (lightweight['watches'] as List).single as Map;
    expect(watchState.containsKey('samples'), isFalse);

    final target = TakeALookController()..applySnapshot(source.snapshot());
    expect(target.watches.single.color, customColor);
    expect(target.watches.single.samples, hasLength(2));
    final sampleCursor = target.watches.single.totalSampleCount;
    source.setSerialNumber('probe-02');
    target.applySnapshot(source.stateSnapshot());
    expect(target.watches.single.color, customColor);
    expect(target.serialNumber, 'probe-02');
    expect(target.watches.single.samples, hasLength(2));
    expect(target.watches.single.totalSampleCount, sampleCursor);

    source.dispose();
    target.dispose();
  });

  test(
    'telemetry deltas append once, clear, and recover after retention loss',
    () {
      final source = TakeALookController();
      source.loadDemoSymbols();
      source.toggleSymbol(demoSymbols.first.key);
      source.addSelectedToWatch();
      final key = source.watches.single.symbol.key;
      source.configurePlotView({'plotRetentionSeconds': 1});
      source.setSampleRate(1000);
      source.applyBackendEvent(BackendEventType.samples, {
        'frames': [
          {
            'elapsed': 1,
            'values': {key: 1},
          },
        ],
      });
      final target = TakeALookController()..applySnapshot(source.snapshot());
      var cursor = source.telemetryCursors();

      source.applyBackendEvent(BackendEventType.samples, {
        'frames': [
          {
            'elapsed': 2,
            'values': {key: 2},
          },
        ],
      });
      final delta = source.telemetryDeltaSnapshot(cursor);
      expect(
        ((delta['watches'] as List).single as Map)['samples'],
        hasLength(1),
      );
      target.applyTelemetryDelta(delta);
      target.applyTelemetryDelta(delta);
      expect(target.watches.single.samples, hasLength(2));
      expect(target.watches.single.value, 2);

      cursor = source.telemetryCursors();
      source.applyBackendSamplesCleared();
      final cleared = source.telemetryDeltaSnapshot(cursor);
      expect(((cleared['watches'] as List).single as Map)['reset'], isTrue);
      target.applyTelemetryDelta(cleared);
      expect(target.watches.single.samples, isEmpty);

      source.applyBackendEvent(BackendEventType.samples, {
        'frames': [
          for (var index = 0; index < 1801; index += 1)
            {
              'elapsed': index / 1000,
              'values': {key: index},
            },
        ],
      });
      final recovered = source.telemetryDeltaSnapshot({key: 0});
      final recoveredWatch = (recovered['watches'] as List).single as Map;
      expect(recoveredWatch['reset'], isTrue);
      expect(recoveredWatch['samples'], hasLength(1001));
      target.applyTelemetryDelta(recovered);
      expect(target.watches.single.samples, hasLength(1001));
      expect(target.watches.single.totalSampleCount, 1801);

      source.dispose();
      target.dispose();
    },
  );
}
