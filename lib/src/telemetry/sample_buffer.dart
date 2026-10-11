import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Bounded time/value history. Samples are stored as numbers; Offset objects
/// are created only when a UI or serialization consumer reads them.
class SampleBuffer extends IterableBase<Offset> {
  SampleBuffer({int capacity = defaultCapacity})
    : _times = Float64List(capacity),
      _values = Float64List(capacity) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  static const defaultCapacity = 1800;
  int get capacity => _times.length;
  Float64List _times;
  Float64List _values;
  double? _retentionSeconds;
  double _latestTime = double.negativeInfinity;
  double? _configuredRate;
  bool _ordered = true;
  int _start = 0;
  int _length = 0;
  int _revision = 0;

  /// Reserve a time window at the configured rate. A rate decrease must not
  /// discard the denser history that is still inside that window.
  void configureRetention({required double seconds, required double rateHz}) {
    if (!seconds.isFinite || seconds <= 0 || !rateHz.isFinite || rateHz <= 0) {
      throw ArgumentError(
        'Retention and sample rate must be finite and positive.',
      );
    }
    if (_retentionSeconds == seconds && _configuredRate == rateHz) return;
    _retentionSeconds = seconds;
    _configuredRate = rateHz;
    _expirePrefix();
    _resize(math.max((seconds * rateHz).ceil() + 1, _length));
  }

  void _resize(int size) {
    if (size == capacity) return;
    final times = Float64List(size);
    final values = Float64List(size);
    for (var i = 0; i < _length; i++) {
      final physical = (_start + i) % capacity;
      times[i] = _times[physical];
      values[i] = _values[physical];
    }
    _times = times;
    _values = values;
    _start = 0;
    _revision++;
  }

  void _expirePrefix() {
    final retention = _retentionSeconds;
    if (retention == null) return;
    final cutoff = _latestTime - retention - 1e-9;
    // Only remove a prefix: detached-window cursors describe a contiguous tail
    // even when memory and RTT batches have overlapping timestamps.
    while (_length > 0 && _times[_start] < cutoff) {
      _start = (_start + 1) % capacity;
      _length--;
      _revision++;
    }
  }

  /// Sorted streams can jump straight to the visible window. Mixed/overlapping
  /// streams use a full scan; callers still check timestamps in either case.
  (int, int) rangeIndices(double minimumTime, double maximumTime) {
    if (!_ordered) return (0, _length);
    int bound(double time, bool inclusive) {
      var low = 0;
      var high = _length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        final value = timeAt(middle);
        if (value < time || (inclusive && value == time)) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      return low;
    }

    return (bound(minimumTime, false), bound(maximumTime, true));
  }

  @override
  int get length => _length;
  @override
  bool get isEmpty => _length == 0;
  @override
  bool get isNotEmpty => _length != 0;

  int _physicalIndex(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return (_start + index) % capacity;
  }

  double timeAt(int index) => _times[_physicalIndex(index)];
  double valueAt(int index) => _values[_physicalIndex(index)];
  Offset operator [](int index) {
    final physical = _physicalIndex(index);
    return Offset(_times[physical], _values[physical]);
  }

  @override
  Offset get first {
    if (isEmpty) throw StateError('No elements');
    return this[0];
  }

  @override
  Offset get last {
    if (isEmpty) throw StateError('No elements');
    return this[_length - 1];
  }

  void add(Offset point) => addXY(point.dx, point.dy);

  void addXY(double time, double value) {
    if (_length > 0 && time < timeAt(_length - 1)) _ordered = false;
    _latestTime = math.max(_latestTime, time);
    _expirePrefix();
    // RTT's actual rate may exceed the requested polling rate. Grow instead
    // of silently shortening the promised history window.
    if (_retentionSeconds != null && _length == capacity) {
      _resize(capacity * 2);
    }
    final position = (_start + _length) % capacity;
    _times[position] = time;
    _values[position] = value;
    if (_length == capacity) {
      _start = (_start + 1) % capacity;
    } else {
      _length++;
    }
    _revision++;
  }

  void addAll(Iterable<Offset> points) {
    final source = identical(points, this) ? points.toList() : points;
    for (final point in source) {
      addXY(point.dx, point.dy);
    }
  }

  void clear() {
    _start = 0;
    _length = 0;
    _latestTime = double.negativeInfinity;
    _ordered = true;
    if (_retentionSeconds != null) {
      _resize((_retentionSeconds! * _configuredRate!).ceil() + 1);
    }
    _revision++;
  }

  /// Scan without allocating an Offset for every input point. No sorted-time
  /// assumption is made: memory and RTT samples can arrive in separate batches.
  (double, double)? valueBounds(double minimumTime, double maximumTime) {
    var low = double.infinity;
    var high = double.negativeInfinity;
    final (start, end) = rangeIndices(minimumTime, maximumTime);
    for (var index = start; index < end; index++) {
      final position = (_start + index) % capacity;
      final time = _times[position];
      if (time < minimumTime || time > maximumTime) continue;
      low = math.min(low, _values[position]);
      high = math.max(high, _values[position]);
    }
    return low <= high ? (low, high) : null;
  }

  @override
  Iterator<Offset> get iterator => _SampleIterator(this, 0);

  @override
  Iterable<Offset> skip(int count) {
    if (count < 0) throw RangeError.range(count, 0, null, 'count');
    return _SampleTail(this, count);
  }
}

class _SampleTail extends IterableBase<Offset> {
  _SampleTail(this.buffer, this.start);
  final SampleBuffer buffer;
  final int start;
  @override
  Iterator<Offset> get iterator => _SampleIterator(buffer, start);
}

class _SampleIterator implements Iterator<Offset> {
  _SampleIterator(this.buffer, this.index) : revision = buffer._revision;
  final SampleBuffer buffer;
  final int revision;
  int index;
  Offset? _current;
  @override
  Offset get current => _current!;
  @override
  bool moveNext() {
    if (revision != buffer._revision) {
      throw ConcurrentModificationError(buffer);
    }
    if (index >= buffer.length) {
      _current = null;
      return false;
    }
    _current = buffer[index++];
    return true;
  }
}
