import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../telemetry/sample_buffer.dart';

final _sampleReductions =
    Expando<
      ({
        int revision,
        double xMin,
        double xMax,
        double width,
        List<Offset> points,
      })
    >();

List<Offset> downsampleTelemetrySamples(
  Iterable<Offset> samples, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  if (samples is SampleBuffer) {
    final cached = _sampleReductions[samples];
    if (cached != null &&
        cached.revision == samples.revision &&
        cached.xMin == xMin &&
        cached.xMax == xMax &&
        cached.width == pixelWidth) {
      return cached.points;
    }
    final points = List<Offset>.unmodifiable(
      _downsampleBuffer(samples, xMin, xMax, pixelWidth),
    );
    _sampleReductions[samples] = (
      revision: samples.revision,
      xMin: xMin,
      xMax: xMax,
      width: pixelWidth,
      points: points,
    );
    return points;
  }
  final visible = [
    for (final point in samples)
      if (point.dx >= xMin && point.dx <= xMax) point,
  ];
  final bucketCount = math.max(1, pixelWidth.floor());
  if (visible.length <= bucketCount * 2 || xMax <= xMin) return visible;

  final result = <Offset>[];
  _appendDistinctPoint(result, visible.first);
  var currentBucket = -1;
  Offset? minimum;
  Offset? maximum;
  var minimumIndex = 0;
  var maximumIndex = 0;
  var pointIndex = 0;

  void flushBucket() {
    final low = minimum;
    final high = maximum;
    if (low == null || high == null) return;
    if (minimumIndex <= maximumIndex) {
      _appendDistinctPoint(result, low);
      _appendDistinctPoint(result, high);
    } else {
      _appendDistinctPoint(result, high);
      _appendDistinctPoint(result, low);
    }
  }

  for (final point in visible) {
    final bucket = (((point.dx - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flushBucket();
      currentBucket = bucket;
      minimum = point;
      maximum = point;
      minimumIndex = pointIndex;
      maximumIndex = pointIndex;
    } else {
      if (point.dy < minimum!.dy) {
        minimum = point;
        minimumIndex = pointIndex;
      }
      if (point.dy > maximum!.dy) {
        maximum = point;
        maximumIndex = pointIndex;
      }
    }
    pointIndex += 1;
  }
  flushBucket();
  _appendDistinctPoint(result, visible.last);
  return result;
}

List<Offset> _downsampleBuffer(
  SampleBuffer samples,
  double xMin,
  double xMax,
  double pixelWidth,
) {
  final bucketCount = math.max(1, pixelWidth.floor());
  final (start, end) = samples.rangeIndices(xMin, xMax);
  if (samples.isOrdered) {
    if (end <= start) return const [];
    if (end - start <= bucketCount * 2 || xMax <= xMin) {
      return [for (var i = start; i < end; i++) samples[i]];
    }
    int bucketAt(int index) =>
        (((samples.timeAt(index) - xMin) / (xMax - xMin)) * bucketCount)
            .floor()
            .clamp(0, bucketCount - 1);
    if (end - start <= bucketCount * 24) {
      return samples.reduceTimeBuckets(start, end, xMin, xMax, bucketCount);
    }
    final result = <Offset>[];
    _appendDistinctPoint(result, samples[start]);
    var index = start;
    while (index < end) {
      final bucket = bucketAt(index);
      var guess = (index + ((end - index) / (bucketCount - bucket)).ceil())
          .clamp(index + 1, end);
      var low = index + 1, high = end;
      if (guess == end && bucketAt(end - 1) == bucket) {
        low = high = end;
      } else {
        guess = math.min(guess, end - 1);
        var step = 1;
        if (bucketAt(guess) <= bucket) {
          low = guess + 1;
          high = math.min(end, low + step);
          while (high < end && bucketAt(high) <= bucket) {
            low = high + 1;
            step *= 2;
            high = math.min(end, high + step);
          }
        } else {
          high = guess;
          low = math.max(index + 1, high - step);
          while (low > index + 1 && bucketAt(low) > bucket) {
            high = low;
            step *= 2;
            low = math.max(index + 1, low - step);
          }
          if (bucketAt(low) <= bucket) low++;
        }
      }
      // Match the original pixel expression, including floating-point rounding.
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (bucketAt(middle) <= bucket) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      final (minimum, maximum) = samples.extremaIndices(index, low);
      _appendDistinctPoint(result, samples[math.min(minimum, maximum)]);
      _appendDistinctPoint(result, samples[math.max(minimum, maximum)]);
      index = low;
    }
    _appendDistinctPoint(result, samples[end - 1]);
    return result;
  }
  var visibleCount = 0;
  var firstVisible = -1;
  var lastVisible = -1;
  for (var i = start; i < end; i++) {
    final time = samples.timeAt(i);
    if (time >= xMin && time <= xMax) {
      visibleCount++;
      if (firstVisible < 0) firstVisible = i;
      lastVisible = i;
    }
  }
  if (visibleCount <= bucketCount * 2 || xMax <= xMin) {
    return [
      for (var i = start; i < end; i++)
        if (samples.timeAt(i) >= xMin && samples.timeAt(i) <= xMax) samples[i],
    ];
  }
  final result = <Offset>[];
  _appendDistinctPoint(result, samples[firstVisible]);
  var currentBucket = -1;
  var minimumIndex = -1;
  var maximumIndex = -1;
  var minimum = double.infinity;
  var maximum = double.negativeInfinity;
  void flush() {
    if (minimumIndex < 0) return;
    final first = math.min(minimumIndex, maximumIndex);
    final last = math.max(minimumIndex, maximumIndex);
    _appendDistinctPoint(result, samples[first]);
    _appendDistinctPoint(result, samples[last]);
  }

  for (var i = start; i < end; i++) {
    final time = samples.timeAt(i);
    if (time < xMin || time > xMax) continue;
    final value = samples.valueAt(i);
    final bucket = (((time - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flush();
      currentBucket = bucket;
      minimum = maximum = value;
      minimumIndex = maximumIndex = i;
    } else {
      if (value < minimum) {
        minimum = value;
        minimumIndex = i;
      }
      if (value > maximum) {
        maximum = value;
        maximumIndex = i;
      }
    }
  }
  flush();
  _appendDistinctPoint(result, samples[lastVisible]);
  return result;
}

void _appendDistinctPoint(List<Offset> points, Offset point) {
  if (points.isEmpty || points.last != point) points.add(point);
}
