import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'numeric_history.dart';
import 'sample_buffer.dart';

/// Shared disk-read cache. Each view still owns its visible range and resolution.
class PlotHistoryCache {
  PlotHistoryCache(HistoryReader? reader)
    : _reader = reader ?? readNumericHistory;

  final HistoryReader _reader;
  final _windows = <HistoryWindow>[];
  final _pending = <HistoryRequest, Future<HistoryWindow>>{};
  int _generation = 0;

  Future<HistoryWindow> read(HistoryRequest request) async {
    bool fits(HistoryRequest previous) =>
        previous.path == request.path &&
        listEquals(previous.keys, request.keys) &&
        previous.start <= request.start &&
        previous.coveredEnd >= request.coveredEnd &&
        previous.sourceEnd <= request.sourceEnd;

    for (final window in _windows) {
      if (fits(window.request) &&
          (!window.reduced ||
              window.request.resolution <= request.resolution)) {
        return window;
      }
    }
    for (final entry in _pending.entries) {
      if (fits(entry.key) &&
          entry.key.resolution <= request.resolution &&
          entry.key.maxPoints >= request.maxPoints) {
        return entry.value;
      }
    }
    final generation = _generation;
    final pending = _reader(request);
    _pending[request] = pending;
    try {
      final window = await pending;
      if (generation == _generation) {
        _windows.insert(0, window);
        if (_windows.length > 2) _windows.removeLast();
      }
      return window;
    } finally {
      if (identical(_pending[request], pending)) _pending.remove(request);
    }
  }

  void clear() {
    _generation++;
    _windows.clear();
    _pending.clear();
  }
}

/// Groups recording paths and resolves each channel's history for a viewport.
class PlotHistoryQuery {
  PlotHistoryQuery({required this.onChanged, required this.reader}) {
    live = PlotHistory(onChanged: onChanged, reader: reader);
  }

  final VoidCallback onChanged;
  final HistoryReader reader;
  late final PlotHistory live;
  final _archived = <String, PlotHistory>{};
  String? _livePath;

  void update({
    required String? livePath,
    required List<WatchItem> watches,
    required double start,
    required double end,
    required double liveEnd,
    required double pixelWidth,
    required bool enabled,
    required bool liveEnabled,
  }) {
    _livePath = livePath;
    final archived = <String, List<WatchItem>>{};
    final liveKeys = <String>[];
    for (final watch in watches) {
      final path = watch.archivedHistoryPath;
      if (path != null && path != livePath) {
        (archived[path] ??= []).add(watch);
      } else {
        liveKeys.add(watch.symbol.key);
      }
    }
    live.update(
      path: livePath,
      keys: liveKeys,
      start: start,
      end: end,
      sourceEnd: liveEnd,
      pixelWidth: pixelWidth,
      enabled: enabled && liveEnabled,
    );
    _archived.removeWhere((path, history) {
      if (archived.containsKey(path)) return false;
      history.dispose();
      return true;
    });
    for (final entry in archived.entries) {
      final history = _archived.putIfAbsent(
        entry.key,
        () => PlotHistory(onChanged: onChanged, reader: reader),
      );
      history.update(
        path: entry.key,
        keys: [for (final watch in entry.value) watch.symbol.key],
        start: start,
        end: end,
        sourceEnd: entry.value.fold<double>(
          0,
          (end, watch) => math.max(end, watch.archivedHistoryEndSeconds),
        ),
        pixelWidth: pixelWidth,
        enabled: enabled,
      );
    }
  }

  SampleBuffer? samplesFor(WatchItem watch) {
    final path = watch.archivedHistoryPath;
    final source = path == _livePath ? live : _archived[path] ?? live;
    return source.samplesFor(
      watch.symbol.key,
      minimumTime: watch.historyStartSeconds,
    );
  }

  void clear({bool preserveArchived = false}) {
    live.clear();
    if (preserveArchived) return;
    for (final history in _archived.values) {
      history.dispose();
    }
    _archived.clear();
  }

  void dispose() {
    clear();
    live.dispose();
  }
}

