import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/telemetry/numeric_history.dart';
import 'package:take_a_look_v2/src/telemetry/raw_recording.dart';

void main() {
  final backend = Directory('backend').absolute;
  final python = File(
    Platform.isWindows
        ? '${backend.path}/.venv/Scripts/python.exe'
        : '${backend.path}/.venv/bin/python',
  );
  late Directory directory;
  late RawSampleRecording recording;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tal_history_');
    recording = RawSampleRecording(directory);
  });
  tearDown(() {
    recording.close();
    directory.deleteSync(recursive: true);
  });

  HistoryRequest request(double start, double end, {int buckets = 400}) =>
      HistoryRequest(
        path: recording.status['historyPath'] as String,
        keys: ['a', 'b', 'missing'],
        start: start,
        end: end,
        sourceEnd: end,
        buckets: buckets,
        maxPoints: 2000,
      );

  test(
    'history keeps sparse channels, duplicate times, gaps and session files',
    () async {
      recording.append(
        [
          {
            'elapsed': 1.0,
            'values': <String, double>{'a': 1},
          },
          {
            'elapsed': 1.0,
            'values': <String, double>{'a': 2},
          },
          {
            'elapsed': 3.0,
            'values': <String, double>{'b': 9},
          },
          {
            'elapsed': 2.0,
            'values': <String, double>{'a': 4},
          },
          {
            'elapsed': 2.5,
            'values': <String, double>{'a': double.nan},
          },
        ],
        {'a': 'Alpha', 'b': 'Beta'},
      );
      final saved = request(0, 4);
      final result = await readNumericHistory(saved);
      expect(result.series['a']!.take(6), [1, 1, 1, 2, 2, 4]);
      expect(result.series['a']!.last.isNaN, isTrue);
      expect(result.series['b'], [3, 9]);
      expect(result.series['missing'], isEmpty);
      expect(result.reduced, isFalse);
      recording.rotate();
      expect(recording.status['historyPath'], isNull);
      expect((await readNumericHistory(saved)).series['b'], [3, 9]);
    },
  );

  test(
    'large overview preserves spikes, zoom restores exact samples and reads only relevant branches',
    () async {
      const count = 262147; // Three tree levels plus an incomplete tail.
      for (var start = 0; start < count; start += 4096) {
        recording.append(
          [
            for (var i = start; i < math.min(count, start + 4096); i++)
              {
                'elapsed': i / 1000,
                'values': <String, double>{
                  'a': i == 10003
                      ? 9000
                      : i == 190009
                      ? -8000
                      : math.sin(i / 30),
                },
              },
          ],
          {'a': 'Alpha'},
        );
      }
      final overview = await readNumericHistory(request(0, 263));
      expect(overview.reduced, isTrue);
      expect(overview.series['a']!.length ~/ 2, lessThanOrEqualTo(2000));
      expect(
        overview.series['a'],
        containsAll([10.003, 9000, 190.009, -8000, 262.146]),
      );
      expect(overview.rawPointsRead, lessThan(64));
      expect(overview.bytesRead, lessThan(count * 16 ~/ 5));

      final detail = await readNumericHistory(request(100.001, 100.010));
      expect(detail.reduced, isFalse);
      expect(detail.series['a'], [
        for (var i = 100001; i <= 100010; i++) ...[i / 1000, math.sin(i / 30)],
      ]);
      expect(detail.rawPointsRead, lessThan(256));
      expect(detail.bytesRead, lessThan(300000));

      // Summaries are append-only and must not omit newly completed nodes/tails.
      recording.append(
        [
          {
            'elapsed': 263.0,
            'values': <String, double>{'a': 42, 'b': 5},
          },
        ],
        {'a': 'Alpha', 'b': 'Beta'},
      );
      final tail = await readNumericHistory(request(262.145, 263));
      expect(tail.series['a']!.last, 42);
      expect(tail.series['b'], [263, 5]);
    },
  );

  test(
    'out-of-order timestamps across tree blocks still return chronological exact values',
    () async {
      recording.append(
        [
          for (var i = 0; i < 1000; i++)
            {
              'elapsed': (1000 - i) / 100,
              'values': <String, double>{'a': i.toDouble()},
            },
        ],
        {'a': 'Alpha'},
      );
      final result = await readNumericHistory(request(4.0, 4.03));
      expect(result.series['a'], [4, 600, 4.01, 599, 4.02, 598, 4.03, 597]);
    },
  );

  test(
    'Dart reader consumes the production Python writer format',
    () async {
      final output = await Process.run(python.path, [
        '-c',
        '''
from pathlib import Path
from take_a_look_backend.services.recording import RawRecording
import sys
r = RawRecording(Path(sys.argv[1]))
for start in range(0, 262147, 4096):
    r.append(((i / 1000, {'a': 9999 if i == 12345 else i % 11}) for i in range(start, min(start + 4096, 262147))), {'a':'Alpha'})
print(r.status()['historyPath'])
r.close()
''',
        directory.path,
      ], workingDirectory: backend.path);
      expect(output.exitCode, 0, reason: '${output.stderr}');
      final path = '${output.stdout}'.trim();
      final overview = await readNumericHistory(
        HistoryRequest(
          path: path,
          keys: ['a'],
          start: 0,
          end: 263,
          sourceEnd: 263,
          buckets: 400,
          maxPoints: 2000,
        ),
      );
      expect(overview.series['a'], containsAll([12.345, 9999, 262.146]));
      expect(overview.rawPointsRead, lessThan(64));
      final detail = await readNumericHistory(
        HistoryRequest(
          path: path,
          keys: ['a'],
          start: 12.344,
          end: 12.346,
          sourceEnd: 263,
          buckets: 400,
        ),
      );
      expect(detail.series['a'], [
        12.344,
        12344 % 11,
        12.345,
        9999,
        12.346,
        12346 % 11,
      ]);
    },
    skip: !python.existsSync() ? 'Run tool/setup_backend first.' : false,
  );
}
