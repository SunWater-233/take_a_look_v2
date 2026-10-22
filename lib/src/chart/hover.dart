import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../models/watch_tree.dart';
import '../telemetry/sample_buffer.dart';
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

final _watchOrders = Expando<({int revision, List<WatchItem> watches})>();

List<TelemetryPlotSeries> telemetryPlotSeries(
  TakeALookController controller,
  CartesianPlotViewport viewport,
) {
  var order = _watchOrders[controller];
  if (order == null || order.revision != controller.watchRevision) {
    order = (
      revision: controller.watchRevision,
      watches: [
        for (final root in buildWatchTree(controller.watches))
          ...root.watchesInDisplayOrder,
      ],
    );
    _watchOrders[controller] = order;
  }
  final plottedCount = order.watches.where((watch) => watch.plotted).length;
  final highlighted = order.watches.any(
    (watch) =>
        watch.plotted && watch.symbol.key == controller.plotHighlightedWatchKey,
  );
  // Bound GPU line work as channel count grows. Envelopes still retain their
  // actual extrema; the inspected curve keeps full horizontal pixel resolution.
  const totalBuckets = 6144.0;
  final ordinaryWidth = math.min(
    viewport.plot.width,
    (totalBuckets - (highlighted ? viewport.plot.width : 0)) /
        math.max(1, plottedCount - (highlighted ? 1 : 0)),
  );
  return [
    for (final watch in order.watches)
      if (watch.plotted)
        _seriesFor(
          watch,
          controller.plotSamplesFor(watch),
          viewport,
          pixelWidth: watch.symbol.key == controller.plotHighlightedWatchKey
              ? viewport.plot.width
              : math.max(1, ordinaryWidth),
        ),
  ];
}

TelemetryPlotSeries _seriesFor(
  WatchItem watch,
  Iterable<Offset> samples,
  CartesianPlotViewport viewport, {
  required double pixelWidth,
}) => TelemetryPlotSeries(
  watch: watch,
  samples: samples,
  points: downsampleTelemetrySamples(
    samples,
    xMin: viewport.xMin,
    xMax: viewport.xMax,
    pixelWidth: pixelWidth,
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

/// Keep a hovered curve through small pointer or live-data movements. New
/// targets still use proximity and watch-table order; only the current target
/// gets the wider release radius.
class TelemetryHoverTracker {
  String? _watchKey;

  void clear() => _watchKey = null;

  TelemetryHoverHit? hitTest(
    List<TelemetryPlotSeries> series,
    CartesianPlotViewport viewport,
    Offset? position,
  ) {
    if (position == null || !viewport.plot.contains(position)) {
      clear();
      return null;
    }
    var hit = hitTestTelemetrySeries(series, viewport, position, tolerance: 12);
    if (hit == null && _watchKey != null) {
      hit = hitTestTelemetrySeries(
        [
          for (final candidate in series)
            if (candidate.watch.symbol.key == _watchKey) candidate,
        ],
        viewport,
        position,
        tolerance: 20,
      );
    }
    _watchKey = hit?.series.watch.symbol.key;
    return hit;
  }
}

/// A table selection takes precedence over proximity to any other curve.
/// Without a pointer, inspect the selected curve's latest visible sample.
TelemetryHoverHit? inspectTelemetrySeries(
  List<TelemetryPlotSeries> series,
  CartesianPlotViewport viewport, {
  Offset? position,
  String? highlightedWatchKey,
  TelemetryHoverTracker? hoverTracker,
}) {
  if (highlightedWatchKey == null) {
    if (hoverTracker != null) {
      return hoverTracker.hitTest(series, viewport, position);
    }
    return position == null
        ? null
        : hitTestTelemetrySeries(series, viewport, position, tolerance: 12);
  }
  hoverTracker?.clear();
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
  final samples = selected.samples;
  Iterable<Offset> candidates = samples;
  if (samples is SampleBuffer && samples.isOrdered) {
    final (start, end) = samples.rangeIndices(viewport.xMin, viewport.xMax);
    if (start >= end) return null;
    if (horizontalOnly) {
      final time = viewport.unmapX(position.dx);
      final next = samples.lowerBound(time).clamp(start, end);
      final indices = <int>{
        if (next > start)
          samples.lowerBound(samples.timeAt(next - 1)).clamp(start, end - 1),
        if (next < end) next,
      }.toList()..sort();
      candidates = indices.map((index) => samples[index]);
    } else {
      candidates = Iterable.generate(
        end - start,
        (index) => samples[start + index],
      );
    }
  }
  for (final point in candidates) {
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