/// Aligned, overlapping time windows let panning reuse samples across frames.
/// One background read can run at a time, with visible data taking priority.
class PlotHistory {
  PlotHistory({required this.onChanged, HistoryReader? reader})
    : _reader = reader ?? readNumericHistory;
  final VoidCallback onChanged;
  final HistoryReader _reader;
  final List<_CachedWindow> _cache = [];
  Timer? _timer;
  HistoryRequest? _wanted;
  HistoryRequest? _active;
  String? _path;
  List<String> _keys = const [];
  double _visibleStart = 0, _visibleEnd = 0, _viewportEnd = 0;
  double _blockSeconds = 0;
  int _direction = 0;
  int _generation = 0;
  bool _disposed = false;
  String? error;
  DateTime? _retryAt;
  bool _prefetchRetry = false;
  static const _blocksPerWindow = 6;

  bool get loading =>
      _wanted != null &&
      !hasVisibleWindow &&
      (_timer != null || _active != null);
  int get retainedPoints =>
      _cache.fold(0, (sum, item) => sum + item.pointCount);

  void update({
    required String? path,
    required List<String> keys,
    required double start,
    required double end,
    required double sourceEnd,
    required double pixelWidth,
    required bool enabled,
  }) {
    if (_disposed) return;
    if (_path != path || !listEquals(_keys, keys)) {
      clear();
      _path = path;
      _keys = List.of(keys);
    }
    if (!enabled ||
        path == null ||
        keys.isEmpty ||
        start > sourceEnd ||
        end < 0) {
      error = null;
      _wanted = null;
      _direction = 0;
      _timer?.cancel();
      _timer = null;
      return;
    }
    final span = math.max(0.2, end - start);
    final shift = start - _visibleStart;
    if (_wanted == null || (shift - (end - _viewportEnd)).abs() > span * 1e-6) {
      _direction = 0;
    } else if (shift.abs() > span * 1e-6) {
      _direction = shift.isNegative ? -1 : 1;
    }
    _visibleStart = math.max(0, start);
    _visibleEnd = math.min(end, sourceEnd);
    _viewportEnd = end;
    _blockSeconds = math
        .pow(2, (math.log(span / 2) / math.ln2).floor())
        .toDouble();
    final maxPoints = (131072 ~/ keys.length).clamp(512, 16384);
    // Keep bucket boundaries aligned across adjacent windows at the same zoom.
    final bucketsPerBlock = (_blockSeconds / span * pixelWidth).ceil().clamp(
      1,
      maxPoints ~/ (5 * _blocksPerWindow),
    );
    _wanted = _windowAt(
      _visibleStart,
      path: path,
      sourceEnd: sourceEnd,
      buckets: bucketsPerBlock * _blocksPerWindow,
      maxPoints: maxPoints,
    );
    _schedule();
  }

  HistoryRequest _windowAt(
    double start, {
    required String path,
    required double sourceEnd,
    required int buckets,
    required int maxPoints,
  }) {
    final anchor = (start / _blockSeconds).floor() * _blockSeconds;
    final left = math.max(0.0, anchor - _blockSeconds);
    // Six blocks cover the viewport, including one block before its anchor.
    return HistoryRequest(
      path: path,
      keys: _keys,
      start: left,
      end: left + _blocksPerWindow * _blockSeconds,
      sourceEnd: sourceEnd,
      buckets: buckets,
      maxPoints: maxPoints,
    );
  }

  _CachedWindow? _covering(double start, double end) {
    final resolution = _wanted!.resolution * 1.5;
    for (final item in _cache) {
      final window = item.window;
      if (window.request.start <= start + 1e-9 &&
          item.end >= end - 1e-9 &&
          (!window.reduced || window.request.resolution <= resolution)) {
        return item;
      }
    }
    return null;
  }

