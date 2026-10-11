import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../telemetry/sample_buffer.dart';
import 'analysis_data.dart';

@immutable
class AnalysisSeries {
  const AnalysisSeries({
    required this.name,
    required this.color,
    required this.points,
  }) : _prepared = false,
       _bounds = null;
  const AnalysisSeries._prepared(
    this.name,
    this.color,
    this.points,
    this._bounds,
  ) : _prepared = true;
  final String name;
  final Color color;
  final List<AnalysisPoint> points;
  final bool _prepared;
  final (double, double, double, double)? _bounds;

  factory AnalysisSeries.fromSamples({
    required String name,
    required Color color,
    required SampleBuffer samples,
  }) {
    final frozen = samples.snapshot();
    final points = _SampleAnalysisPoints(frozen);
    if (!frozen.isOrdered) {
      return AnalysisSeries(name: name, color: color, points: points).prepare();
    }
    final range = frozen.valueBounds(double.negativeInfinity, double.infinity);
    return AnalysisSeries._prepared(name, color, points, (
      frozen.first.dx,
      frozen.last.dx,
      range?.$1 ?? double.infinity,
      range?.$2 ?? double.negativeInfinity,
    ));
  }

  /// Copy mutable input once. Background imports already own immutable data.
  AnalysisSeries prepare() {
    if (_prepared) return this;
    var ordered = true;
    final xy = Float64List(points.length * 2);
    var xMin = double.infinity, xMax = double.negativeInfinity;
    var yMin = double.infinity, yMax = double.negativeInfinity;
    for (var i = 0; i < points.length; i++) {
      final x = analysisXAt(points, i), y = analysisYAt(points, i);
      if (i > 0 && xy[(i - 1) * 2].compareTo(x) > 0) ordered = false;
      xy[i * 2] = x;
      xy[i * 2 + 1] = y;
      xMin = math.min(xMin, x);
      xMax = math.max(xMax, x);
      yMin = math.min(yMin, y);
      yMax = math.max(yMax, y);
    }
    if (!ordered) {
      final sorted = List<AnalysisPoint>.of(points)
        ..sort((a, b) => a.x.compareTo(b.x));
      for (var i = 0; i < sorted.length; i++) {
        xy[i * 2] = sorted[i].x;
        xy[i * 2 + 1] = sorted[i].y;
      }
    }
    return AnalysisSeries._prepared(name, color, PackedAnalysisPoints(xy), (
      xMin,
      xMax,
      yMin,
      yMax,
    ));
  }

  (double, double, double, double) get rawBounds =>
      _bounds ?? prepare().rawBounds;

  Map<String, Object?> toJson({bool packed = false}) => {
    'name': name,
    'color': color.toARGB32(),
    'points': packed
        ? (points is PackedAnalysisPoints
              ? (points as PackedAnalysisPoints).packed
              : packAnalysisPoints(points))
        : [for (final point in points) point.toJson()],
    if (packed)
      'bounds': [rawBounds.$1, rawBounds.$2, rawBounds.$3, rawBounds.$4],
  };
  static AnalysisSeries fromJson(Object? value) {
    final data = Map<String, Object?>.from(value! as Map);
    final raw = data['points'];
    final bounds = data['bounds'];
    if (raw is Float64List && bounds is List && bounds.length == 4) {
      return AnalysisSeries._prepared(
        data['name'] as String,
        Color(data['color'] as int),
        PackedAnalysisPoints(raw),
        (
          (bounds[0] as num).toDouble(),
          (bounds[1] as num).toDouble(),
          (bounds[2] as num).toDouble(),
          (bounds[3] as num).toDouble(),
        ),
      );
    }
    return AnalysisSeries(
      name: data['name'] as String,
      color: Color(data['color'] as int),
      points: List<AnalysisPoint>.unmodifiable(
        (raw as List? ?? const []).map(AnalysisPoint.fromJson),
      ),
    );
  }
}

class _SampleAnalysisPoints extends NumericAnalysisPoints {
  _SampleAnalysisPoints(this.samples);
  final SampleBuffer samples;
  @override
  int get length => samples.length;
  @override
  double xAt(int index) => samples.timeAt(index);
  @override
  double yAt(int index) => samples.valueAt(index);
}

@immutable
class AnalysisStats {
  const AnalysisStats({
    required this.count,
    required this.minimum,
    required this.maximum,
    required this.average,
  });
  final int count;
  final double minimum;
  final double maximum;
  final double average;
}
