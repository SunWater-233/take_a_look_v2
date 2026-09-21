import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum AnalysisMouseMode { threeButton, rectangle }

enum AnalysisWindowFunction { rectangular, hann, hamming }

@immutable
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

@immutable
class AnalysisSeries {
  const AnalysisSeries({
    required this.name,
    required this.color,
    required this.points,
  });

  final String name;
  final Color color;
  final List<AnalysisPoint> points;

  Map<String, Object?> toJson() => {
    'name': name,
    'color': color.toARGB32(),
    'points': [for (final point in points) point.toJson()],
  };

  static AnalysisSeries fromJson(Object? value) {
    final data = Map<String, Object?>.from(value! as Map);
    return AnalysisSeries(
      name: data['name'] as String,
      color: Color(data['color'] as int),
      points: List<AnalysisPoint>.unmodifiable(
        (data['points'] as List? ?? const []).map(AnalysisPoint.fromJson),
      ),
    );
  }
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

/// Controller-owned analysis state.
///
/// Unlike widget state, this object survives tab rebuilds and can be included
/// in the one-shot snapshot used to create detached windows. Large point data
/// is omitted from periodic state snapshots and is only transferred on initial
/// attachment or when an import explicitly changes the dataset.
class AnalysisSession {
  static const defaultColumnWidths = <double>[180, 90, 110, 110, 110, 110, 92];

  double statsHeight = 164;
  double statsHorizontalOffset = 0;
  List<double> statsColumnWidths = List<double>.of(defaultColumnWidths);
  double statsRowHeight = 32;
  List<AnalysisSeries> series = const [];
  List<bool> seriesVisibility = const [];
  final Set<int> selectedColumns = <int>{};
  final Set<int> hiddenColumns = <int>{};
  int? selectedSeriesIndex;
  int? selectedCellColumn;
  String sourceLabel = '';
  double? selectionStart;
  double? selectionEnd;
  double? viewXMin;
  double? viewXMax;
  double? viewYMin;
  double? viewYMax;
  AnalysisMouseMode mouseMode = AnalysisMouseMode.threeButton;
  bool mouseXEnabled = true;
  bool mouseYEnabled = true;
  bool invertX = false;
  bool invertY = false;
  bool fftVisible = false;
  int? fftSeriesIndex;
  int? fftTimeSeriesIndex;
  AnalysisWindowFunction fftWindow = AnalysisWindowFunction.hann;
  bool fftRemoveDc = true;
  double? fftSelectionStart;
  double? fftSelectionEnd;
  double? fftViewXMin;
  double? fftViewXMax;
  double? fftViewYMin;
  double? fftViewYMax;
  AnalysisMouseMode fftMouseMode = AnalysisMouseMode.threeButton;
  bool fftMouseXEnabled = true;
  bool fftMouseYEnabled = true;
  bool fftInvertX = false;
  bool fftInvertY = false;

  (double, double, double, double)? _dataBounds;
  List<AnalysisStats?> selectionStats = const [];

  (double, double)? get selectedRange {
    final start = selectionStart;
    final end = selectionEnd;
    if (start == null || end == null) return null;
    return (math.min(start, end), math.max(start, end));
  }

  (double, double, double, double) get dataBounds {
    final cached = _dataBounds;
    if (cached != null) return cached;
    var xMin = double.infinity;
    var xMax = -double.infinity;
    var yMin = double.infinity;
    var yMax = -double.infinity;
    for (final item in series) {
      for (final point in item.points) {
        xMin = math.min(xMin, point.x);
        xMax = math.max(xMax, point.x);
        yMin = math.min(yMin, point.y);
        yMax = math.max(yMax, point.y);
      }
    }
    if (!xMin.isFinite || !xMax.isFinite) {
      return _dataBounds = (0, 1, -1, 1);
    }
    if (xMax <= xMin) {
      xMin -= 0.5;
      xMax += 0.5;
    }
    if (yMax <= yMin) {
      final padding = math.max(1, yMax.abs() * 0.1);
      yMin -= padding;
      yMax += padding;
    } else {
      final padding = (yMax - yMin) * 0.08;
      yMin -= padding;
      yMax += padding;
    }
    return _dataBounds = (xMin, xMax, yMin, yMax);
  }