  HistoryRequest? _nextRequest() {
    final wanted = _wanted;
    if (wanted == null) return null;
    if (!hasVisibleWindow) return wanted;
    if (_direction == 0) return null;
    final shift = _direction * _blockSeconds;
    final start = math.max(0.0, _visibleStart + shift);
    final end = math.min(wanted.sourceEnd, _viewportEnd + shift);
    if (start >= end || _covering(start, end) != null) return null;
    return _windowAt(
      start,
      path: wanted.path,
      sourceEnd: wanted.sourceEnd,
      buckets: wanted.buckets,
      maxPoints: wanted.maxPoints,
    );
  }

  void _schedule() {
    if (_disposed || _timer != null || _active != null) return;
    if (_retryAt != null &&
        DateTime.now().isBefore(_retryAt!) &&
        (!_prefetchRetry || hasVisibleWindow)) {
      return;
    }
    if (_nextRequest() == null) return;
    _timer = Timer(Duration.zero, () {
      _timer = null;
      final request = _nextRequest();
      if (request != null) unawaited(_load(request));
    });
  }

  Future<void> _load(HistoryRequest request) async {
    final generation = _generation;
    _active = request;
    try {
      final window = await _reader(request);
      if (_disposed || generation != _generation || _wanted == null) return;
      // Keep neighbouring windows available for a quick reversal.
      _cache.insert(0, _CachedWindow(window));
      if (_cache.length > 3) _cache.removeLast();
      error = null;
      _retryAt = null;
    } catch (failure) {
      if (!_disposed && generation == _generation && _wanted != null) {
        _prefetchRetry = hasVisibleWindow;
        if (!_prefetchRetry) error = '历史数据读取失败：$failure';
        _retryAt = DateTime.now().add(const Duration(seconds: 2));
      }
    } finally {
      _active = null;
      if (!_disposed) {
        _schedule();
        onChanged();
      }
    }
  }

  SampleBuffer? samplesFor(String key, {double minimumTime = 0}) {
    if (_wanted == null) return null;
    final covering = _covering(_visibleStart, _visibleEnd);
    if (covering != null) return covering.samplesFor(key, minimumTime);
    // Use the largest overlap while a visible window is loading.
    _CachedWindow? best;
    var overlap = -1.0;
    for (final item in _cache) {
      final length =
          math.min(item.end, _visibleEnd) -
          math.max(item.window.request.start, _visibleStart);
      if (length >= 0 && length > overlap) {
        best = item;
        overlap = length;
      }
    }
    return best?.samplesFor(key, minimumTime);
  }

  bool get hasVisibleWindow =>
      _wanted != null && _covering(_visibleStart, _visibleEnd) != null;

  void clear() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _wanted = null;
    _direction = 0;
    _cache.clear();
    error = null;
    _retryAt = null;
    _prefetchRetry = false;
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class _CachedWindow {
  _CachedWindow(this.window) {
    for (final entry in window.series.entries) {
      final data = entry.value;
      final buffer = SampleBuffer(capacity: math.max(1, data.length ~/ 2));
      for (var i = 0; i < data.length; i += 2) {
        buffer.addXY(data[i], data[i + 1]);
      }
      samples[entry.key] = buffer.snapshot();
      pointCount += buffer.length;
    }
  }
  final HistoryWindow window;
  double get end => window.request.coveredEnd;
  final Map<String, SampleBuffer> samples = {};
  final Map<String, ({double minimum, SampleBuffer buffer})> _trimmed = {};
  int pointCount = 0;

  SampleBuffer? samplesFor(String key, double minimumTime) {
    final source = samples[key];
    if (source == null || source.isEmpty || source.first.dx >= minimumTime) {
      return source;
    }
    final cached = _trimmed[key];
    if (cached?.minimum == minimumTime) return cached!.buffer;
    // A variable re-added after permanent deletion starts a new history.
    // Cache the clipped numeric buffer to retain the chart's fast path.
    final index = source.lowerBound(minimumTime);
    final trimmed = SampleBuffer(capacity: math.max(1, source.length - index));
    for (final point in source.skip(index)) {
      trimmed.add(point);
    }
    final buffer = trimmed.snapshot();
    pointCount += buffer.length - (cached?.buffer.length ?? 0);
    _trimmed[key] = (minimum: minimumTime, buffer: buffer);
    return buffer;
  }
}
