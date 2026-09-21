import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis.dart';
import 'package:take_a_look_v2/src/analysis_fft.dart';
import 'package:take_a_look_v2/src/chart/axis_settings.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';
import 'package:take_a_look_v2/src/controller.dart';

void main() {
  test('FFT finds the amplitude and frequency of a selected CSV signal', () {
    const sampleRate = 1024.0;
    const frequency = 50.0;
    const amplitude = 2.0;
    final signal = <AnalysisPoint>[];
    final elapsed = <AnalysisPoint>[];
    for (var index = 0; index < 1024; index += 1) {
      final time = index / sampleRate;
      signal.add(
        AnalysisPoint(
          index.toDouble(),
          amplitude * math.sin(2 * math.pi * frequency * time) + 4,
        ),
      );
      elapsed.add(AnalysisPoint(index.toDouble(), time));
    }

    final spectrum = analysisSpectrumForSeries(signal, timePoints: elapsed);

    expect(spectrum.error, isNull);
    expect(spectrum.sampleRate, closeTo(sampleRate, 1e-6));
    expect(spectrum.peakFrequency, closeTo(frequency, 1e-6));
    expect(spectrum.peakAmplitude, closeTo(amplitude, 0.01));
  });

  test('analysis session detects elapsed_s as the CSV FFT time base', () {
    final session = AnalysisSession()
      ..replaceData(const [
        AnalysisSeries(
          name: 'elapsed_s',
          color: Colors.blue,
          points: [AnalysisPoint(0, 0), AnalysisPoint(1, 0.1)],
        ),
        AnalysisSeries(
          name: 'motor_speed',
          color: Colors.red,
          points: [AnalysisPoint(0, 1), AnalysisPoint(1, 2)],
        ),
      ], '本地 CSV');

    expect(session.fftTimeSeriesIndex, 0);
    expect(session.fftSeriesIndex, 1);
    session.fftVisible = true;
    final restored = AnalysisSession()
      ..applyJson(session.toJson(includeData: true));
    expect(restored.fftVisible, isTrue);
    expect(restored.fftTimeSeriesIndex, 0);
    expect(restored.fftSeriesIndex, 1);
  });

  test(
    'analysis CSV accepts negative X values and computes range statistics',
    () {
      final series = parseAnalysisCsv(
        'time,signal\n-2,4\n-1,2\n0,6\n',
        colors: const [Colors.blue],
      );

      expect(series, hasLength(1));
      expect(series.single.points.first.x, -2);
      final stats = analysisStatsForRange(series.single.points, -2, -1);
      expect(stats?.count, 2);
      expect(stats?.minimum, 2);
      expect(stats?.maximum, 4);
      expect(stats?.average, 3);
    },
  );

  test('analysis CSV can be parsed off the UI isolate', () async {
    final series = await parseAnalysisCsvInBackground(
      'time,signal\n0,1\n1,2\n',
      colors: const [Colors.blue],
    );

    expect(series.single.points, hasLength(2));
    expect(series.single.points.last.y, 2);
  });

  test(
    'analysis session full snapshots carry data and compact snapshots do not',
    () {
      final source = AnalysisSession()
        ..replaceData(const [
          AnalysisSeries(
            name: 'signal',
            color: Colors.red,
            points: [AnalysisPoint(-1, 2), AnalysisPoint(1, 4)],
          ),
        ], 'test CSV')
        ..viewXMin = -0.5
        ..viewXMax = 0.5;

      final restored = AnalysisSession()
        ..applyJson(source.toJson(includeData: true));
      expect(restored.series.single.points.first.x, -1);
      expect(restored.sourceLabel, 'test CSV');

      final compact = source.toJson(includeData: false);
      expect(compact, isNot(contains('series')));
      restored.applyJson(compact);
      expect(restored.series, hasLength(1));
      expect(restored.viewXMin, -0.5);
      expect(restored.viewXMax, 0.5);
    },
  );

  test('controller full snapshot restores the analysis dataset', () {
    final source = TakeALookController();
    final destination = TakeALookController();
    addTearDown(source.dispose);
    addTearDown(destination.dispose);
    source.analysisSession.replaceData(const [
      AnalysisSeries(
        name: 'signal',
        color: Colors.green,
        points: [AnalysisPoint(0, 1), AnalysisPoint(1, 3)],
      ),
    ], 'detached test');

    destination.applySnapshot(source.snapshot());

    expect(destination.analysisSession.series, hasLength(1));
    expect(destination.analysisSession.series.single.points.last.y, 3);
    expect(destination.analysisSession.sourceLabel, 'detached test');
    final periodic = source.stateSnapshot();
    final analysis = Map<String, dynamic>.from(
      periodic['analysisSession']! as Map,
    );
    expect(analysis, isNot(contains('series')));
  });

  test('axis validation applies a caller-provided lower bound', () {
    final analysisDraft = AxisSettingsDraft(
      automatic: false,
      minimum: -2,
      maximum: 2,
      mouseEnabled: true,
      inverted: false,
    );
    final realtimeDraft = AxisSettingsDraft(
      automatic: false,
      minimum: -2,
      maximum: 2,
      mouseEnabled: true,
      inverted: false,
      minimumAllowed: 0,
    );
    addTearDown(analysisDraft.dispose);
    addTearDown(realtimeDraft.dispose);

    expect(analysisDraft.validate(xAxis: true), isNotNull);
    expect(realtimeDraft.validate(xAxis: true), isNull);
  });

  test('cartesian viewport maps pixels and values in both directions', () {
    const normal = CartesianPlotViewport(
      plot: Rect.fromLTWH(10, 20, 100, 200),
      xMin: -5,
      xMax: 5,
      yMin: -10,
      yMax: 10,
    );
    const inverted = CartesianPlotViewport(
      plot: Rect.fromLTWH(10, 20, 100, 200),
      xMin: -5,
      xMax: 5,
      yMin: -10,
      yMax: 10,
      invertX: true,
      invertY: true,
    );

    expect(normal.unmapX(normal.mapX(2)), closeTo(2, 1e-9));
    expect(normal.unmapY(normal.mapY(-3)), closeTo(-3, 1e-9));
    expect(inverted.unmapX(inverted.mapX(2)), closeTo(2, 1e-9));
    expect(inverted.unmapY(inverted.mapY(-3)), closeTo(-3, 1e-9));
    expect(
      zoomCartesianWindow(
        minimum: 0,
        maximum: 10,
        dataMinimum: 0,
        dataMaximum: 10,
        anchorFraction: 0.5,
        scale: 0.5,
      ),
      (2.5, 7.5),
    );
  });
}
