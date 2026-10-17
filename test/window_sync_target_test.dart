import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/window_sync_target.dart';

TakeALookController source() {
  final controller = TakeALookController(backendCommand: (_, _) async {});
  controller.applySnapshot({
    'symbols': [
      {
        'key': 'a',
        'source': 'fixture.c',
        'name': 'a',
        'address': 0,
        'type': 'float',
        'size': 4,
      },
    ],
    'watches': [
      {'key': 'a', 'sampling': true, 'plotted': true, 'color': 0xFF0080FF},
    ],
  });
  return controller;
}

void append(TakeALookController controller, List<double> times) {
  controller.applyBackendSamples({
    'frames': [
      for (final t in times)
        {
          'elapsed': t,
          'values': {'a': t * 2},
        },
    ],
  });
}

void receive(
  TakeALookController controller,
  String method,
  Map<String, dynamic> data,
) {
  if (method == 'state') {
    controller.applySnapshot(data);
  } else {
    controller.applyTelemetryDelta(data);
  }
}

void main() {
  test(
    'undo restores full remote data when only deletion metadata was delivered',
    () async {
      final controller = source();
      final replica = TakeALookController(remoteCommand: (_, _) async {});
      final target = WindowSyncTarget(
        controller,
        (method, data) async => receive(replica, method, data),
      );
      addTearDown(controller.dispose);
      addTearDown(replica.dispose);
      addTearDown(target.dispose);
      append(controller, [1, 2]);
      await target.initialize(includeHistory: true, includeAnalysis: false);
      controller.removeWatch('a');
      await target.flushState();
      expect(replica.watches, isEmpty);
      append(controller, [3]);
      controller.undoWatchDeletion();
      target.requestTelemetry();
      await target.settled;
      expect(replica.watches.single.samples.map((point) => point.dx), [
        1,
        2,
        3,
      ]);
    },
  );

  test('state patches omit unchanged symbols and source indexes', () {
    final controller = source();
    final replica = TakeALookController(remoteCommand: (_, _) async {});
    addTearDown(controller.dispose);
    addTearDown(replica.dispose);
    replica.applySnapshot(controller.snapshot());
    final versions = controller.snapshotVersions();
    controller.addLog('new log');
    final patch = controller.stateDeltaSnapshot(versions);
    expect(patch, contains('logs'));
    for (final field in [
      'symbols',
      'watches',
      'debug',
      'analysisSession',
      'sourceWorkspace',
    ]) {
      expect(patch, isNot(contains(field)));
    }
    replica.applySnapshot(patch);
    expect(replica.logs.last.message, 'new log');
    controller.toggleWatchPlot('a', false);
    replica.applySnapshot(controller.stateDeltaSnapshot(versions));
    expect(replica.watches.single.plotted, isFalse);
    expect(replica.symbols.single.key, 'a');
  });

  test(
    'packed snapshots retain duplicate timestamps and retry deltas once',
    () {
      final controller = source();
      final replica = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(controller.dispose);
      addTearDown(replica.dispose);
      append(controller, [1, 1, 2]);
      final snapshot = controller.snapshot(packedSamples: true);
      expect(
        ((snapshot['watches'] as List).single as Map)['samples'],
        isA<Float64List>(),
      );
      replica.applySnapshot(snapshot);
      final cursors = controller.telemetryCursors();
      append(controller, [2, 3]);
      final delta = controller.telemetryDeltaSnapshot(
        cursors,
        packedSamples: true,
      );
      replica.applyTelemetryDelta(delta);
      replica.applyTelemetryDelta(delta);
      expect(
        replica.watches.single.samples.toList(),
        controller.watches.single.samples.toList(),
      );
      expect(replica.watches.single.totalSampleCount, 5);
    },
  );

  test(
    'slow windows do not hold other recipients and pending states coalesce',
    () async {
      final controller = source();
      addTearDown(controller.dispose);
      final gate = Completer<void>();
      final slowMessages = <Map<String, dynamic>>[];
      final fastReplica = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(fastReplica.dispose);
      final slow = WindowSyncTarget(controller, (method, data) async {
        slowMessages.add(data);
        if (slowMessages.length == 1) await gate.future;
      });
      final fast = WindowSyncTarget(controller, (method, data) async {
        receive(fastReplica, method, data);
      });
      addTearDown(slow.dispose);
      addTearDown(fast.dispose);
      final pending = slow.initialize(
        includeHistory: true,
        includeAnalysis: false,
      );
      await fast.initialize(includeHistory: true, includeAnalysis: false);
      for (var i = 0; i < 100; i++) {
        controller.addLog('entry $i');
        slow.requestState();
      }
      fast.requestState();
      await fast.settled;
      expect(fastReplica.logs.last.message, 'entry 99');
      expect(slowMessages, hasLength(1));
      gate.complete();
      await pending;
      await slow.settled;
      expect(slowMessages, hasLength(2));
      expect(slowMessages.last, isNot(contains('symbols')));
      expect(
        (slowMessages.last['logs'] as List).last,
        containsPair('message', 'entry 99'),
      );
    },
  );

  test('lost sample acknowledgements recover without duplication', () async {
    final controller = source();
    final replica = TakeALookController(remoteCommand: (_, _) async {});
    addTearDown(controller.dispose);
    addTearDown(replica.dispose);
    var fail = true;
    final target = WindowSyncTarget(controller, (method, data) async {
      receive(replica, method, data);
      if (method == 'telemetryDelta' && fail) {
        fail = false;
        throw StateError('lost ack');
      }
    });
    addTearDown(target.dispose);
    append(controller, [1]);
    await target.initialize(includeHistory: true, includeAnalysis: false);
    append(controller, [2, 2]);
    target.requestTelemetry();
    await target.settled;
    append(controller, [3]);
    target.requestTelemetry();
    await target.settled;
    expect(
      replica.watches.single.samples.toList(),
      controller.watches.single.samples.toList(),
    );
    expect(replica.watches.single.totalSampleCount, 4);
  });

  test('values-only windows receive full history on reassignment', () async {
    final controller = source();
    final replica = TakeALookController(remoteCommand: (_, _) async {});
    addTearDown(controller.dispose);
    addTearDown(replica.dispose);
    append(controller, [1, 2]);
    final target = WindowSyncTarget(
      controller,
      (method, data) async => receive(replica, method, data),
    );
    addTearDown(target.dispose);
    await target.initialize(includeHistory: false, includeAnalysis: false);
    append(controller, [3]);
    target.requestTelemetry();
    await target.settled;
    expect(replica.watches.single.samples, isEmpty);
    expect(replica.watches.single.value, 6);
    await target.initialize(includeHistory: true, includeAnalysis: false);
    expect(replica.watches.single.samples.toList(), [
      const Offset(1, 2),
      const Offset(2, 4),
      const Offset(3, 6),
    ]);
    await target.initialize(includeHistory: false, includeAnalysis: false);
    expect(replica.watches.single.samples, isEmpty);
  });
}
