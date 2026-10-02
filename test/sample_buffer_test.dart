import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_transport.dart';
import 'package:take_a_look_v2/src/chart/downsampling.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/telemetry/sample_buffer.dart';
import 'package:take_a_look_v2/src/telemetry/telemetry_store.dart';

void main() {
  test('bounded history wraps in order and snapshots survive later writes', () {
    final buffer = SampleBuffer(capacity: 3);
    for (var i = 0; i < 8; i++) {
      buffer.addXY(i.toDouble(), -i.toDouble());
    }
    expect(buffer.toList(), [
      const Offset(5, -5),
      const Offset(6, -6),
      const Offset(7, -7),
    ]);
    expect(buffer.skip(2).single, const Offset(7, -7));
    expect(buffer.skip(20), isEmpty);
    final snapshot = buffer.toList();
    buffer.clear();
    buffer.addXY(10, 20);
    expect(snapshot.first, const Offset(5, -5));
    expect(buffer.single, const Offset(10, 20));
    expect(() => buffer[-1], throwsRangeError);
    expect(() => buffer[1], throwsRangeError);
    expect(() => SampleBuffer(capacity: 0), throwsArgumentError);
  });

  test('ring downsampling agrees with list after wrap and keeps extrema', () {
    final buffer = SampleBuffer(capacity: 240);
    for (var i = 0; i < 1000; i++) {
      buffer.addXY(
        i / 100,
        i == 855
            ? -100
            : i == 880
            ? 100
            : i % 9.0,
      );
    }
    for (final width in [5.0, 100.0, 1000.0]) {
      final expected = downsampleTelemetrySamples(
        buffer.toList(),
        xMin: 8,
        xMax: 9,
        pixelWidth: width,
      );
      final actual = downsampleTelemetrySamples(
        buffer,
        xMin: 8,
        xMax: 9,
        pixelWidth: width,
      );
      expect(actual, expected);
      expect(actual.map((point) => point.dy), containsAll([-100, 100]));
    }
    expect(buffer.valueBounds(8, 9), (-100, 100));
    expect(buffer.valueBounds(20, 30), isNull);
    final iterator = buffer.iterator..moveNext();
    buffer.addXY(10, 0);
    expect(iterator.moveNext, throwsConcurrentModificationError);
  });

  test(
    'binary batches preserve sparse values, retention and recording switches',
    () {
      const frames = 2005;
      final watches = [for (var i = 0; i < 3; i++) _watch('ch$i')];
      watches[2].samplingEnabled = false;
      final batch = BackendSampleBatch(
        schemaId: 1,
        sequence: 1,
        keys: const ['ch0', 'ch1', 'ch2'],
        elapsedSeconds: Float64List.fromList([
          for (var i = 0; i < frames; i++) i / 1000,
        ]),
        values: Float64List.fromList([
          for (var i = 0; i < frames * 3; i++) i.toDouble(),
        ]),
        validity: Uint8List.fromList([
          for (var i = 0; i < frames; i++) i.isEven ? 7 : 5,
        ]),
        validityBytesPerFrame: 1,
      );
      final end = TelemetryStore().applyBinaryBatch(
        batch,
        watches,
        currentElapsed: 0,
      );
      expect(end, 2.004);
      expect(watches[0].totalSampleCount, frames);
      expect(watches[0].samples, hasLength(1800));
      expect(watches[0].samples.first, const Offset(0.205, 615));
      expect(watches[0].samples.last, const Offset(2.004, 6012));
      expect(watches[1].totalSampleCount, 1003);
      expect(watches[1].samples.last.dy, 6013);
      expect(watches[2].samples, isEmpty);
      expect(watches[2].totalSampleCount, 0);
      expect(watches[2].value, 6014);
    },
  );
}

WatchItem _watch(String key) => WatchItem(
  symbol: SymbolItem(
    source: 'fixture',
    name: key,
    address: 0,
    type: 'float',
    size: 4,
    backendKey: key,
  ),
  color: const Color(0xFF0080FF),
);
