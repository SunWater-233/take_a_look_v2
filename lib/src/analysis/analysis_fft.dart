import 'dart:math' as math;
import 'dart:typed_data';

import 'analysis_data.dart';

class AnalysisSpectrum {
  const AnalysisSpectrum({
    required this.points,
    required this.sampleRate,
    required this.sampleCount,
    required this.fftSize,
    required this.resampled,
    required this.peakFrequency,
    required this.peakAmplitude,
    this.error,
  });

  const AnalysisSpectrum.error(String message)
    : points = const [],
      sampleRate = 0,
      sampleCount = 0,
      fftSize = 0,
      resampled = false,
      peakFrequency = 0,
      peakAmplitude = 0,
      error = message;

  final List<AnalysisPoint> points;
  final double sampleRate;
  final int sampleCount;
  final int fftSize;
  final bool resampled;
  final double peakFrequency;
  final double peakAmplitude;
  final String? error;

  double get frequencyResolution => fftSize == 0 ? 0 : sampleRate / fftSize;
}

AnalysisSpectrum analysisSpectrumForSeries(
  List<AnalysisPoint> signalPoints, {
  List<AnalysisPoint>? timePoints,
  double? selectionStart,
  double? selectionEnd,
  AnalysisWindowFunction window = AnalysisWindowFunction.hann,
  bool removeDc = true,
}) {
  if (signalPoints.length < 4) {
    return const AnalysisSpectrum.error('至少需要 4 个有效样本');
  }
  final rangeStart = selectionStart == null || selectionEnd == null
      ? double.negativeInfinity
      : math.min(selectionStart, selectionEnd);
  final rangeEnd = selectionStart == null || selectionEnd == null
      ? double.infinity
      : math.max(selectionStart, selectionEnd);
  final first = rangeStart.isInfinite
      ? 0
      : lowerBoundAnalysisPoints(signalPoints, rangeStart);
  final afterLast = rangeEnd.isInfinite
      ? signalPoints.length
      : upperBoundAnalysisPoints(signalPoints, rangeEnd);
  if (afterLast - first < 4) {
    return const AnalysisSpectrum.error('所选范围至少需要 4 个有效样本');
  }

  final timeStorage = Float64List(afterLast - first);
  final valueStorage = Float64List(afterLast - first);
  var validCount = 0;
  for (var index = first; index < afterLast; index += 1) {
    final x = analysisXAt(signalPoints, index);
    final value = analysisYAt(signalPoints, index);
    final time = timePoints == null
        ? x
        : _interpolateSeriesValue(timePoints, x);
    if (time == null || !time.isFinite || !value.isFinite) continue;
    if (validCount > 0 && time <= timeStorage[validCount - 1]) {
      return const AnalysisSpectrum.error('时间基准必须严格递增');
    }
    timeStorage[validCount] = time;
    valueStorage[validCount] = value;
    validCount++;
  }
  if (validCount < 4) {
    return const AnalysisSpectrum.error('时间基准与信号没有足够的重合样本');
  }
  final times = Float64List.sublistView(timeStorage, 0, validCount);
  final values = Float64List.sublistView(valueStorage, 0, validCount);

  final deltas = Float64List(times.length - 1);
  for (var index = 1; index < times.length; index++) {
    deltas[index - 1] = times[index] - times[index - 1];
  }
  deltas.sort();
  final medianDelta = deltas[deltas.length ~/ 2];
  if (!medianDelta.isFinite || medianDelta <= 0) {
    return const AnalysisSpectrum.error('无法从时间基准计算采样率');
  }
  if (deltas.last > medianDelta * 5) {
    return const AnalysisSpectrum.error('数据中存在过大的采样时间间隔');
  }
  final maximumJitter = deltas.fold<double>(0, (maximum, value) {
    return math.max(maximum, (value - medianDelta).abs() / medianDelta);
  });
  final duration = times.last - times.first;
  if (!duration.isFinite || duration <= 0) {
    return const AnalysisSpectrum.error('分析区间的持续时间无效');
  }

  final shouldResample = maximumJitter > 0.01;
  final uniformValues = shouldResample
      ? _resampleUniform(times, values)
      : values;
  final sampleInterval = duration / (uniformValues.length - 1);
  final sampleRate = 1 / sampleInterval;
  final sampleCount = uniformValues.length;
  var fftSize = 1;
  while (fftSize < sampleCount) {
    fftSize <<= 1;
  }

  final real = Float64List(fftSize);
  final imaginary = Float64List(fftSize);
  final mean = removeDc
      ? uniformValues.reduce((left, right) => left + right) / sampleCount
      : 0.0;
  var windowSum = 0.0;
  for (var index = 0; index < sampleCount; index += 1) {
    final weight = _windowWeight(window, index, sampleCount);
    windowSum += weight;
    real[index] = (uniformValues[index] - mean) * weight;
  }
  if (windowSum <= 0) {
    return const AnalysisSpectrum.error('窗函数参数无效');
  }
  _fftInPlace(real, imaginary);

  var peakFrequency = 0.0;
  var peakAmplitude = 0.0;
  final lastBin = fftSize ~/ 2;
  final amplitudes = Float64List(lastBin + 1);
  for (var bin = 0; bin <= lastBin; bin += 1) {
    final magnitude = math.sqrt(
      real[bin] * real[bin] + imaginary[bin] * imaginary[bin],
    );
    final edgeBin = bin == 0 || bin == lastBin;
    final amplitude = magnitude / windowSum * (edgeBin ? 1 : 2);
    final frequency = bin * sampleRate / fftSize;
    amplitudes[bin] = amplitude;
    if (bin > 0 && amplitude > peakAmplitude) {
      peakAmplitude = amplitude;
      peakFrequency = frequency;
    }
  }
  return AnalysisSpectrum(
    points: UniformAnalysisPoints(amplitudes, step: sampleRate / fftSize),
    sampleRate: sampleRate,
    sampleCount: sampleCount,
    fftSize: fftSize,
    resampled: shouldResample,
    peakFrequency: peakFrequency,
    peakAmplitude: peakAmplitude,
  );
}

