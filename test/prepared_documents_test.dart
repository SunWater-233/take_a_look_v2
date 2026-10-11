import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/telemetry/sample_buffer.dart';
import 'package:take_a_look_v2/src/panels/source_documents.dart';
import 'package:take_a_look_v2/src/panels/source_highlighter.dart';
import 'package:take_a_look_v2/src/panels/source_search.dart';

void main() {
  test(
    'streamed CSV matches prepared text for ragged, quoted and sparse rows',
    () async {
      final directory = await Directory.systemTemp.createTemp('tal_import_');
      addTearDown(() => directory.delete(recursive: true));
      const input =
          'time,"a,""quoted""",b\r\n2,4,\r\n-1,2,3\r\nbad,99,88,77\r\n2,5,6\r\n3,NaN,Infinity\r\n';
      final file = File('${directory.path}/input.csv');
      await file.writeAsString(input);
      final text = parseAnalysisCsv(
        input,
        colors: const [Colors.blue, Colors.red],
      );
      final stream = await parseAnalysisCsvFileInBackground(
        file.path,
        colors: const [Colors.blue, Colors.red],
      );
      expect(
        stream.map((s) => s.toJson()).toList(),
        text.map((s) => s.toJson()).toList(),
      );
      expect(stream.first.name, 'a,"quoted"');
      expect(stream.first.points.map((p) => [p.x, p.y]).toList(), [
        [-1.0, 2.0],
        [2.0, 4.0],
        [2.0, 5.0],
      ]);
      final session = AnalysisSession()..replaceData(stream, 'CSV');
      expect(
        identical(session.series.first.points, stream.first.points),
        isTrue,
      );
      expect(
        () => session.series.first.points.add(const AnalysisPoint(9, 9)),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'numeric preparation copies caller data and realtime imports stay frozen',
    () {
      final input = [const AnalysisPoint(2, 4), const AnalysisPoint(1, 2)];
      final session = AnalysisSession()
        ..replaceData([
          AnalysisSeries(name: 'a', color: Colors.blue, points: input),
        ], 'fixture');
      input[0] = const AnalysisPoint(100, 100);
      expect(session.series.first.points.map((p) => p.x).toList(), [1, 2]);
      final samples = SampleBuffer(capacity: 3)
        ..addXY(0, 1)
        ..addXY(1, 2)
        ..addXY(2, 3);
      final frozen = AnalysisSeries.fromSamples(
        name: 'b',
        color: Colors.red,
        samples: samples,
      );
      samples.addXY(3, 9);
      samples.clear();
      expect(frozen.points.map((p) => p.y).toList(), [1, 2, 3]);
      final restored = AnalysisSeries.fromJson(frozen.toJson(packed: true));
      expect(restored.points.map((p) => [p.x, p.y]).toList(), [
        [0, 1],
        [1, 2],
        [2, 3],
      ]);
    },
  );
  test(
    'source documents share reads and resolve build-machine aliases',
    () async {
      final directory = await Directory.systemTemp.createTemp('tal_sources_');
      addTearDown(() => directory.delete(recursive: true));
      final local = File('${directory.path}/src/main.c');
      await local.parent.create();
      await local.writeAsString('int first;');
      final documents = SourceDocuments();
      final a = documents.read(
        'Z:/firmware/src/main.c',
        sourceRoot: directory.path,
      );
      final b = documents.read(
        'Z:/firmware/src/main.c',
        sourceRoot: directory.path,
      );
      expect(identical(a, b), isTrue);
      expect((await a).text, 'int first;');
      await local.writeAsString('int second;');
      documents.invalidate('Z:/firmware/src/main.c');
      expect(
        (await documents.read(
          'Z:/firmware/src/main.c',
          sourceRoot: directory.path,
        )).text,
        'int second;',
      );
    },
  );
  test(
    'large source highlighting runs in background and reuses prepared text',
    () async {
      final text = SourceSearchText(
        ('uint32_t counter = 0x1234; // 注释\n') * 10000,
      );
      final highlighter = SourceHighlighter();
      final first = highlighter.prepare(text);
      expect(identical(first, highlighter.prepare(text)), isTrue);
      final prepared = await first;
      expect(prepared.lines, hasLength(10001));
      expect(
        prepared.lines.first.spans.map((s) => s.text).join(),
        'uint32_t counter = 0x1234; // 注释',
      );
      expect(prepared.maximumLineLength, prepared.lines.first.rawText.length);
      expect(
        prepared.lines.first.spans.first.style!.color,
        const Color(0xFF4EC9B0),
      );
    },
  );
}
