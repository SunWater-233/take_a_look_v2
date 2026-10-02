// Run through tool/run_data_benchmarks.ps1 in a separate Flutter release app.
// Production algorithms are imported, not copied or modified for the benchmark.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/analysis/analysis_fft.dart';
import 'package:take_a_look_v2/src/analysis/analysis_worker.dart';
import 'package:take_a_look_v2/src/backend/backend_transport.dart';
import 'package:take_a_look_v2/src/chart/downsampling.dart';
import 'package:take_a_look_v2/src/chart/painter.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/telemetry/telemetry_store.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

double _checksum = 0;
final _results = <Map<String, Object?>>[];
late File _progress;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = File(
    Platform.environment['TAL_BENCH_OUTPUT'] ?? 'data-benchmark.json',
  );
  output.parent.createSync(recursive: true);
  _progress = File('${output.path}.progress.jsonl')..writeAsStringSync('');
  final started = DateTime.now();
  try {
    if (!kReleaseMode) throw StateError('This benchmark requires release AOT.');
    _checkFixtures();
    if (Platform.environment['TAL_BENCH_SUITE'] == 'heartbeat') {
      await _responsivenessBenchmarks();
    } else if (Platform.environment['TAL_BENCH_SUITE'] == 'worker') {
      await _productionWorkerBenchmarks();
    } else if (Platform.environment['TAL_BENCH_SUITE'] == 'live') {
      await _liveWindowBenchmark();
    } else {
      await _acquisitionBenchmarks();
      await _downsamplingBenchmarks();
      await _fftBenchmarks();
      await _csvBenchmarks();
      await _responsivenessBenchmarks();
      await _paintingBenchmarks();
    }
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'status': 'passed',
        'startedAt': started.toIso8601String(),
        'finishedAt': DateTime.now().toIso8601String(),
        'mode': 'Flutter Windows release AOT',
        'suite': Platform.environment['TAL_BENCH_SUITE'] ?? 'all',
        'dartVersion': Platform.version,
        'os': Platform.operatingSystemVersion,
        'logicalProcessors': Platform.numberOfProcessors,
        'maxRssBytes': ProcessInfo.maxRss,
        'checksum': _checksum,
        'method':
            'Synthetic inputs; production functions imported from the workspace. '
            'Individual cases record what is included. Microbenchmarks exclude '
            'input generation and use three warm-ups and calibrated blocks. '
            'Live mode includes widgets and concurrent acquisition/analysis. '
            'No physical probe, OS pipe, disk recording or multi-window traffic.',
        'results': _results,
      }),
    );
    exit(0);
  } catch (error, stack) {
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'status': 'failed',
        'error': '$error',
        'stack': '$stack',
        'results': _results,
      }),
    );
    exit(1);
  }
}

Future<void> _productionWorkerBenchmarks() async {
  for (final count in [131072, 1048576]) {
    final worker = FftAnalysisWorker();
    final signal = _signal(count);
    final first = Stopwatch()..start();
    final initial = await worker.analyze(signal);
    first.stop();
    if (initial?.error != null || initial?.sampleCount != count) {
      throw StateError('Production worker returned an invalid spectrum');
    }
    final gaps = <double>[];
    final clock = Stopwatch()..start();
    var previous = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = clock.elapsedMicroseconds;
      gaps.add((now - previous) / 1000);
      previous = now;
    });
    final times = <double>[];
    for (var pass = 0; pass < 9; pass++) {
      final timer = Stopwatch()..start();
      final spectrum = (await worker.analyze(signal))!;
      timer.stop();
      if (spectrum.sampleCount != count ||
          spectrum.points.length != count ~/ 2 + 1) {
        throw StateError('Production worker lost spectrum bins');
      }
      _checksum += spectrum.peakAmplitude;
      times.add(timer.elapsedMicroseconds / 1000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    heartbeat.cancel();
    times.sort();
    gaps.sort();
    if (worker.datasetUploadCount != 1) {
      throw StateError('Input was uploaded repeatedly');
    }
    _record({
      'name': 'production_worker_$count',
      'inputPoints': count,
      'firstRequestMs': first.elapsedMicroseconds / 1000,
      'medianMs': _percentile(times, 0.5),
      'p95Ms': _percentile(times, 0.95),
      'maxHeartbeatGapMs': gaps.last,
      'datasetUploadCount': worker.datasetUploadCount,
      'note':
          'Real FftAnalysisWorker, full spectrum returned through TransferableTypedData; '
          'first request includes startup and input upload, steady requests reuse inputs.',
    });
    worker.dispose();
  }
}

