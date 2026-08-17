import 'dart:math' as math;

import 'package:flutter/material.dart';

List<Offset> downsampleTelemetrySamples(
  Iterable<Offset> samples, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
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

void _appendDistinctPoint(List<Offset> points, Offset point) {
  if (points.isEmpty || points.last != point) points.add(point);
}
