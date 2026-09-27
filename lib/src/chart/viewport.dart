import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../sample_buffer.dart';

Rect telemetryPlotRect(Size size) => Rect.fromLTRB(
  52,
  48,
  math.max(54, size.width - 10),
  math.max(50, size.height - 46),
);

class TelemetryViewport {
  const TelemetryViewport({
    required this.plot,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });

  final Rect plot;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

  double get xSpan => math.max(0.001, xMax - xMin);
  double get ySpan => math.max(1e-9, yMax - yMin);
}

TelemetryViewport telemetryViewport(TakeALookController controller, Size size) {
  final plot = telemetryPlotRect(size);
  final plotted = controller.watches.where((item) => item.plotted);
  var xMax = controller.plotWindowEndSeconds;
  final window = math.max(0.2, controller.plotVisibleWindowSeconds);
  var xMin = math.max(0.0, xMax - window);
  if (xMax <= xMin) xMax = xMin + window;

  var yMin = controller.plotAutoY
      ? double.infinity
      : controller.plotYMin ?? double.infinity;
  var yMax = controller.plotAutoY
      ? -double.infinity
      : controller.plotYMax ?? -double.infinity;
  if (controller.plotAutoY || !yMin.isFinite || !yMax.isFinite) {
    yMin = double.infinity;
    yMax = -double.infinity;
    for (final watch in plotted) {
      final samples = controller.plotSamplesFor(watch);
      if (samples is SampleBuffer) {
        final bounds = samples.valueBounds(xMin, xMax);
        if (bounds != null) {
          yMin = math.min(yMin, bounds.$1);
          yMax = math.max(yMax, bounds.$2);
        }
        continue;
      }
      for (final point in samples) {
        if (point.dx < xMin || point.dx > xMax) continue;
        yMin = math.min(yMin, point.dy);
        yMax = math.max(yMax, point.dy);
      }
    }
    if (!yMin.isFinite || !yMax.isFinite) {
      yMin = -1;
      yMax = 1;
    }
    if ((yMax - yMin).abs() < 0.001) {
      yMin -= 1;
      yMax += 1;
    } else {
      final pad = (yMax - yMin) * 0.12;
      yMin -= pad;
      yMax += pad;
    }
  }
  return TelemetryViewport(
    plot: plot,
    xMin: xMin,
    xMax: xMax,
    yMin: yMin,
    yMax: yMax,
  );
}