  void replaceData(List<AnalysisSeries> next, String source) {
    series = List<AnalysisSeries>.unmodifiable([
      for (final item in next)
        AnalysisSeries(
          name: item.name,
          color: item.color,
          points: List<AnalysisPoint>.unmodifiable(
            List<AnalysisPoint>.of(item.points)
              ..sort((left, right) => left.x.compareTo(right.x)),
          ),
        ),
    ]);
    seriesVisibility = List<bool>.filled(series.length, true);
    selectedColumns.clear();
    selectedSeriesIndex = null;
    selectedCellColumn = null;
    sourceLabel = source;
    fftTimeSeriesIndex = source.toLowerCase().contains('csv')
        ? _detectTimeSeriesIndex(series)
        : null;
    fftSeriesIndex = _defaultFftSeriesIndex(series, fftTimeSeriesIndex);
    resetFftViewport();
    selectionStart = null;
    selectionEnd = null;
    selectionStats = const [];
    _dataBounds = null;
    resetViewport();
  }

  void clearData() {
    series = const [];
    seriesVisibility = const [];
    selectedColumns.clear();
    selectedSeriesIndex = null;
    selectedCellColumn = null;
    sourceLabel = '';
    fftVisible = false;
    fftSeriesIndex = null;
    fftTimeSeriesIndex = null;
    fftSelectionStart = null;
    fftSelectionEnd = null;
    resetFftViewport();
    selectionStart = null;
    selectionEnd = null;
    selectionStats = const [];
    _dataBounds = null;
    resetViewport();
  }

  void resetViewport() {
    viewXMin = null;
    viewXMax = null;
    viewYMin = null;
    viewYMax = null;
  }

  void resetFftViewport() {
    fftViewXMin = null;
    fftViewXMax = null;
    fftViewYMin = null;
    fftViewYMax = null;
  }

  void updateSelectionStats() {
    final range = selectedRange;
    selectionStats = range == null
        ? const []
        : [
            for (final item in series)
              analysisStatsForRange(item.points, range.$1, range.$2),
          ];
  }

  Map<String, Object?> toJson({required bool includeData}) => {
    if (includeData) 'series': [for (final item in series) item.toJson()],
    'seriesVisibility': seriesVisibility,
    'sourceLabel': sourceLabel,
    'statsHeight': statsHeight,
    'statsHorizontalOffset': statsHorizontalOffset,
    'statsColumnWidths': statsColumnWidths,
    'statsRowHeight': statsRowHeight,
    'selectedColumns': selectedColumns.toList(),
    'hiddenColumns': hiddenColumns.toList(),
    'selectedSeriesIndex': selectedSeriesIndex,
    'selectedCellColumn': selectedCellColumn,
    'selectionStart': selectionStart,
    'selectionEnd': selectionEnd,
    'viewXMin': viewXMin,
    'viewXMax': viewXMax,
    'viewYMin': viewYMin,
    'viewYMax': viewYMax,
    'mouseMode': mouseMode.name,
    'mouseXEnabled': mouseXEnabled,
    'mouseYEnabled': mouseYEnabled,
    'invertX': invertX,
    'invertY': invertY,
    'fftVisible': fftVisible,
    'fftSeriesIndex': fftSeriesIndex,
    'fftTimeSeriesIndex': fftTimeSeriesIndex,
    'fftWindow': fftWindow.name,
    'fftRemoveDc': fftRemoveDc,
    'fftSelectionStart': fftSelectionStart,
    'fftSelectionEnd': fftSelectionEnd,
    'fftViewXMin': fftViewXMin,
    'fftViewXMax': fftViewXMax,
    'fftViewYMin': fftViewYMin,
    'fftViewYMax': fftViewYMax,
    'fftMouseMode': fftMouseMode.name,
    'fftMouseXEnabled': fftMouseXEnabled,
    'fftMouseYEnabled': fftMouseYEnabled,
    'fftInvertX': fftInvertX,
    'fftInvertY': fftInvertY,
  };