Future<void> _liveWindowBenchmark() async {
  const channels = 32;
  const rate = 10000;
  const framesPerBatch = 64;
  const warmupUs = 2000000;
  final input = _watches(channels);
  final controller = TakeALookController(backendCommand: (_, _) async {});
  controller.applySnapshot({
    'connectionStatus': 'connected',
    'sampleRateHz': rate.toDouble(),
    'displayRefreshMode': 'standard',
    'plotVisibleWindowSeconds': 0.2,
    'symbols': [for (final watch in input) watch.symbol.toJson()],
    'watches': [
      for (final watch in input)
        {
          'key': watch.symbol.key,
          'plotted': true,
          'sampling': true,
          'color': watch.color.toARGB32(),
        },
    ],
  });
  controller.analysisSession.replaceData([
    AnalysisSeries(
      name: 'FFT fixture',
      color: Colors.cyan,
      points: _signal(131072),
    ),
  ], 'benchmark');
  controller.analysisSession.fftVisible = true;
  final uiErrors = <String>[];
  final previousErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    uiErrors.add(details.exceptionAsString());
  };
  runApp(
    MaterialApp(
      theme: buildTalTheme(),
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: buildWorkspacePanelBody(
                      WorkspacePanelId.plot,
                      controller,
                    ),
                  ),
                  SizedBox(
                    height: 230,
                    child: buildWorkspacePanelBody(
                      WorkspacePanelId.watch,
                      controller,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: buildWorkspacePanelBody(
                WorkspacePanelId.analysis,
                controller,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  final clock = Stopwatch()..start();
  final buildTimes = <double>[];
  final rasterTimes = <double>[];
  void timings(List<ui.FrameTiming> frames) {
    if (clock.elapsedMicroseconds < warmupUs) return;
    for (final frame in frames) {
      buildTimes.add(frame.buildDuration.inMicroseconds / 1000);
      rasterTimes.add(frame.rasterDuration.inMicroseconds / 1000);
    }
  }

  WidgetsBinding.instance.addTimingsCallback(timings);
  var telemetryNotifications = 0;
  controller.telemetryChanges.addListener(() {
    if (clock.elapsedMicroseconds >= warmupUs) telemetryNotifications++;
  });
  var receivedFrames = 0;
  final keys = _keys(channels);
  final decoder = BackendStreamDecoder(
    onJsonLine: (_) {},
    onSamplePayload: (bytes) {
      final batch = decodeBackendSamplePayload(bytes, keys);
      controller.applyBackendSampleBatch(batch);
      receivedFrames += batch.frameCount;
    },
  );
  final payload = _payload(channels, framesPerBatch);
  final data = ByteData.sublistView(payload);
  final frameSize = 8 + (channels + 7) ~/ 8 + channels * 8;
  var sentFrames = 0;
  var maxBacklogFrames = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final due = clock.elapsedMicroseconds * rate ~/ 1000000;
    maxBacklogFrames = math.max(maxBacklogFrames, due - sentFrames);
    while (sentFrames + framesPerBatch <= due) {
      data.setUint32(5, sentFrames ~/ framesPerBatch, Endian.little);
      for (var frame = 0; frame < framesPerBatch; frame++) {
        final offset = 15 + frame * frameSize;
        data.setFloat64(offset, (sentFrames + frame) / rate, Endian.little);
        for (var channel = 0; channel < channels; channel++) {
          data.setFloat64(
            offset + 8 + (channels + 7) ~/ 8 + channel * 8,
            math.sin((sentFrames + frame) / 32 + channel) + channel / 4,
            Endian.little,
          );
        }
      }
      for (final chunk in _wireChunks(payload)) {
        decoder.add(chunk);
      }
      sentFrames += framesPerBatch;
    }
  });
  var fftChanges = 0;
  final analysis = Timer.periodic(const Duration(milliseconds: 500), (_) {
    controller.analysisSession.selectionStart = (fftChanges % 3) * 0.25;
    controller.analysisSession.selectionEnd = 6;
    controller.commitAnalysisSession();
    fftChanges++;
  });
  await Future<void>.delayed(const Duration(seconds: 8));
  sampler.cancel();
  analysis.cancel();
  clock.stop();
  WidgetsBinding.instance.removeTimingsCallback(timings);
  buildTimes.sort();
  rasterTimes.sort();
  if (receivedFrames != sentFrames ||
      controller.watches.any(
        (watch) =>
            watch.totalSampleCount != sentFrames ||
            watch.samples.length != 1800,
      )) {
    throw StateError('Live sampling lost data or exceeded the retention limit');
  }
  if (uiErrors.isNotEmpty) throw StateError('Live UI errors: $uiErrors');
  if (buildTimes.isEmpty) {
    throw StateError('No real Flutter frame timings were delivered');
  }
  _record({
    'name': 'live_32x10000_with_fft',
    'channels': channels,
    'requestedHz': rate,
    'receivedFramesPerChannel': receivedFrames,
    'elapsedSeconds': clock.elapsedMicroseconds / 1000000,
    'effectiveHz': receivedFrames / (clock.elapsedMicroseconds / 1000000),
    'maxSchedulingBacklogFrames': maxBacklogFrames,
    'telemetryNotifications': telemetryNotifications,
    'fftSelectionChanges': fftChanges,
    'renderedFramesAfterWarmup': buildTimes.length,
    'buildMedianMs': _percentile(buildTimes, 0.5),
    'buildP95Ms': _percentile(buildTimes, 0.95),
    'rasterMedianMs': _percentile(rasterTimes, 0.5),
    'rasterP95Ms': _percentile(rasterTimes, 0.95),
    'rssBytes': ProcessInfo.currentRss,
    'note':
        'Windows release engine with real plot/watch/analysis widgets in a hidden native '
        'window. Synthetic framed samples; no probe or OS pipe. 2 s warm-up, about 6 s measured. '
        'Frame timings measure engine work, not physical display presentation.',
  });
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 80));
  controller.dispose();
  FlutterError.onError = previousErrorHandler;
}

