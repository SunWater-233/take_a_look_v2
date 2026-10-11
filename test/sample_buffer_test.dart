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
      final store = TelemetryStore()
        ..retentionSeconds = 1
        ..sampleRateHz = 1000;
      final end = store.applyBinaryBatch(batch, watches, currentElapsed: 0);
      expect(end, 2.004);
      expect(watches[0].totalSampleCount, frames);
      expect(watches[0].samples, hasLength(1001));
      expect(watches[0].samples.first, const Offset(1.004, 3012));
      expect(watches[0].samples.last, const Offset(2.004, 6012));
      expect(watches[1].totalSampleCount, 1003);
      expect(watches[1].samples.last.dy, 6013);
      expect(watches[2].samples, isEmpty);
      expect(watches[2].totalSampleCount, 0);
      expect(watches[2].value, 6014);
    },
  );

  test('time retention grows at high rates and survives a rate decrease', () {
    final buffer = SampleBuffer(capacity: 3)
      ..configureRetention(seconds: 2, rateHz: 1000);
    expect(buffer.capacity, 2001);
    for (var i = 0; i <= 3000; i++) {
      buffer.addXY(i / 1000, i.toDouble());
    }
    expect(buffer.length, 2001);
    expect(buffer.first.dx, 1);
    buffer.configureRetention(seconds: 2, rateHz: 50);
    expect(buffer.length, 2001);
    expect(buffer.first.dx, 1);
    buffer.addXY(3.02, 3020);
    expect(buffer.first.dx, closeTo(1.02, 1e-9));
    expect(buffer.last.dx, 3.02);
    buffer.configureRetention(seconds: 1, rateHz: 50);
    expect(buffer.first.dx, closeTo(2.02, 1e-9));
    buffer.clear();
    expect(buffer.capacity, 51);
    // An actual RTT stream can exceed its configured polling rate.
    for (var i = 0; i <= 1000; i++) {
      buffer.addXY(i / 1000, i.toDouble());
    }
    expect(buffer.length, 1001);
    expect(buffer.first.dx, 0);
    expect(buffer.capacity, greaterThanOrEqualTo(1001));
  });

  test('visible range lookup supports ring wrap and overlapping batches', () {
    final buffer = SampleBuffer(capacity: 10);
    for (var i = 0; i < 30; i++) {
      buffer.addXY(i.toDouble(), i.toDouble());
    }
    expect(buffer.rangeIndices(22, 25), (2, 6));
    expect(buffer.valueBounds(22, 25), (22, 25));
    buffer.addXY(23.5, -10);
    expect(buffer.valueBounds(22, 25), (-10, 25));
  });
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