double? _interpolateSeriesValue(List<AnalysisPoint> points, double x) {
  if (points.isEmpty ||
      x < analysisXAt(points, 0) ||
      x > analysisXAt(points, points.length - 1)) {
    return null;
  }
  final after = lowerBoundAnalysisPoints(points, x);
  if (after < points.length && analysisXAt(points, after) == x) {
    return analysisYAt(points, after);
  }
  if (after == 0 || after >= points.length) return null;
  final leftX = analysisXAt(points, after - 1);
  final leftY = analysisYAt(points, after - 1);
  final span = analysisXAt(points, after) - leftX;
  if (span <= 0) return null;
  final fraction = (x - leftX) / span;
  return leftY + (analysisYAt(points, after) - leftY) * fraction;
}

Float64List _resampleUniform(Float64List times, Float64List values) {
  final result = Float64List(values.length);
  final start = times.first;
  final step = (times.last - start) / (values.length - 1);
  var source = 1;
  for (var index = 0; index < result.length; index += 1) {
    final time = index == result.length - 1 ? times.last : start + step * index;
    while (source < times.length - 1 && times[source] < time) {
      source += 1;
    }
    final leftIndex = source - 1;
    final span = times[source] - times[leftIndex];
    final fraction = span <= 0 ? 0.0 : (time - times[leftIndex]) / span;
    result[index] =
        values[leftIndex] + (values[source] - values[leftIndex]) * fraction;
  }
  return result;
}

double _windowWeight(AnalysisWindowFunction window, int index, int length) {
  if (length <= 1) return 1;
  final phase = 2 * math.pi * index / (length - 1);
  return switch (window) {
    AnalysisWindowFunction.rectangular => 1,
    AnalysisWindowFunction.hann => 0.5 * (1 - math.cos(phase)),
    AnalysisWindowFunction.hamming => 0.54 - 0.46 * math.cos(phase),
  };
}

void _fftInPlace(Float64List real, Float64List imaginary) {
  final length = real.length;
  var target = 0;
  for (var index = 1; index < length; index += 1) {
    var bit = length >> 1;
    while (target & bit != 0) {
      target ^= bit;
      bit >>= 1;
    }
    target ^= bit;
    if (index < target) {
      final realValue = real[index];
      real[index] = real[target];
      real[target] = realValue;
      final imaginaryValue = imaginary[index];
      imaginary[index] = imaginary[target];
      imaginary[target] = imaginaryValue;
    }
  }

  for (var blockSize = 2; blockSize <= length; blockSize <<= 1) {
    final angle = -2 * math.pi / blockSize;
    final rootReal = math.cos(angle);
    final rootImaginary = math.sin(angle);
    final half = blockSize >> 1;
    for (var start = 0; start < length; start += blockSize) {
      var twiddleReal = 1.0;
      var twiddleImaginary = 0.0;
      for (var offset = 0; offset < half; offset += 1) {
        final even = start + offset;
        final odd = even + half;
        final oddReal =
            real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary;
        final oddImaginary =
            real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal;
        real[odd] = real[even] - oddReal;
        imaginary[odd] = imaginary[even] - oddImaginary;
        real[even] += oddReal;
        imaginary[even] += oddImaginary;
        final nextReal =
            twiddleReal * rootReal - twiddleImaginary * rootImaginary;
        twiddleImaginary =
            twiddleReal * rootImaginary + twiddleImaginary * rootReal;
        twiddleReal = nextReal;
      }
    }
  }
}