void _record(Map<String, Object?> result) {
  _results.add(result);
  _progress.writeAsStringSync('${jsonEncode(result)}\n', mode: FileMode.append);
}

Future<void> _measure(
  String name,
  double Function() action, {
  Map<String, Object?> details = const {},
  int blocks = 15,
}) async {
  final warm = Stopwatch()..start();
  for (var i = 0; i < 3; i++) {
    _checksum += action();
  }
  warm.stop();
  final estimateUs = math.max(1.0, warm.elapsedMicroseconds / 3);
  final iterations = (20000 / estimateUs).ceil().clamp(1, 2000);
  final times = <double>[];
  for (var block = 0; block < blocks; block++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      _checksum += action();
    }
    watch.stop();
    times.add(watch.elapsedMicroseconds / 1000 / iterations);
    await Future<void>.delayed(Duration.zero);
  }
  times.sort();
  _record({
    'name': name,
    ...details,
    'medianMs': _percentile(times, 0.5),
    'p95Ms': _percentile(times, 0.95),
    'minMs': times.first,
    'maxMs': times.last,
    'blocks': blocks,
    'operationsPerBlock': iterations,
  });
}

double _percentile(List<double> sorted, double fraction) =>
    sorted[(fraction * (sorted.length - 1)).ceil()];

