import 'dart:collection';
import 'dart:typed_data';

enum AnalysisWindowFunction { rectangular, hann, hamming }

class AnalysisPoint {
  const AnalysisPoint(this.x, this.y);
  final double x;
  final double y;
  List<double> toJson() => [x, y];
  static AnalysisPoint fromJson(Object? value) {
    final point = value! as List;
    return AnalysisPoint(
      (point[0] as num).toDouble(),
      (point[1] as num).toDouble(),
    );
  }
}

/// Read-only numeric series shared by the analysis worker and chart consumers.
abstract class NumericAnalysisPoints extends ListBase<AnalysisPoint> {
  double xAt(int index);
  double yAt(int index);
  @override
  AnalysisPoint operator [](int index) => AnalysisPoint(xAt(index), yAt(index));
  @override
  void operator []=(int index, AnalysisPoint value) =>
      throw UnsupportedError('Analysis points are read-only');
  @override
  set length(int value) =>
      throw UnsupportedError('Analysis points are read-only');
}

class PackedAnalysisPoints extends NumericAnalysisPoints {
  PackedAnalysisPoints(Float64List xy) : _xy = xy.asUnmodifiableView() {
    if (xy.length.isOdd) throw ArgumentError('Expected interleaved x/y pairs');
  }
  final Float64List _xy;
  @override
  int get length => _xy.length ~/ 2;
  @override
  double xAt(int index) {
    RangeError.checkValidIndex(index, this);
    return _xy[index * 2];
  }

  @override
  double yAt(int index) {
    RangeError.checkValidIndex(index, this);
    return _xy[index * 2 + 1];
  }
}

/// FFT bins have uniformly spaced X values; only amplitudes need storage.
class UniformAnalysisPoints extends NumericAnalysisPoints {
  UniformAnalysisPoints(Float64List values, {required this.step})
    : values = values.asUnmodifiableView();
  final Float64List values;
  final double step;
  @override
  int get length => values.length;
  @override
  double xAt(int index) {
    RangeError.checkValidIndex(index, this);
    return index * step;
  }

  @override
  double yAt(int index) => values[index];
}

double analysisXAt(List<AnalysisPoint> points, int index) =>
    points is NumericAnalysisPoints ? points.xAt(index) : points[index].x;
double analysisYAt(List<AnalysisPoint> points, int index) =>
    points is NumericAnalysisPoints ? points.yAt(index) : points[index].y;

Float64List packAnalysisPoints(List<AnalysisPoint> points) {
  final packed = Float64List(points.length * 2);
  for (var index = 0; index < points.length; index++) {
    packed[index * 2] = analysisXAt(points, index);
    packed[index * 2 + 1] = analysisYAt(points, index);
  }
  return packed;
}

int lowerBoundAnalysisPoints(List<AnalysisPoint> points, double value) {
  var low = 0;
  var high = points.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (analysisXAt(points, middle) < value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

int upperBoundAnalysisPoints(List<AnalysisPoint> points, double value) {
  var low = 0;
  var high = points.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (analysisXAt(points, middle) <= value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}
