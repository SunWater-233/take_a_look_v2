// dart compile exe tool/benchmarks/history_benchmark.dart -o build/history_benchmark.exe
// build/history_benchmark.exe build/history-benchmark
// Measures the production disk reader in AOT, including worker startup and
// transfers. The heartbeat is the Dart main isolate, not a rendered frame rate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:take_a_look_v2/src/telemetry/numeric_history.dart';

Future<void> main(List<String> arguments) async {
  final output = Directory(
    arguments.isEmpty ? 'build/history-benchmark' : arguments.first,
  ).absolute;
  output.createSync(recursive: true);
  final rows = <Map<String, Object?>>[];
  for (final (channels, samples) in [(1, 1000003), (32, 131075)]) {
    final path = '${output.path}/data-$channels';
    final writing = Stopwatch()..start();
    await Isolate.run(() => _fixture(path, channels, samples));
    final writeMs = writing.elapsedMicroseconds / 1000;
    final keys = [for (var c = 0; c < channels; c++) 'c$c'];
    final last = (samples - 1) / 1000;
    final maxPoints = (131072 ~/ channels).clamp(512, 16384);
    final queries = <(String, double, double)>[
      ('overview', 0, last),
      ('detail', 10, 10.02),
      for (var i = 0; i < 8; i++) ('pan-$i', 10 + i * 3.0, 34 + i * 3.0),
    ];
    for (final (name, start, end) in queries) {
      final request = HistoryRequest(
        path: path,
        keys: keys,
        start: start,
        end: end,
        sourceEnd: last,
        buckets: math.min(name.startsWith('pan') ? 2400 : 1200, maxPoints ~/ 5),
        maxPoints: maxPoints,
      );
      var maxGapUs = 0, ticks = 0;
      final elapsed = Stopwatch()..start();
      var previous = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 4), (_) {
        final now = elapsed.elapsedMicroseconds;
        maxGapUs = math.max(maxGapUs, now - previous);
        previous = now;
        ticks++;
      });
      final result = await readNumericHistory(request);
      final duration = elapsed.elapsedMicroseconds;
      maxGapUs = math.max(maxGapUs, duration - previous);
      heartbeat.cancel();
      if (result.series.values.any((data) => data.length ~/ 2 > maxPoints)) {
        throw StateError('Output budget exceeded');
      }
      if (name == 'overview' && !result.series['c0']!.contains(99999)) {
        throw StateError('Spike lost');
      }
      rows.add({
        'channels': channels,
        'samplesPerChannel': samples,
        'case': name,
        'milliseconds': duration / 1000,
        'bytesRead': result.bytesRead,
        'rawPointsRead': result.rawPointsRead,
        'summaryNodesRead': result.summaryNodesRead,
        'returnedPoints': result.series.values.fold<int>(
          0,
          (sum, values) => sum + values.length ~/ 2,
        ),
        'mainIsolateMaxGapMs': maxGapUs / 1000,
        'heartbeatTicks': ticks,
        'fixtureWriteMs': writeMs,
      });
      stdout.writeln(
        '$channels channels $name: ${(duration / 1000).toStringAsFixed(2)} ms, ${result.bytesRead} bytes, main gap ${(maxGapUs / 1000).toStringAsFixed(2)} ms',
      );
    }
  }
  File('${output.path}/results.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'mode': 'Dart Windows AOT; synthetic data; OS cache may be warm',
      'dart': Platform.version,
      'results': rows,
    }),
  );
}

void _fixture(String path, int channels, int samples) {
  final writer = NumericHistoryWriter(Directory(path));
  final schema = [
    for (var c = 0; c < channels; c++) {'key': 'c$c', 'name': 'Channel $c'},
  ];
  try {
    for (var start = 0; start < samples; start += 1024) {
      writer.append([
        for (var i = start; i < math.min(samples, start + 1024); i++)
          <Object>[
            i / 1000,
            for (var c = 0; c < channels; c++) ...[
              c,
              i == 12345 ? 99999.0 : math.sin(i / (31 + c)) * (c + 1),
            ],
          ],
      ], schema);
    }
  } finally {
    writer.close();
  }
}