List<String> _keys(int channels) => [
  for (var i = 0; i < channels; i++) 'channel_$i',
];

Uint8List _payload(int channels, int frames) {
  final validityBytes = (channels + 7) ~/ 8;
  final bytes = ByteData(15 + frames * (8 + validityBytes + 8 * channels))
    ..setUint8(0, 1)
    ..setUint32(1, 1, Endian.little)
    ..setUint32(5, 1, Endian.little)
    ..setUint32(9, frames, Endian.little)
    ..setUint16(13, channels, Endian.little);
  var offset = 15;
  for (var frame = 0; frame < frames; frame++) {
    bytes.setFloat64(offset, 0.18 + frame / 10000, Endian.little);
    offset += 8;
    for (var byte = 0; byte < validityBytes; byte++) {
      bytes.setUint8(offset++, 255);
    }
    for (var channel = 0; channel < channels; channel++) {
      bytes.setFloat64(offset, channel + frame / 100, Endian.little);
      offset += 8;
    }
  }
  return bytes.buffer.asUint8List();
}

List<Uint8List> _wireChunks(Uint8List payload) {
  final wire = Uint8List(payload.length + 5);
  ByteData.sublistView(wire)
    ..setUint8(0, 0)
    ..setUint32(1, payload.length, Endian.little);
  wire.setRange(5, wire.length, payload);
  return [
    for (var start = 0; start < wire.length; start += 4096)
      Uint8List.sublistView(wire, start, math.min(start + 4096, wire.length)),
  ];
}

List<WatchItem> _watches(int channels) => [
  for (var channel = 0; channel < channels; channel++)
    WatchItem(
        symbol: SymbolItem(
          source: 'benchmark.c',
          name: 'channel_$channel',
          address: 0x20000000 + channel * 4,
          type: 'float',
          size: 4,
          backendKey: 'channel_$channel',
        ),
        color: Color(0xFF0080FF + channel * 1000),
      )
      ..samples.addAll([
        for (var i = 0; i < TelemetryStore.retainedSamplesPerWatch; i++)
          Offset(i / 10000, math.sin(i / 20 + channel) + channel / 8),
      ])
      ..totalSampleCount = TelemetryStore.retainedSamplesPerWatch,
];

// Benchmark-only control, not a proposed drop-in production replacement.
// Stores equivalent numeric time/value history without shifting List<Offset>.
class _RingWatch {
  _RingWatch(WatchItem watch)
    : key = watch.symbol.key,
      times = Float64List(TelemetryStore.retainedSamplesPerWatch),
      values = Float64List(TelemetryStore.retainedSamplesPerWatch) {
    for (var i = 0; i < watch.samples.length; i++) {
      times[i] = watch.samples[i].dx;
      values[i] = watch.samples[i].dy;
    }
  }
  final String key;
  final Float64List times;
  final Float64List values;
  int cursor = 0;
  int total = TelemetryStore.retainedSamplesPerWatch;
  double value = 0;
}

double _applyRing(BackendSampleBatch batch, List<_RingWatch> watches) {
  final byKey = {for (final watch in watches) watch.key: watch};
  final schema = [for (final key in batch.keys) byKey[key]];
  for (var frame = 0; frame < batch.frameCount; frame++) {
    for (var variable = 0; variable < batch.variableCount; variable++) {
      final watch = schema[variable];
      if (watch == null || !batch.hasValue(frame, variable)) continue;
      final value = batch.valueAt(frame, variable);
      watch.times[watch.cursor] = batch.elapsedSeconds[frame];
      watch.values[watch.cursor] = value;
      watch.value = value;
      watch.cursor = (watch.cursor + 1) % watch.values.length;
      watch.total++;
    }
  }
  return watches.last.value;
}

