import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

// Shared disk format: backend/services/numeric_history.py. Level zero contains
// little-endian float64 (time, value). Each higher node covers 64 children and
// stores time bounds, then five (original index, time, value) triples.
const _group = 64;
const _nodeBytes = 17 * 8;
const _empty = _Point(-1, 0, double.nan);

class _Point {
  const _Point(this.index, this.time, this.value);
  final int index;
  final double time;
  final double value;
}

class _Summary {
  int count = 0;
  double start = double.infinity, end = double.negativeInfinity;
  _Point first = _empty,
      low = _empty,
      high = _empty,
      last = _empty,
      gap = _empty;

  void add(_Summary other) {
    if (count == 0) {
      first = other.first;
      low = other.low;
      high = other.high;
    }
    if (other.low.value.isFinite &&
        (!low.value.isFinite || other.low.value < low.value)) {
      low = other.low;
    }
    if (other.high.value.isFinite &&
        (!high.value.isFinite || other.high.value > high.value)) {
      high = other.high;
    }
    if (gap.index < 0 && other.gap.index >= 0) gap = other.gap;
    last = other.last;
    start = math.min(start, other.start);
    end = math.max(end, other.end);
    count++;
  }

  Uint8List encode() {
    final data = ByteData(_nodeBytes);
    data.setFloat64(0, start, Endian.little);
    data.setFloat64(8, end, Endian.little);
    var offset = 16;
    for (final point in [first, low, high, last, gap]) {
      data.setFloat64(offset, point.index.toDouble(), Endian.little);
      data.setFloat64(offset + 8, point.time, Endian.little);
      data.setFloat64(offset + 16, point.value, Endian.little);
      offset += 24;
    }
    return data.buffer.asUint8List();
  }
}

/// Writer for the simulated frontend; production writes the same format on its
/// existing ordered recording worker. Memory does not grow with session length.
class NumericHistoryWriter {
  NumericHistoryWriter(this.directory) {
    directory.createSync(recursive: true);
  }
  final Directory directory;
  final Map<int, _SeriesWriter> _series = {};
  int _channelCount = 0;

  void append(List<List<Object>> rows, List<Map<String, String>> channels) {
    final grouped = <int, List<(double, double)>>{};
    for (final row in rows) {
      for (var i = 1; i < row.length; i += 2) {
        final value = row[i + 1];
        (grouped[row[i] as int] ??= []).add((
          (row.first as num).toDouble(),
          value is num
              ? value.toDouble()
              : double.tryParse('$value') ?? double.nan,
        ));
      }
    }
    for (final entry in grouped.entries) {
      (_series[entry.key] ??= _SeriesWriter(
        '${directory.path}/${entry.key}',
      )).append(entry.value);
    }
    if (_channelCount != channels.length) {
      final temporary = File('${directory.path}/manifest.tmp');
      temporary.writeAsStringSync(
        jsonEncode({'version': 1, 'channels': channels}),
      );
      temporary.renameSync('${directory.path}/manifest.json');
      _channelCount = channels.length;
    }
  }

  void close() {
    for (final series in _series.values) {
      series.close();
    }
    _series.clear();
  }
}

class _SeriesWriter {
  _SeriesWriter(this.path)
    : raw = File('$path.samples').openSync(mode: FileMode.writeOnly);
  final String path;
  final RandomAccessFile raw;
  final List<RandomAccessFile> levels = [];
  final List<_Summary> pending = [];
  int count = 0;

  void append(List<(double, double)> points) {
    final data = ByteData(points.length * 16);
    final output = <int, BytesBuilder>{};
    void push(int level, _Summary summary) {
      if (pending.length <= level) {
        pending.add(_Summary());
        levels.add(
          File('$path.l${level + 1}').openSync(mode: FileMode.writeOnly),
        );
      }
      final parent = pending[level]..add(summary);
      if (parent.count == _group) {
        (output[level] ??= BytesBuilder(copy: false)).add(parent.encode());
        pending[level] = _Summary();
        push(level + 1, parent);
      }
    }

    var offset = 0;
    for (final (time, value) in points) {
      if (!time.isFinite) continue;
      data.setFloat64(offset, time, Endian.little);
      data.setFloat64(offset + 8, value, Endian.little);
      offset += 16;
      final point = _Point(count++, time, value);
      push(
        0,
        _Summary()
          ..start = time
          ..end = time
          ..first = point
          ..low = point
          ..high = point
          ..last = point
          ..gap = value.isFinite ? _empty : point,
      );
    }
    // Publish all completed summaries before exposing their raw prefix.
    for (final entry in output.entries) {
      levels[entry.key].writeFromSync(entry.value.takeBytes());
    }
    raw.writeFromSync(data.buffer.asUint8List(), 0, offset);
  }

