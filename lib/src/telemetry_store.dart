import 'dart:math' as math;
import 'dart:ui';

import 'backend_client.dart';
import 'models.dart';

/// Owns mutation and retention rules for high-frequency watch samples.
class TelemetryStore {
  static const int retainedSamplesPerWatch = 1800;

  void append(WatchItem watch, Offset point) {
    watch.samples.add(point);
    watch.totalSampleCount += 1;
    final overflow = watch.samples.length - retainedSamplesPerWatch;
    if (overflow > 0) watch.samples.removeRange(0, overflow);
  }

  void clear(Iterable<WatchItem> watches) {
    for (final watch in watches) {
      watch.samples.clear();
      watch.totalSampleCount = 0;
    }
  }

  double applyJsonFrames(
    Map<String, dynamic> payload,
    Iterable<WatchItem> watches, {
    required double currentElapsed,
  }) {
    final watchesByKey = {for (final watch in watches) watch.symbol.key: watch};
    var elapsedSeconds = currentElapsed;
    for (final rawFrame in payload['frames'] as List? ?? const []) {
      if (rawFrame is! Map) continue;
      final frame = Map<String, dynamic>.from(rawFrame);
      final elapsed = (frame['elapsed'] as num?)?.toDouble();
      final rawValues = frame['values'];
      if (elapsed == null || rawValues is! Map) continue;
      elapsedSeconds = math.max(elapsedSeconds, elapsed);
      for (final entry in rawValues.entries) {
        final watch = watchesByKey[entry.key];
        if (watch == null) continue;
        watch.value = numericValue(entry.value, fallback: watch.value);
        append(watch, Offset(elapsed, watch.value));
      }
    }
    return elapsedSeconds;
  }

  double applyBinaryBatch(
    BackendSampleBatch batch,
    Iterable<WatchItem> watches, {
    required double currentElapsed,
  }) {
    final watchesByKey = {for (final watch in watches) watch.symbol.key: watch};
    final schemaWatches = [for (final key in batch.keys) watchesByKey[key]];
    var elapsedSeconds = currentElapsed;
    for (var frame = 0; frame < batch.frameCount; frame += 1) {
      final elapsed = batch.elapsedSeconds[frame];
      elapsedSeconds = math.max(elapsedSeconds, elapsed);
      for (var variable = 0; variable < batch.variableCount; variable += 1) {
        final watch = schemaWatches[variable];
        if (watch == null || !batch.hasValue(frame, variable)) continue;
        watch.value = batch.valueAt(frame, variable);
        append(watch, Offset(elapsed, watch.value));
      }
    }
    return elapsedSeconds;
  }

  static double numericValue(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is bool) return value ? 1 : 0;
    return fallback;
  }
}