void _checkFixtures() {
  final watches = _watches(8);
  final rings = watches.map(_RingWatch.new).toList();
  final batch = decodeBackendSamplePayload(_payload(8, 64), _keys(8));
  final store = TelemetryStore();
  for (var pass = 0; pass < 40; pass++) {
    store.applyBinaryBatch(batch, watches, currentElapsed: 0);
    _applyRing(batch, rings);
  }
  for (var channel = 0; channel < watches.length; channel++) {
    final watch = watches[channel];
    final ring = rings[channel];
    if (watch.totalSampleCount != ring.total) {
      throw StateError('Count mismatch');
    }
    for (var i = 0; i < watch.samples.length; i++) {
      final position = (ring.cursor + i) % ring.values.length;
      if (watch.samples[i].dx != ring.times[position] ||
          watch.samples[i].dy != ring.values[position]) {
        throw StateError('Ring history mismatch');
      }
    }
  }
  final spectrum = analysisSpectrumForSeries(_signal(8192));
  if (spectrum.error != null ||
      (spectrum.peakFrequency - 128).abs() > 0.01 ||
      (spectrum.peakAmplitude - 2).abs() > 0.01) {
    throw StateError('FFT fixture failed');
  }
}

Future<void> _acquisitionBenchmarks() async {
  for (final channels in [8, 32, 64, 128]) {
    const frames = 64;
    final keys = _keys(channels);
    final payload = _payload(channels, frames);
    final chunks = _wireChunks(payload);
    final batch = decodeBackendSamplePayload(payload, keys);
    final watches = _watches(channels);
    final rings = watches.map(_RingWatch.new).toList();
    final store = TelemetryStore();
    final details = <String, Object?>{
      'channels': channels,
      'framesPerBatch': frames,
      'valuesPerOperation': channels * frames,
      'payloadBytes': payload.length,
      'retainedPointsPerChannel': TelemetryStore.retainedSamplesPerWatch,
    };
    await _measure('decode_$channels', () {
      final decoded = decodeBackendSamplePayload(payload, keys);
      return decoded.values.last;
    }, details: details);
    await _measure('cache_current_$channels', () {
      store.applyBinaryBatch(batch, watches, currentElapsed: 0);
      return watches.last.value;
    }, details: details);
    for (final useRing in [false, true]) {
      var lastValue = 0.0;
      var decodedFrames = 0;
      final initialCount = useRing
          ? rings.first.total
          : watches.first.totalSampleCount;
      final decoder = BackendStreamDecoder(
        onJsonLine: (_) {},
        onSamplePayload: (bytes) {
          final decoded = decodeBackendSamplePayload(bytes, keys);
          decodedFrames += decoded.frameCount;
          if (useRing) {
            lastValue = _applyRing(decoded, rings);
          } else {
            store.applyBinaryBatch(decoded, watches, currentElapsed: 0);
            lastValue = watches.last.value;
          }
        },
      );
      await _measure('pipeline_${useRing ? 'ring' : 'current'}_$channels', () {
        for (final chunk in chunks) {
          decoder.add(chunk);
        }
        return lastValue;
      }, details: details);
      final measurement = _results.last;
      final expectedFrames =
          frames *
          (3 +
              (measurement['blocks']! as int) *
                  (measurement['operationsPerBlock']! as int));
      final finalCount = useRing
          ? rings.first.total
          : watches.first.totalSampleCount;
      if (decodedFrames != expectedFrames ||
          finalCount - initialCount != expectedFrames ||
          (lastValue - (channels - 1 + (frames - 1) / 100)).abs() > 1e-10) {
        throw StateError('The acquisition benchmark dropped or altered data');
      }
    }
  }
}

Future<void> _downsamplingBenchmarks() async {
  for (final count in [1800, 100000, 1000000]) {
    final points = [
      for (var i = 0; i < count; i++) Offset(i.toDouble(), math.sin(i / 20)),
    ];
    await _measure('downsample_$count', () {
      final result = downsampleTelemetrySamples(
        points,
        xMin: 0,
        xMax: count - 1.0,
        pixelWidth: 1000,
      );
      if (result.length > 2001) throw StateError('Too many display points');
      return result.length.toDouble();
    }, details: {'inputPoints': count, 'pixelWidth': 1000});
  }
}

