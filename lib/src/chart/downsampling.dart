import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../telemetry/sample_buffer.dart';

List<Offset> downsampleTelemetrySamples(
  Iterable<Offset> samples, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  if (samples is SampleBuffer) {
    return _downsampleBuffer(samples, xMin, xMax, pixelWidth);
  }
  final visible = [
    for (final point in samples)
      if (point.dx >= xMin && point.dx <= xMax) point,
  ];
  final bucketCount = math.max(1, pixelWidth.floor());
  if (visible.length <= bucketCount * 2 || xMax <= xMin) return visible;

  final result = <Offset>[];
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
  var visibleCount = 0;
  var lastVisible = -1;
  for (var i = 0; i < samples.length; i++) {
    final time = samples.timeAt(i);
    if (time >= xMin && time <= xMax) {
      visibleCount++;
      lastVisible = i;
    }
  }
  if (visibleCount <= bucketCount * 2 || xMax <= xMin) {
    return [
      for (var i = 0; i < samples.length; i++)
        if (samples.timeAt(i) >= xMin && samples.timeAt(i) <= xMax) samples[i],
    ];
  }
  final result = <Offset>[];
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

  for (var i = 0; i < samples.length; i++) {
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