  void close() {
    raw.closeSync();
    for (final level in levels) {
      level.closeSync();
    }
  }
}

class HistoryRequest {
  const HistoryRequest({
    required this.path,
    required this.keys,
    required this.start,
    required this.end,
    required this.sourceEnd,
    required this.buckets,
    this.maxPoints = 16384,
  });
  final String path;
  final List<String> keys;
  final double start, end, sourceEnd;
  final int buckets, maxPoints;
  double get resolution => (end - start) / math.max(1, buckets);
}

class HistoryWindow {
  HistoryWindow({
    required this.request,
    required this.series,
    required this.reduced,
    this.bytesRead = 0,
    this.rawPointsRead = 0,
    this.summaryNodesRead = 0,
  });
  final HistoryRequest request;
  final Map<String, Float64List> series;
  final bool reduced;
  final int bytesRead, rawPointsRead, summaryNodesRead;
}

typedef HistoryReader = Future<HistoryWindow> Function(HistoryRequest request);

Future<HistoryWindow> readNumericHistory(HistoryRequest request) =>
    Isolate.run(() => readNumericHistorySync(request));

/// Traverses a fixed raw prefix; skips unrelated subtrees and uses their exact
/// extrema at screen resolution. No journal scan or full-session allocation.
HistoryWindow readNumericHistorySync(HistoryRequest request) {
  final manifest =
      jsonDecode(File('${request.path}/manifest.json').readAsStringSync())
          as Map;
  if (manifest['version'] != 1) {
    throw const FormatException('Unsupported history format');
  }
  final channels = manifest['channels'] as List;
  final ids = {for (var i = 0; i < channels.length; i++) channels[i]['key']: i};
  final series = <String, Float64List>{};
  var bytesRead = 0, rawPointsRead = 0, summaryNodesRead = 0;
  var reduced = false;
  for (final key in request.keys) {
    final id = ids[key];
    if (id == null) {
      series[key] = Float64List(0);
      continue;
    }
    final path = '${request.path}/$id';
    final handles = <int, _HistoryFile>{};
    final collector = _Collector(request);
    _HistoryFile handle(int level) => handles.putIfAbsent(
      level,
      () => _HistoryFile(File(level == 0 ? '$path.samples' : '$path.l$level')),
    );
    ByteData read(int level, int first, int count) {
      final size = level == 0 ? 16 : _nodeBytes;
      return handle(level).read(first * size, count * size);
    }

    void walk(int level, int stride, int begin, int end) {
      if (begin >= end) return;
      if (level == 0) {
        final data = read(0, begin, end - begin);
        rawPointsRead += end - begin;
        for (var i = 0; i < end - begin; i++) {
          collector.add(
            _Point(
              begin + i,
              data.getFloat64(i * 16, Endian.little),
              data.getFloat64(i * 16 + 8, Endian.little),
            ),
          );
        }
        return;
      }
      final count = (end - begin) ~/ stride;
      if (count > 0) {
        final data = read(level, begin ~/ stride, count);
        summaryNodesRead += count;
        for (var i = 0; i < count; i++) {
          final offset = i * _nodeBytes;
          final startTime = data.getFloat64(offset, Endian.little);
          final endTime = data.getFloat64(offset + 8, Endian.little);
          if (endTime < request.start || startTime > request.end) continue;
          if (startTime >= request.start &&
              endTime <= request.end &&
              endTime - startTime <= request.resolution) {
            reduced = true;
            for (var p = 0; p < 5; p++) {
              final base = offset + 16 + p * 24;
              final index = data.getFloat64(base, Endian.little).toInt();
              if (index >= 0) {
                collector.add(
                  _Point(
                    index,
                    data.getFloat64(base + 8, Endian.little),
                    data.getFloat64(base + 16, Endian.little),
                  ),
                );
              }
            }
          } else {
            final first = begin + i * stride;
            walk(level - 1, stride ~/ _group, first, first + stride);
          }
        }
      }
      // Incomplete nodes are never published. Descend into the committed tail.
      walk(level - 1, stride ~/ _group, begin + count * stride, end);
    }

    try {
      final count = handle(0).length ~/ 16;
      var level = 0, stride = 1;
      while (stride * _group <= count) {
        level++;
        stride *= _group;
      }
      walk(level, stride, 0, count);
      series[key] = collector.finish();
      reduced = reduced || collector.reduced;
    } finally {
      for (final file in handles.values) {
        bytesRead += file.bytesRead;
        file.file.closeSync();
      }
    }
  }
  return HistoryWindow(
    request: request,
    series: series,
    reduced: reduced,
    bytesRead: bytesRead,
    rawPointsRead: rawPointsRead,
    summaryNodesRead: summaryNodesRead,
  );
}