List<AnalysisPoint> _signal(int count) => [
  for (var i = 0; i < count; i++)
    AnalysisPoint(i / 16384, 2 * math.sin(2 * math.pi * 128 * i / 16384) + 3),
];

Future<void> _fftBenchmarks() async {
  for (final count in [2048, 8192, 32768, 131072, 262144, 1048576]) {
    final signal = _signal(count);
    await _measure(
      'fft_$count',
      () {
        final spectrum = analysisSpectrumForSeries(signal);
        if (spectrum.error != null) throw StateError(spectrum.error!);
        return spectrum.peakAmplitude + spectrum.peakFrequency;
      },
      details: {
        'inputPoints': count,
        'includes': 'validation, window, FFT, spectrum',
      },
      blocks: count >= 262144 ? 9 : 15,
    );
  }
  const count = 131072;
  final original = _signal(count);
  final indexed = [
    for (var i = 0; i < count; i++) AnalysisPoint(i.toDouble(), original[i].y),
  ];
  final time = [
    for (var i = 0; i < count; i++) AnalysisPoint(i.toDouble(), original[i].x),
  ];
  await _measure(
    'fft_separate_timebase_$count',
    () {
      final spectrum = analysisSpectrumForSeries(indexed, timePoints: time);
      if (spectrum.error != null) throw StateError(spectrum.error!);
      return spectrum.peakFrequency;
    },
    details: {'inputPoints': count, 'separateTimebase': true},
    blocks: 9,
  );
}

Future<void> _csvBenchmarks() async {
  for (final rows in [10000, 100000, 500000]) {
    final text = StringBuffer('time,a,b,c,d,e,f,g,h\n');
    for (var i = 0; i < rows; i++) {
      text.writeln('${i / 10000},1.25,-2.5,3.75,4.125,5.25,6.5,7.75,8.875');
    }
    final csv = text.toString();
    await _measure(
      'csv_${rows}_8',
      () {
        final series = parseAnalysisCsv(csv, colors: const [Color(0xFF0080FF)]);
        if (series.length != 8 || series.last.points.length != rows) {
          throw StateError('CSV fixture failed');
        }
        return series.last.points.last.y;
      },
      details: {'rows': rows, 'channels': 8, 'inputBytes': csv.length},
      blocks: rows >= 100000 ? 7 : 15,
    );
  }
}

Future<void> _responsivenessBenchmarks() async {
  final signal = _signal(262144);
  for (final mode in [
    'idle',
    'main_isolate',
    'worker_isolate',
    'resident_worker_summary',
  ]) {
    ReceivePort? workerResponses;
    StreamIterator<Object?>? replies;
    SendPort? commands;
    final startup = Stopwatch()..start();
    if (mode == 'resident_worker_summary') {
      workerResponses = ReceivePort();
      replies = StreamIterator<Object?>(workerResponses);
      await Isolate.spawn(_residentFftWorker, (
        workerResponses.sendPort,
        signal,
      ));
      await replies.moveNext();
      commands = replies.current! as SendPort;
    }
    startup.stop();
    final gaps = <double>[];
    final clock = Stopwatch()..start();
    var previous = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = clock.elapsedMicroseconds;
      gaps.add((now - previous) / 1000);
      previous = now;
    });
    await Future<void>.delayed(const Duration(milliseconds: 160));
    final operation = Stopwatch()..start();
    for (var pass = 0; pass < 3; pass++) {
      if (mode == 'idle') {
        await Future<void>.delayed(const Duration(milliseconds: 160));
      } else if (mode == 'main_isolate') {
        _checksum += analysisSpectrumForSeries(signal).peakAmplitude;
      } else if (mode == 'resident_worker_summary') {
        commands!.send('run');
        await replies!.moveNext();
        _checksum += replies.current! as double;
      } else {
        final spectrum = await Isolate.run(
          () => analysisSpectrumForSeries(signal),
        );
        _checksum += spectrum.peakAmplitude;
      }
      await Future<void>.delayed(const Duration(milliseconds: 64));
    }
    operation.stop();
    await Future<void>.delayed(const Duration(milliseconds: 160));
    timer.cancel();
    gaps.sort();
    _record({
      'name': 'heartbeat_$mode',
      'inputPoints': signal.length,
      'timerPeriodMs': 16,
      'medianGapMs': _percentile(gaps, 0.5),
      'p95GapMs': _percentile(gaps, 0.95),
      'maxGapMs': gaps.last,
      'elapsedMs': operation.elapsedMicroseconds / 1000,
      'workerStartupMs': startup.elapsedMicroseconds / 1000,
      'note':
          'Event-loop responsiveness, not actual UI frame timings. Worker '
          'isolate includes startup, input transfer and full spectrum return. '
          'Resident worker loads inputs before heartbeat measurement and '
          'returns only the spectrum peak amplitude.',
    });
    commands?.send('stop');
    await replies?.cancel();
    workerResponses?.close();
  }
}