  void applyJson(Map<String, dynamic> data) {
    if (data.containsKey('series')) {
      series = List<AnalysisSeries>.unmodifiable(
        (data['series'] as List? ?? const []).map(AnalysisSeries.fromJson),
      );
      _dataBounds = null;
    }
    if (data.containsKey('seriesVisibility')) {
      seriesVisibility = List<bool>.unmodifiable(
        (data['seriesVisibility'] as List? ?? const []).cast<bool>(),
      );
    }
    sourceLabel = data['sourceLabel'] as String? ?? sourceLabel;
    statsHeight = (data['statsHeight'] as num?)?.toDouble() ?? statsHeight;
    statsHorizontalOffset =
        (data['statsHorizontalOffset'] as num?)?.toDouble() ??
        statsHorizontalOffset;
    final widths = (data['statsColumnWidths'] as List?)
        ?.map((value) => (value as num).toDouble())
        .toList();
    if (widths?.length == defaultColumnWidths.length) {
      statsColumnWidths = widths!;
    }
    statsRowHeight =
        (data['statsRowHeight'] as num?)?.toDouble() ?? statsRowHeight;
    if (data.containsKey('selectedColumns')) {
      selectedColumns
        ..clear()
        ..addAll((data['selectedColumns'] as List? ?? const []).cast<int>());
    }
    if (data.containsKey('hiddenColumns')) {
      hiddenColumns
        ..clear()
        ..addAll((data['hiddenColumns'] as List? ?? const []).cast<int>());
    }
    selectedSeriesIndex = data.containsKey('selectedSeriesIndex')
        ? data['selectedSeriesIndex'] as int?
        : selectedSeriesIndex;
    selectedCellColumn = data.containsKey('selectedCellColumn')
        ? data['selectedCellColumn'] as int?
        : selectedCellColumn;
    selectionStart = _nullableDouble(data, 'selectionStart', selectionStart);
    selectionEnd = _nullableDouble(data, 'selectionEnd', selectionEnd);
    viewXMin = _nullableDouble(data, 'viewXMin', viewXMin);
    viewXMax = _nullableDouble(data, 'viewXMax', viewXMax);
    viewYMin = _nullableDouble(data, 'viewYMin', viewYMin);
    viewYMax = _nullableDouble(data, 'viewYMax', viewYMax);
    final mode = data['mouseMode'] as String?;
    if (mode != null) mouseMode = AnalysisMouseMode.values.byName(mode);
    mouseXEnabled = data['mouseXEnabled'] as bool? ?? mouseXEnabled;
    mouseYEnabled = data['mouseYEnabled'] as bool? ?? mouseYEnabled;
    invertX = data['invertX'] as bool? ?? invertX;
    invertY = data['invertY'] as bool? ?? invertY;
    fftVisible = data['fftVisible'] as bool? ?? fftVisible;
    fftSeriesIndex = data.containsKey('fftSeriesIndex')
        ? data['fftSeriesIndex'] as int?
        : fftSeriesIndex;
    fftTimeSeriesIndex = data.containsKey('fftTimeSeriesIndex')
        ? data['fftTimeSeriesIndex'] as int?
        : fftTimeSeriesIndex;
    final fftWindowName = data['fftWindow'] as String?;
    if (fftWindowName != null) {
      fftWindow = AnalysisWindowFunction.values.firstWhere(
        (value) => value.name == fftWindowName,
        orElse: () => AnalysisWindowFunction.hann,
      );
    }
    fftRemoveDc = data['fftRemoveDc'] as bool? ?? fftRemoveDc;
    fftSelectionStart = _nullableDouble(
      data,
      'fftSelectionStart',
      fftSelectionStart,
    );
    fftSelectionEnd = _nullableDouble(data, 'fftSelectionEnd', fftSelectionEnd);
    fftViewXMin = _nullableDouble(data, 'fftViewXMin', fftViewXMin);
    fftViewXMax = _nullableDouble(data, 'fftViewXMax', fftViewXMax);
    fftViewYMin = _nullableDouble(data, 'fftViewYMin', fftViewYMin);
    fftViewYMax = _nullableDouble(data, 'fftViewYMax', fftViewYMax);
    final fftMouseModeName = data['fftMouseMode'] as String?;
    if (fftMouseModeName != null) {
      fftMouseMode = AnalysisMouseMode.values.firstWhere(
        (value) => value.name == fftMouseModeName,
        orElse: () => AnalysisMouseMode.threeButton,
      );
    }
    fftMouseXEnabled = data['fftMouseXEnabled'] as bool? ?? fftMouseXEnabled;
    fftMouseYEnabled = data['fftMouseYEnabled'] as bool? ?? fftMouseYEnabled;
    fftInvertX = data['fftInvertX'] as bool? ?? fftInvertX;
    fftInvertY = data['fftInvertY'] as bool? ?? fftInvertY;
    _normalizeFftSelection();
    updateSelectionStats();
  }

