import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis/analysis_data.dart';
import 'package:take_a_look_v2/src/analysis/analysis_fft.dart';
import 'package:take_a_look_v2/src/analysis/analysis_worker.dart';

void main() {
  test(
    'worker preserves spectrum and reuses resident input across selections',
    () async {
      final worker = FftAnalysisWorker();
      addTearDown(worker.dispose);
      final signal = _signal(4096);
      final reference = analysisSpectrumForSeries(signal);
      final first = (await worker.analyze(signal))!;
      expect(first.peakFrequency, closeTo(64, 1e-9));
      expect(first.peakAmplitude, closeTo(2, 0.001));
      expect(first.points, hasLength(reference.points.length));
      for (var i = 0; i < first.points.length; i++) {
        expect(first.points[i].y, closeTo(reference.points[i].y, 1e-12));
      }
      final selected = (await worker.analyze(
        signal,
        selectionStart: 0,
        selectionEnd: 1023 / 4096,
      ))!;
      expect(selected.sampleCount, 1024);
      expect(selected.peakFrequency, closeTo(64, 1e-9));
      expect(worker.datasetUploadCount, 1);
      worker.clearData();
      await worker.analyze(signal);
      expect(worker.datasetUploadCount, 2);
    },
  );

  test(
    'only the newest queued result is delivered while work is in flight',
    () async {
      final worker = FftAnalysisWorker();
      addTearDown(worker.dispose);
      await worker.analyze(_signal(32));
      final signal = _signal(262144);
      final active = worker.analyze(signal);
      await Future<void>.value(); // dispatches to the resident isolate first
      final superseded = worker.analyze(
        signal,
        selectionStart: 0,
        selectionEnd: 1,
      );
      final latest = worker.analyze(
        signal,
        selectionStart: 0,
        selectionEnd: 1023 / 4096,
      );
      expect(await active, isNull);
      expect(await superseded, isNull);
      expect((await latest)!.sampleCount, 1024);
      expect(worker.datasetUploadCount, 2);
    },
  );

  test('worker can change time bases and recover from invalid data', () async {
    final worker = FftAnalysisWorker();
    addTearDown(worker.dispose);
    final signal = _signal(1024);
    final indexed = [
      for (var i = 0; i < signal.length; i++)
        AnalysisPoint(i.toDouble(), signal[i].y),
    ];
    final times = [
      for (var i = 0; i < signal.length; i++)
        AnalysisPoint(i.toDouble(), signal[i].x),
    ];
    final first = (await worker.analyze(indexed, timePoints: times))!;
    expect(first.sampleRate, closeTo(4096, 1e-9));
    final invalid = await worker.analyze(const [AnalysisPoint(0, 1)]);
    expect(invalid!.error, isNotNull);
    final recovered = (await worker.analyze(
      signal,
      window: AnalysisWindowFunction.rectangular,
    ))!;
    expect(recovered.error, isNull);
    expect(recovered.peakFrequency, closeTo(64, 1e-9));
  });

  test(
    'disposing during startup cancels callers and releases the isolate',
    () async {
      final worker = FftAnalysisWorker();
      final result = worker.analyze(_signal(4096));
      worker.dispose();
      expect(await result, isNull);
      await expectLater(worker.analyze(_signal(16)), throwsStateError);
    },
  );

  test('numeric FFT retains DC and Nyquist scaling and handles jitter', () {
    final alternating = [
      for (var i = 0; i < 64; i++)
        AnalysisPoint(i / 64, 4 + (i.isEven ? 2 : -2)),
    ];
    final spectrum = analysisSpectrumForSeries(
      alternating,
      window: AnalysisWindowFunction.rectangular,
      removeDc: false,
    );
    expect(spectrum.points.first.y, closeTo(4, 1e-10));
    expect(spectrum.points.last.y, closeTo(2, 1e-10));
    expect(spectrum.peakFrequency, 32);
    expect(
      () => spectrum.points[0] = const AnalysisPoint(0, 0),
      throwsUnsupportedError,
    );
    final jittered = [
      for (var i = 0; i < 4096; i++)
        AnalysisPoint(
          (i + (i.isOdd ? 0.1 : 0)) / 4096,
          2 * math.sin(2 * math.pi * 64 * (i + (i.isOdd ? 0.1 : 0)) / 4096),
        ),
    ];
    final resampled = analysisSpectrumForSeries(jittered);
    expect(resampled.error, isNull);
    expect(resampled.resampled, isTrue);
    expect(resampled.peakFrequency, closeTo(64, 0.1));
    expect(resampled.peakAmplitude, closeTo(2, 0.02));
  });
}

List<AnalysisPoint> _signal(int count) => [
  for (var i = 0; i < count; i++)
    AnalysisPoint(i / 4096, 3 + 2 * math.sin(2 * math.pi * 64 * i / 4096)),
];