void _residentFftWorker((SendPort, List<AnalysisPoint>) input) async {
  final commands = ReceivePort();
  input.$1.send(commands.sendPort);
  await for (final command in commands) {
    if (command == 'stop') break;
    input.$1.send(analysisSpectrumForSeries(input.$2).peakAmplitude);
  }
  commands.close();
}

Future<void> _paintingBenchmarks() async {
  for (final channels in [8, 32, 64]) {
    final input = _watches(channels);
    final controller = TakeALookController(backendCommand: (_, _) async {});
    controller.applySnapshot({
      'symbols': [for (final watch in input) watch.symbol.toJson()],
      'watches': [
        for (final watch in input)
          {
            'key': watch.symbol.key,
            'plotted': true,
            'sampling': true,
            'color': watch.color.toARGB32(),
          },
      ],
      'elapsedSeconds': 0.18,
      'plotVisibleWindowSeconds': 0.2,
      'followLatest': true,
    });
    for (var i = 0; i < input.length; i++) {
      controller.watches[i].samples.addAll(input[i].samples);
    }
    if (controller.watches.where((watch) => watch.plotted).length != channels ||
        controller.watches.any((watch) => watch.samples.length != 1800)) {
      throw StateError('The chart fixture must actually plot every channel');
    }
    final painter = TelemetryPainter(controller);
    ui.Picture picture() {
      final recorder = ui.PictureRecorder();
      painter.paint(ui.Canvas(recorder), const ui.Size(1200, 600));
      return recorder.endRecording();
    }

    await _measure(
      'paint_record_$channels',
      () {
        final result = picture();
        final bytes = result.approximateBytesUsed;
        result.dispose();
        return bytes.toDouble();
      },
      details: {
        'channels': channels,
        'pointsPerChannel': 1800,
        'canvasWidth': 1200,
        'canvasHeight': 600,
        'includes':
            'production TelemetryPainter CPU recording, not rasterization',
      },
    );
    final durations = <double>[];
    for (var i = 0; i < 12; i++) {
      final timer = Stopwatch()..start();
      final result = picture();
      final image = await result.toImage(1200, 600);
      timer.stop();
      _checksum += image.width;
      image.dispose();
      result.dispose();
      if (i >= 3) durations.add(timer.elapsedMicroseconds / 1000);
    }
    durations.sort();
    _record({
      'name': 'paint_offscreen_$channels',
      'channels': channels,
      'medianMs': _percentile(durations, 0.5),
      'p95Ms': _percentile(durations, 0.95),
      'includes': 'production painter plus toImage offscreen rasterization',
      'note':
          'No widget layout, presentation, live sampling or multi-window traffic',
    });
    controller.dispose();
  }
}
