import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller_snapshot_codec.dart';
import 'package:take_a_look_v2/src/controller/controller_snapshot_schema.dart';
import 'package:take_a_look_v2/src/controller/controller_state.dart';
import 'package:take_a_look_v2/src/models/models.dart';

void main() {
  test(
    'partial encoding is independent of controller and unrelated telemetry',
    () {
      final state = ControllerState();
      state.connection.probeType = 'CMSIS-DAP';
      state.acquisition.sampleRateHz = 500;
      state.plot.autoY = false;
      final view = ControllerSnapshotView(
        state: state,
        symbols: const [],
        selectedSymbols: const [],
        // Encoding a configuration patch must not traverse sample-bearing watches.
        watches: Iterable<WatchItem>.generate(
          1,
          (_) => throw StateError('visited'),
        ),
        logs: const [],
        uiScale: 1.25,
        samplingElapsedSeconds: 7,
        samplingClockRunning: false,
        plotWindowEndSeconds: 9,
        canUndoWatchDeletion: false,
        canRedoWatchDeletion: false,
      );
      final encoded = const ControllerSnapshotCodec().encode(
        view,
        fields: {
          'probeType',
          'sampleRateHz',
          'plotAutoY',
          'uiScale',
          'symbolLoad',
        },
      );
      expect(encoded, {
        'probeType': 'CMSIS-DAP',
        'sampleRateHz': 500.0,
        'plotAutoY': false,
        'uiScale': 1.25,
      });
    },
  );

  test(
    'revisions retain independent symbol epochs and shared-field ownership',
    () {
      final revisions = SnapshotRevisions();
      revisions.record({SnapshotDomain.symbols});
      final first = revisions.versions(symbolRevision: 12);
      expect(first['symbols'], 12);
      expect(first['firmware'], greaterThan(0));
      expect(first['selectedSymbols'], greaterThan(0));
      expect(first['watches'], 0);

      revisions.record({SnapshotDomain.debug});
      final second = revisions.versions(symbolRevision: 12);
      expect(second['firmware'], greaterThan(first['firmware']!));
      expect(second['selectedSymbols'], first['selectedSymbols']);
      expect(second['symbols'], 12);
      expect(second['uiScale'], greaterThan(first['uiScale']!));
      revisions.touch(['unknownWireField']);
      expect(revisions.versions(symbolRevision: 13)['symbols'], 13);
      expect(
        revisions.versions(symbolRevision: 13),
        isNot(contains('unknownWireField')),
      );
    },
  );
}