  void _normalizeFftSelection() {
    if (series.isEmpty) {
      fftSeriesIndex = null;
      fftTimeSeriesIndex = null;
      fftVisible = false;
      return;
    }
    final timeIndex = fftTimeSeriesIndex;
    if (timeIndex != null && (timeIndex < 0 || timeIndex >= series.length)) {
      fftTimeSeriesIndex = null;
    }
    final signalIndex = fftSeriesIndex;
    if (signalIndex == null ||
        signalIndex < 0 ||
        signalIndex >= series.length) {
      fftSeriesIndex = _defaultFftSeriesIndex(series, fftTimeSeriesIndex);
    }
  }

  static double? _nullableDouble(
    Map<String, dynamic> data,
    String key,
    double? current,
  ) {
    if (!data.containsKey(key)) return current;
    return (data[key] as num?)?.toDouble();
  }
}

int? _detectTimeSeriesIndex(List<AnalysisSeries> series) {
  const exactNames = <String>{
    'elapsed_s',
    'elapsed_seconds',
    'time',
    'time_s',
    'timestamp',
    'timestamp_s',
  };
  for (final (index, item) in series.indexed) {
    if (exactNames.contains(item.name.trim().toLowerCase())) return index;
  }
  return null;
}

int? _defaultFftSeriesIndex(List<AnalysisSeries> series, int? timeSeriesIndex) {
  if (series.isEmpty) return null;
  for (var index = 0; index < series.length; index += 1) {
    if (index != timeSeriesIndex) return index;
  }
  return 0;
}

List<AnalysisSeries> parseAnalysisCsv(
  String contents, {
  required List<Color> colors,
}) {
  final rows = [
    for (final line
        in contents.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'))
      if (line.trim().isNotEmpty) parseAnalysisCsvLine(line),
  ];
  if (rows.isEmpty || rows.first.length < 2) return const [];
  final first = rows.first;
  final hasHeader = double.tryParse(first.first.trim()) == null;
  final start = hasHeader ? 1 : 0;
  final columnCount = rows
      .skip(start)
      .fold<int>(first.length, (count, row) => math.max(count, row.length));
  if (columnCount < 2) return const [];
  final names = [
    for (var column = 1; column < columnCount; column += 1)
      hasHeader && first.length > column && first[column].trim().isNotEmpty
          ? first[column].trim()
          : '通道 $column',
  ];
  final points = [for (var i = 0; i < names.length; i += 1) <AnalysisPoint>[]];
  for (final row in rows.skip(start)) {
    final x = double.tryParse(row.isEmpty ? '' : row.first.trim());
    if (x == null || !x.isFinite) continue;
    for (var column = 1; column < columnCount; column += 1) {
      if (row.length <= column) continue;
      final y = double.tryParse(row[column].trim());
      if (y != null && y.isFinite) {
        points[column - 1].add(AnalysisPoint(x, y));
      }
    }
  }
  return [
    for (var index = 0; index < points.length; index += 1)
      if (points[index].isNotEmpty)
        AnalysisSeries(
          name: names[index],
          color: colors[index % colors.length],
          points: List<AnalysisPoint>.unmodifiable(points[index]),
        ),
  ];
}

Future<List<AnalysisSeries>> parseAnalysisCsvInBackground(
  String contents, {
  required List<Color> colors,
}) {
  return compute(_parseAnalysisCsvPayload, (
    contents: contents,
    colors: [for (final color in colors) color.toARGB32()],
  ));
}

List<AnalysisSeries> _parseAnalysisCsvPayload(
  ({String contents, List<int> colors}) payload,
) {
  return parseAnalysisCsv(
    payload.contents,
    colors: [for (final value in payload.colors) Color(value)],
  );
}

List<String> parseAnalysisCsvLine(String line) {
  final values = <String>[];
  var buffer = StringBuffer();
  var quoted = false;
  for (var index = 0; index < line.length; index += 1) {
    final char = line[index];
    if (char == '"') {
      if (quoted && index + 1 < line.length && line[index + 1] == '"') {
        buffer.write('"');
        index += 1;
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

AnalysisStats? analysisStatsForRange(
  List<AnalysisPoint> points,
  double start,
  double end,
) {
  final first = lowerBoundAnalysisPoints(points, start);
  final afterLast = upperBoundAnalysisPoints(points, end);
  if (first >= afterLast) return null;
  var minimum = double.infinity;
  var maximum = -double.infinity;
  var sum = 0.0;
  for (var index = first; index < afterLast; index += 1) {
    final value = points[index].y;
    minimum = math.min(minimum, value);
    maximum = math.max(maximum, value);
    sum += value;
  }
  final count = afterLast - first;
  return AnalysisStats(
    count: count,
    minimum: minimum,
    maximum: maximum,
    average: sum / count,
  );
}

int lowerBoundAnalysisPoints(List<AnalysisPoint> points, double value) {
  var low = 0;
  var high = points.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (points[middle].x < value) {
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
    if (points[middle].x <= value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

List<Offset> downsampleAnalysisPoints(
  List<AnalysisPoint> points, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  if (points.isEmpty || xMax <= xMin) return const [];
  final first = lowerBoundAnalysisPoints(points, xMin);
  final afterLast = upperBoundAnalysisPoints(points, xMax);
  if (first >= afterLast) return const [];
  final bucketCount = math.max(1, pixelWidth.floor());
  final visibleCount = afterLast - first;
  if (visibleCount <= bucketCount * 2) {
    return [
      for (var index = first; index < afterLast; index += 1)
        Offset(points[index].x, points[index].y),
    ];
  }

  final result = <Offset>[];
  var currentBucket = -1;
  AnalysisPoint? minimum;
  AnalysisPoint? maximum;
  var minimumIndex = 0;
  var maximumIndex = 0;

  void append(AnalysisPoint point) {
    final offset = Offset(point.x, point.y);
    if (result.isEmpty || result.last != offset) result.add(offset);
  }

  void flushBucket() {
    final low = minimum;
    final high = maximum;
    if (low == null || high == null) return;
    if (minimumIndex <= maximumIndex) {
      append(low);
      append(high);
    } else {
      append(high);
      append(low);
    }
  }

  for (var index = first; index < afterLast; index += 1) {
    final point = points[index];
    final bucket = (((point.x - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flushBucket();
      currentBucket = bucket;
      minimum = point;
      maximum = point;
      minimumIndex = index;
      maximumIndex = index;
    } else {
      if (point.y < minimum!.y) {
        minimum = point;
        minimumIndex = index;
      }
      if (point.y > maximum!.y) {
        maximum = point;
        maximumIndex = index;
      }
    }
  }
  flushBucket();
  append(points[afterLast - 1]);
  return result;
}
