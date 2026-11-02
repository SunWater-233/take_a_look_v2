import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_transport.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  TakeALookController fixture({
    Future<void> Function(ControllerCommand, Object?)? command,
  }) {
    final controller = TakeALookController(
      backendCommand: command ?? (_, _) async {},
    );
    controller.loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch(mode: WatchReadMode.monitor);
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'joining capture from monitoring enables plotting by default',
    () {
      final c = fixture();
      final watch = c.watches.single;
      final key = watch.symbol.key;
      c.setWatchReadMode(key, WatchReadMode.capture);
      expect(watch.samplingEnabled, isTrue);
      expect(watch.plotted, isTrue);
      c.toggleWatchPlot(key, true);
      expect(watch.plotted, isTrue);
      expect(watch.samplingEnabled, isTrue);
      c.toggleWatchPlot(key, false);
      expect(watch.samplingEnabled, isTrue);
      c.setWatchReadMode(key, WatchReadMode.capture);
      expect(watch.plotted, isFalse);
      c.toggleWatchSampling(key, false);
      expect(watch.plotted, isFalse);
      c.toggleWatchSampling(key, true);
      expect(watch.samplingEnabled, isTrue);
      expect(watch.plotted, isTrue);
      c.selectSymbols([demoSymbols[1].key]);
      c.addSelectedToWatch(mode: WatchReadMode.capture);
      expect(c.watches.last.samplingEnabled, isTrue);
      expect(c.watches.last.plotted, isFalse);
    },
  );

  test(
    'hidden captures keep every sample when their curves are shown again',
    () {
      final c = fixture();
      final watch = c.watches.single;
      final key = watch.symbol.key;
      c.setWatchReadMode(key, WatchReadMode.capture);
      for (var i = 1; i <= 3; i++) {
        if (i == 2) c.toggleWatchPlot(key, true);
        if (i == 3) c.toggleWatchPlot(key, false);
        c.applyBackendSamples({
          'captureOnly': true,
          'frames': [
            {
              'elapsed': i.toDouble(),
              'values': {key: i * 10.0},
            },
          ],
        });
      }
      c.toggleWatchPlot(key, true);
      expect(watch.readMode, WatchReadMode.capture);
      expect(watch.samples.map((point) => point.dy), [10, 20, 30]);
      expect(watch.totalSampleCount, 3);
    },
  );

  test(
    'detached windows keep capture active while toggling curve visibility',
    () async {
      final c = fixture();
      final key = c.watches.single.symbol.key;
      late final TakeALookController detached;
      detached = TakeALookController(
        remoteCommand: (command, args) async {
          detached.applySnapshot(await c.handleCommand(command, args));
        },
      )..applySnapshot(c.stateSnapshot());
      addTearDown(detached.dispose);
      detached.setWatchReadMode(key, WatchReadMode.capture);
      await Future<void>.delayed(Duration.zero);
      expect(detached.watches.single.samplingEnabled, isTrue);
      expect(detached.watches.single.plotted, isTrue);
      detached.toggleWatchPlot(key, true);
      await Future<void>.delayed(Duration.zero);
      expect(c.watches.single.plotted, isTrue);
      detached.toggleWatchPlot(key, false);
      await Future<void>.delayed(Duration.zero);
      expect(c.watches.single.samplingEnabled, isTrue);
      expect(detached.watches.single.samplingEnabled, isTrue);
      expect(c.watches.single.plotted, isFalse);
      expect(detached.watches.single.plotted, isFalse);
    },
  );

  test(
    'latest-only updates preserve history and mode changes never backfill',
    () {
      final controller = fixture();
      final watch = controller.watches.single;
      void latest(int stamp, double value) => controller.applyWatchValues({
        'values': [
          {'key': watch.symbol.key, 'value': value, 'updatedAtMs': stamp},
        ],
      });
      latest(100, 7);
      expect(watch.samples, isEmpty);
      controller.setWatchReadMode(watch.symbol.key, WatchReadMode.capture);
      controller.applyBackendSamples({
        'captureOnly': true,
        'updatedAtMs': 200,
        'frames': [
          {
            'elapsed': 1.0,
            'values': {watch.symbol.key: 10.0},
          },
          {
            'elapsed': 2.0,
            'values': {watch.symbol.key: 11.0},
          },
        ],
      });
      expect(
        watch.value,
        11,
        reason: 'The last frame of one timestamped batch is current.',
      );
      controller.toggleWatchPlot(watch.symbol.key, false);
      expect(watch.readMode, WatchReadMode.capture);
      controller.setWatchReadMode(watch.symbol.key, WatchReadMode.manual);
      latest(300, 42);
      latest(250, 30);
      expect(watch.value, 42);
      expect(watch.samples.map((point) => point.dy), [10, 11]);
      controller.setAllWatchesPlotted(true);
      expect(watch.plotted, isFalse);
      expect(watch.readMode, WatchReadMode.manual);
    },
  );

  test(
    'delayed captured batch keeps history without undoing a newer readback',
    () {
      final controller = fixture();
      final watch = controller.watches.single;
      controller.applyWatchValues({
        'values': [
          {'key': watch.symbol.key, 'value': 42.0, 'updatedAtMs': 300},
        ],
      });
      final payload = ByteData(40)
        ..setUint8(0, 2)
        ..setUint32(1, 1, Endian.little)
        ..setUint32(5, 2, Endian.little)
        ..setUint32(9, 1, Endian.little)
        ..setUint16(13, 1, Endian.little)
        ..setUint64(15, 300, Endian.little)
        ..setFloat64(23, 1.0, Endian.little)
        ..setUint8(31, 1)
        ..setFloat64(32, 9.0, Endian.little);
      final batch = decodeBackendSamplePayload(payload.buffer.asUint8List(), [
        watch.symbol.key,
      ]);
      expect(batch.captureOnly, isTrue);
      controller.applyBackendSampleBatch(batch);
      expect(
        watch.value,
        42,
        reason:
            'Even an equal-millisecond queued capture cannot replace a readback.',
      );
      expect(watch.samples.single.dy, 9);
      expect(watch.totalSampleCount, 1);
      expect(watch.readMode, WatchReadMode.monitor);
    },
  );

  test('read policies round-trip to backend and detached windows', () {
    final commands = <(ControllerCommand, Object?)>[];
    final controller = fixture(
      command: (method, data) async {
        commands.add((method, data));
      },
    );
    final key = controller.watches.single.symbol.key;
    controller.setMonitorRate(5);
    expect(commands.last.$1, ControllerCommand.setMonitorRate);
    controller.applySnapshot({'monitorRateHz': 5});
    controller.setWatchMonitorRate(key, .5);
    controller.setWatchReadMode(key, WatchReadMode.manual);
    controller.readWatch(key);
    final watchCommand =
        (commands
                    .lastWhere(
                      (command) => command.$1 == ControllerCommand.setWatches,
                    )
                    .$2
                as Map)['watches']
            as List;
    expect((watchCommand.single as Map)['readMode'], 'manual');
    expect((watchCommand.single as Map)['monitorRateHz'], .5);
    expect(commands.last.$1, ControllerCommand.readWatch);
    final remote = TakeALookController()
      ..applySnapshot(controller.stateSnapshot());
    addTearDown(remote.dispose);
    expect(remote.monitorRateHz, 5);
    expect(remote.watches.single.readMode, WatchReadMode.manual);
    expect(remote.watches.single.monitorRateHz, .5);
  });
}
