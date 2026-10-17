import 'dart:math' as math;
import 'dart:ui';

import '../backend/backend_transport.dart';
import '../models/models.dart';

/// Owns mutation and retention rules for high-frequency watch samples.
class TelemetryStore {
  static const double defaultRetentionSeconds = 60;
  double retentionSeconds = defaultRetentionSeconds;
  double sampleRateHz = 50;
  double rttSampleRateHz = 1000;
  bool rttEnabled = false;
  String rttProtocol = 'normal';

  void configureWatch(WatchItem watch) {
    final useRtt =
        watch.symbol.dataSource == 'rtt' ||
        (rttEnabled && rttProtocol == 'plus');
    watch.samples.configureRetention(
      seconds: retentionSeconds,
      rateHz: useRtt ? rttSampleRateHz : sampleRateHz,
    );
  }

  void append(WatchItem watch, Offset point) {
    configureWatch(watch);
    watch.samples.add(point);
    watch.totalSampleCount += 1;
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
    for (final watch in watchesByKey.values) {
      configureWatch(watch);
    }
    var elapsedSeconds = currentElapsed;
    final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
    final stamp = (payload['updatedAtMs'] as num?)?.toInt();
    final freshKeys = {
      for (final watch in watchesByKey.values)
        if (stamp == null ||
            watch.updatedAtMs == null ||
            stamp > watch.updatedAtMs!)
          watch.symbol.key,
    };
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
        final value = numericValue(entry.value, fallback: watch.value);
        if (freshKeys.contains(watch.symbol.key)) {
          watch.value = value;
          watch.updatedAtMs = stamp ?? receivedAtMs;
        }
        if (payload['captureOnly'] == true || watch.samplingEnabled) {
          watch.samples.addXY(elapsed, value);
          watch.totalSampleCount++;
        }
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
    for (final watch in watchesByKey.values) {
      configureWatch(watch);
    }
    var elapsedSeconds = currentElapsed;
    for (final elapsed in batch.elapsedSeconds) {
      elapsedSeconds = math.max(elapsedSeconds, elapsed);
    }
    for (var variable = 0; variable < batch.variableCount; variable++) {
      final watch = schemaWatches[variable];
      if (watch == null) continue;
      var recorded = 0;
      var latest = watch.value;
      var received = false;
      for (var frame = 0; frame < batch.frameCount; frame++) {
        if (!batch.hasValue(frame, variable)) continue;
        received = true;
        latest = batch.valueAt(frame, variable);
        if (batch.captureOnly || watch.samplingEnabled) {
          watch.samples.addXY(batch.elapsedSeconds[frame], latest);
          recorded++;
        }
      }
      if (received &&
          (batch.updatedAtMs == null ||
              watch.updatedAtMs == null ||
              batch.updatedAtMs! > watch.updatedAtMs!)) {
        watch.value = latest;
        watch.updatedAtMs =
            batch.updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      }
      watch.totalSampleCount += recorded;
    }
    return elapsedSeconds;
  }

  static double numericValue(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is bool) return value ? 1 : 0;
    return fallback;
  }
}
