import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'numeric_history.dart';
import 'sample_buffer.dart';

/// A bounded viewport cache with one worker request and one replaceable pending
/// request. Throttling (not trailing debounce) keeps history moving during drag.
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
  double _visibleStart = 0, _visibleEnd = 0;
  int _generation = 0;
  bool _disposed = false;
  String? error;
  DateTime? _retryAt;

  bool get loading => _wanted != null && (_timer != null || _active != null);
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
    if (!enabled || path == null || keys.isEmpty) {
      error = null;
      _wanted = null;
      _timer?.cancel();
      _timer = null;
      return;
    }
    _visibleStart = start;
    _visibleEnd = math.min(end, sourceEnd);
    final span = math.max(0.2, end - start);
    final left = math.max(0.0, start - span * 0.5);
    final right = end + span * 0.5;
    final maxPoints = (131072 ~/ keys.length).clamp(512, 16384);
    _wanted = HistoryRequest(
      path: path,
      keys: _keys,
      start: left,
      end: right,
      sourceEnd: sourceEnd,
      buckets: ((right - left) / span * pixelWidth).ceil().clamp(
        1,
        maxPoints ~/ 5,
      ),
      maxPoints: maxPoints,
    );
    if (_satisfied) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _schedule();
  }

  bool _covers(HistoryRequest request, {required bool reduced}) =>
      request.start <= _visibleStart + 1e-9 &&
      math.min(request.end, request.sourceEnd) >= _visibleEnd - 1e-9 &&
      (!reduced || request.resolution <= _wanted!.resolution * 1.5);

  bool get _satisfied =>
      _wanted == null ||
      _cache.any(
        (item) => _covers(item.window.request, reduced: item.window.reduced),
      );

  void _schedule() {
    if (_disposed || _satisfied || _timer != null || _active != null) return;
    if (_retryAt != null && DateTime.now().isBefore(_retryAt!)) return;
    _timer = Timer(const Duration(milliseconds: 60), () {
      _timer = null;
      if (!_disposed && !_satisfied) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final request = _wanted!;
    final generation = _generation;
    _active = request;
    try {
      final window = await _reader(request);
      if (_disposed || generation != _generation || _wanted == null) return;
      // Never replace the visible data with a result for an obsolete viewport.
      // Retain it as one of two neighbouring windows for quick backtracking.
      _cache.insert(0, _CachedWindow(window));
      if (_cache.length > 2) _cache.removeLast();
      error = null;
      _retryAt = null;
    } catch (failure) {
      if (!_disposed && generation == _generation && _wanted != null) {
        error = '历史数据读取失败：$failure';
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
    for (final item in _cache) {
      if (_covers(item.window.request, reduced: item.window.reduced)) {
        return item.samplesFor(key, minimumTime);
      }
    }
    // Keep the overlapping curve visible while its neighbouring range loads.
    for (final item in _cache) {
      if (item.window.request.start <= _visibleEnd &&
          item.window.request.end >= _visibleStart) {
        return item.samplesFor(key, minimumTime);
      }
    }
    return null;
  }

  bool get hasVisibleWindow => _wanted != null && _satisfied;

  void clear() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _wanted = null;
    _cache.clear();
    error = null;
    _retryAt = null;
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