/// Coalesce adjacent leaves into bounded reads. A pan over many dense channels
/// otherwise makes thousands of tiny seek/read calls despite the time index.
class _HistoryFile {
  _HistoryFile(File source) : file = source.openSync() {
    length = file.lengthSync();
  }
  static const _blockSize = 65536;
  final RandomAccessFile file;
  late final int length;
  int bytesRead = 0;
  int _start = -1;
  Uint8List _data = Uint8List(0);

  ByteData read(int offset, int count) {
    if (offset + count > length) {
      throw const FormatException(
        'History index ended before its committed prefix',
      );
    }
    void load(int position) {
      if (position >= _start && position < _start + _data.length) return;
      _start = position ~/ _blockSize * _blockSize;
      file.setPositionSync(_start);
      _data = file.readSync(math.min(_blockSize, length - _start));
      bytesRead += _data.length;
      if (position >= _start + _data.length) {
        throw const FormatException('History file was truncated during a read');
      }
    }

    load(offset);
    if (offset + count <= _start + _data.length) {
      return ByteData.sublistView(
        _data,
        offset - _start,
        offset - _start + count,
      );
    }
    final bytes = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      load(offset + copied);
      final relative = offset + copied - _start;
      final take = math.min(count - copied, _data.length - relative);
      bytes.setRange(copied, copied + take, _data, relative);
      copied += take;
    }
    return ByteData.sublistView(bytes);
  }
}

class _Collector {
  _Collector(this.request);
  final HistoryRequest request;
  Map<int, _Point>? exact = {};
  final Map<int, _Summary> buckets = {};
  bool get reduced => exact == null;

  void add(_Point point) {
    if (point.time < request.start ||
        point.time > request.end ||
        !point.time.isFinite) {
      return;
    }
    final points = exact;
    if (points != null) {
      points[point.index] = point;
      if (points.length <= request.maxPoints) return;
      exact = null;
      for (final item in points.values) {
        _addBucket(item);
      }
    } else {
      _addBucket(point);
    }
  }

  void _addBucket(_Point point) {
    final index = ((point.time - request.start) / request.resolution)
        .floor()
        .clamp(0, request.buckets - 1);
    final bucket = buckets[index] ??= _Summary();
    // Tree extrema may arrive out of order; endpoint selection uses raw indices.
    final first = bucket.count == 0 || point.index < bucket.first.index
        ? point
        : bucket.first;
    final last = bucket.count == 0 || point.index > bucket.last.index
        ? point
        : bucket.last;
    bucket.add(
      _Summary()
        ..start = point.time
        ..end = point.time
        ..first = point
        ..low = point
        ..high = point
        ..last = point
        ..gap = point.value.isFinite ? _empty : point,
    );
    bucket.first = first;
    bucket.last = last;
  }

  Float64List finish() {
    final points =
        exact ??
        {
          for (final bucket in buckets.values)
            for (final point in [
              bucket.first,
              bucket.low,
              bucket.high,
              bucket.last,
              bucket.gap,
            ])
              if (point.index >= 0) point.index: point,
        };
    final sorted = points.values.toList()
      ..sort((a, b) {
        final time = a.time.compareTo(b.time);
        return time == 0 ? a.index.compareTo(b.index) : time;
      });
    final result = Float64List(sorted.length * 2);
    for (var i = 0; i < sorted.length; i++) {
      result[i * 2] = sorted[i].time;
      result[i * 2 + 1] = sorted[i].value;
    }
    return result;
  }
}
