import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'analysis_data.dart';
import 'analysis_dataset.dart';

/// Retains numeric columns and only the current row, including sparse columns.
class AnalysisCsvBuilder {
  AnalysisCsvBuilder(this.colors);
  final List<Color> colors;
  List<String>? _first;
  bool _hasHeader = false;
  bool _invalid = false;
  final List<_NumericColumn> _columns = [];
  void addLine(String line) {
    if (line.trim().isEmpty || _invalid) return;
    final row = parseAnalysisCsvLine(line);
    if (_first == null) {
      _first = row;
      if (row.length < 2) {
        _invalid = true;
        return;
      }
      _hasHeader = double.tryParse(row.first.trim()) == null;
      _ensureColumns(row.length - 1);
      if (_hasHeader) return;
    }
    _ensureColumns(row.length - 1);
    final x = double.tryParse(row.isEmpty ? '' : row.first.trim());
    if (x == null || !x.isFinite) return;
    for (var col = 1; col < row.length; col++) {
      final y = double.tryParse(row[col].trim());
      if (y != null && y.isFinite) _columns[col - 1].add(x, y);
    }
  }

  void _ensureColumns(int count) {
    while (_columns.length < count) {
      _columns.add(_NumericColumn());
    }
  }

  List<AnalysisSeries> finish() {
    final first = _first;
    if (first == null || _invalid) return const [];
    return [
      for (var i = 0; i < _columns.length; i++)
        if (_columns[i].length > 0)
          AnalysisSeries(
            name:
                _hasHeader &&
                    first.length > i + 1 &&
                    first[i + 1].trim().isNotEmpty
                ? first[i + 1].trim()
                : '通道 ${i + 1}',
            color: colors[i % colors.length],
            points: PackedAnalysisPoints(_columns[i].finish()),
          ).prepare(),
    ];
  }
}

class _NumericColumn {
  Float64List _data = Float64List(2048);
  int length = 0;
  void add(double x, double y) {
    if (length * 2 == _data.length) {
      _data = Float64List(_data.length * 2)..setRange(0, _data.length, _data);
    }
    _data[length * 2] = x;
    _data[length * 2 + 1] = y;
    length++;
  }

  Float64List finish() => Float64List.sublistView(_data, 0, length * 2);
}

List<AnalysisSeries> parseAnalysisCsv(
  String contents, {
  required List<Color> colors,
}) {
  final builder = AnalysisCsvBuilder(colors);
  for (final line in LineSplitter.split(contents)) {
    builder.addLine(line);
  }
  return builder.finish();
}

Future<List<AnalysisSeries>> parseAnalysisCsvInBackground(
  String contents, {
  required List<Color> colors,
}) => compute(_parseText, (
  contents: contents,
  colors: [for (final c in colors) c.toARGB32()],
));
List<AnalysisSeries> _parseText(({String contents, List<int> colors}) input) =>
    parseAnalysisCsv(
      input.contents,
      colors: [for (final c in input.colors) Color(c)],
    );

Future<List<AnalysisSeries>> parseAnalysisCsvFileInBackground(
  String path, {
  required List<Color> colors,
}) => compute(_parseFile, (
  path: path,
  colors: [for (final c in colors) c.toARGB32()],
));
Future<List<AnalysisSeries>> _parseFile(
  ({String path, List<int> colors}) input,
) async {
  final builder = AnalysisCsvBuilder([for (final c in input.colors) Color(c)]);
  await for (final line in File(
    input.path,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    builder.addLine(line);
  }
  return builder.finish();
}

List<String> parseAnalysisCsvLine(String line) {
  final values = <String>[];
  var buffer = StringBuffer();
  var quoted = false;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == '"') {
      if (quoted && index + 1 < line.length && line[index + 1] == '"') {
        buffer.write('"');
        index++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      values.add(buffer.toString());
      buffer = StringBuffer();
    } else {
      buffer.write(char);
    }
  }
  values.add(buffer.toString());
  return values;
}
