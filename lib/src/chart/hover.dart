import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../models/watch_tree.dart';
import 'cartesian_renderer.dart';
import 'downsampling.dart';

class TelemetryPlotSeries {
  const TelemetryPlotSeries({
    required this.watch,
    required this.samples,
    required this.points,
  });

  final WatchItem watch;
  final Iterable<Offset> samples;
  final List<Offset> points;
}

List<TelemetryPlotSeries> telemetryPlotSeries(
  TakeALookController controller,
  CartesianPlotViewport viewport,
) {
  return [
    for (final root in buildWatchTree(controller.watches))
      for (final watch in root.watchesInDisplayOrder)
        if (watch.plotted)
          _seriesFor(watch, controller.plotSamplesFor(watch), viewport),
  ];
}

TelemetryPlotSeries _seriesFor(
  WatchItem watch,
  Iterable<Offset> samples,
  CartesianPlotViewport viewport,
) => TelemetryPlotSeries(
  watch: watch,
  samples: samples,
  points: downsampleTelemetrySamples(
    samples,
    xMin: viewport.xMin,
    xMax: viewport.xMax,
    pixelWidth: viewport.plot.width,
  ),
);

class TelemetryHoverHit {
  const TelemetryHoverHit({
    required this.series,
    required this.sample,
    required this.position,
  });

  final TelemetryPlotSeries series;
  final Offset sample;
  final Offset position;

  String get valueText =>
      't = ${_formatValue(sample.dx)} s\n采样值 = ${_formatValue(sample.dy)}';
}

/// A table selection takes precedence over proximity to any other curve.
/// Without a pointer, inspect the selected curve's latest visible sample.
TelemetryHoverHit? inspectTelemetrySeries(
  List<TelemetryPlotSeries> series,
  CartesianPlotViewport viewport, {
  Offset? position,
  String? highlightedWatchKey,
}) {
  if (highlightedWatchKey == null) {
    return position == null
        ? null
        : hitTestTelemetrySeries(series, viewport, position);
  }
  for (final candidate in series) {
    if (candidate.watch.symbol.key != highlightedWatchKey) continue;
    final target = position != null && viewport.plot.contains(position)
        ? position
        : Offset(viewport.mapX(viewport.xMax), viewport.plot.center.dy);
    return _nearestTelemetrySample(
      candidate,
      viewport,
      target,
      horizontalOnly: true,
    );
  }
  return null;
}

/// Hit-test the displayed polyline, then report a real, unmodified sample.
/// Equal-distance hits keep the first series in watch-table order.
TelemetryHoverHit? hitTestTelemetrySeries(
  List<TelemetryPlotSeries> series,
  CartesianPlotViewport viewport,
  Offset position, {
  double tolerance = 6,
}) {
  if (!viewport.plot.contains(position)) return null;
  TelemetryPlotSeries? selected;
  var closest = tolerance * tolerance;
  for (final candidate in series) {
    Offset? previous;
    var distance = double.infinity;
    for (final point in candidate.points) {
      if (!point.isFinite) {
        previous = null;
        continue;
      }
      final pixel = Offset(viewport.mapX(point.dx), viewport.mapY(point.dy));
      distance = math.min(distance, (pixel - position).distanceSquared);
      if (previous != null) {
        final segment = pixel - previous;
        final lengthSquared = segment.distanceSquared;
        if (lengthSquared > 0) {
          final relative = position - previous;
          final fraction =
              ((relative.dx * segment.dx + relative.dy * segment.dy) /
                      lengthSquared)
                  .clamp(0.0, 1.0);
          final nearest = previous + segment * fraction;
          distance = math.min(distance, (nearest - position).distanceSquared);
        }
      }
      previous = pixel;
    }
    if (distance <= tolerance * tolerance &&
        (selected == null || distance < closest - 1e-6)) {
      selected = candidate;
      closest = distance;
    }
  }
  if (selected == null) return null;
  return _nearestTelemetrySample(selected, viewport, position);
}

TelemetryHoverHit? _nearestTelemetrySample(
  TelemetryPlotSeries selected,
  CartesianPlotViewport viewport,
  Offset position, {
  bool horizontalOnly = false,
}) {
  Offset? sample;
  Offset? samplePosition;
  var sampleDistance = double.infinity;
  for (final point in selected.samples) {
    if (!point.isFinite ||
        point.dx < viewport.xMin ||
        point.dx > viewport.xMax) {
      continue;
    }
    final pixel = Offset(viewport.mapX(point.dx), viewport.mapY(point.dy));
    final distance = horizontalOnly
        ? (pixel.dx - position.dx).abs()
        : (pixel - position).distanceSquared;
    if (distance < sampleDistance) {
      sample = point;
      samplePosition = pixel;
      sampleDistance = distance;
    }
  }
  if (sample == null || samplePosition == null) return null;
  return TelemetryHoverHit(
    series: selected,
    sample: sample,
    position: samplePosition,
  );
}

String _formatValue(double value) {
  final parts = value.toStringAsPrecision(9).split('e');
  if (parts.first.contains('.')) {
    parts[0] = parts.first.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return parts.join('e');
}
