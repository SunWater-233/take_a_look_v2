import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Numeric ring history. Frozen snapshots share pages until a later write.
/// Extrema summaries retain original order, precision, and earliest equal hits.
class SampleBuffer extends IterableBase<Offset> {
  SampleBuffer({int capacity = defaultCapacity})
    : _capacity = capacity,
      _readOnly = false,
      _pages = List<_SamplePage?>.filled(
        capacity > 0 ? (capacity + _pageSize - 1) ~/ _pageSize : 0,
        null,
      ) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }
  SampleBuffer._snapshot(SampleBuffer source)
    : _capacity = source._capacity,
      _pages = List.of(source._pages),
      _start = source._start,
      _length = source._length,
      _revision = source._revision,
      _ordered = source._ordered,
      _finite = source._finite,
      _latestTime = source._latestTime,
      _lastTime = source._lastTime,
      _readOnly = true {
    for (final page in _pages) {
      if (page != null) page.shared = true;
    }
  }

  static const defaultCapacity = 1800;
  static const _pageSize = 256;
  int _capacity;
  List<_SamplePage?> _pages;
  int get capacity => _capacity;
  int get revision => _revision;
  bool get isOrdered => _ordered;
  double? _retentionSeconds;
  double _latestTime = double.negativeInfinity;
  double _lastTime = double.negativeInfinity;
  double? _configuredRate;
  bool _ordered = true;
  bool _finite = true;
  int _start = 0;
  int _length = 0;
  int _revision = 0;
  final bool _readOnly;
  ({int revision, double start, double end, (double, double)? bounds})? _bounds;

  /// O(number of pages), without copying points or sharing mutable values.
  SampleBuffer snapshot() => _readOnly ? this : SampleBuffer._snapshot(this);
  void _requireMutable() {
    if (_readOnly) throw UnsupportedError('A frozen history is read-only.');
  }

  void configureRetention({required double seconds, required double rateHz}) {
    _requireMutable();
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
    final oldPages = _pages;
    final oldCapacity = capacity;
    final oldStart = _start;
    _capacity = size;
    _pages = List.filled((size + _pageSize - 1) ~/ _pageSize, null);
    _start = 0;
    for (var i = 0; i < _length; i++) {
      final sum = oldStart + i;
      final physical = sum < oldCapacity ? sum : sum - oldCapacity;
      final page = oldPages[physical ~/ _pageSize]!;
      final offset = physical % _pageSize;
      _write(i, page.times[offset], page.values[offset]);
    }
    _revision++;
  }

  void _expirePrefix() {
    final retention = _retentionSeconds;
    if (retention == null) return;
    final cutoff = _latestTime - retention - 1e-9;
    // Cursors still describe a contiguous tail for overlapping streams.
    while (_length > 0 && _time(_start) < cutoff) {
      _start++;
      if (_start == capacity) _start = 0;
      _length--;
      _revision++;
    }
  }

  (int, int) rangeIndices(double minimumTime, double maximumTime) {
    if (!_ordered) return (0, _length);
    return (lowerBound(minimumTime), lowerBound(maximumTime, afterEqual: true));
  }

  int lowerBound(double time, {bool afterEqual = false}) {
    var low = 0;
    var high = _length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      final value = timeAt(middle);
      if (value < time || (afterEqual && value == time)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  @override
  int get length => _length;
  @override
  bool get isEmpty => _length == 0;
  @override
  bool get isNotEmpty => _length != 0;
  int _physicalIndex(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _position(index);
  }

  int _position(int index) {
    final position = _start + index;
    return position < capacity ? position : position - capacity;
  }

  double _time(int physical) =>
      _pages[physical ~/ _pageSize]!.times[physical % _pageSize];
  double _value(int physical) =>
      _pages[physical ~/ _pageSize]!.values[physical % _pageSize];
  double timeAt(int index) => _time(_physicalIndex(index));
  double valueAt(int index) => _value(_physicalIndex(index));
  Offset operator [](int index) {
    final physical = _physicalIndex(index);
    return Offset(_time(physical), _value(physical));
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

  void _write(int physical, double time, double value) {
    final pageIndex = physical ~/ _pageSize;
    var page = _pages[pageIndex];
    if (page == null) {
      page = _SamplePage();
      _pages[pageIndex] = page;
    } else if (page.shared) {
      page = page.copy();
      _pages[pageIndex] = page;
    }
    final offset = physical % _pageSize;
    page.times[offset] = time;
    page.values[offset] = value;
    page.invalidate(offset);
  }

  void add(Offset point) => addXY(point.dx, point.dy);
  void addXY(double time, double value) {
    _requireMutable();
    if (_ordered && (!time.isFinite || (_length > 0 && time < _lastTime))) {
      _ordered = false;
    }
    _lastTime = time;
    if (!value.isFinite) _finite = false;
    _latestTime = math.max(_latestTime, time);
    _expirePrefix();
    if (_retentionSeconds != null && _length == capacity) _resize(capacity * 2);
    _write(_position(_length), time, value);
    if (_length == capacity) {
      _start++;
      if (_start == capacity) _start = 0;
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
    _requireMutable();
    _start = 0;
    _length = 0;
    _latestTime = double.negativeInfinity;
    _lastTime = double.negativeInfinity;
    _ordered = _finite = true;
    if (_retentionSeconds != null) {
      _capacity = (_retentionSeconds! * _configuredRate!).ceil() + 1;
    }
    _pages = List.filled((capacity + _pageSize - 1) ~/ _pageSize, null);
    _revision++;
  }

  /// Earliest indices of the exact minimum and maximum in [start, end).
  (int, int) extremaIndices(int start, int end) {
    RangeError.checkValidRange(start, end, _length);
    if (start == end) throw StateError('An empty range has no extrema.');
    var minimumIndex = start;
    var maximumIndex = start;
    var minimum = valueAt(start);
    var maximum = minimum;
    if (!_finite) {
      for (var i = start + 1; i < end; i++) {
        final value = valueAt(i);
        if (value < minimum) {
          minimum = value;
          minimumIndex = i;
        }
        if (value > maximum) {
          maximum = value;
          maximumIndex = i;
        }
      }
      return (minimumIndex, maximumIndex);
    }
    var index = start;
    while (index < end) {
      final physical = _position(index);
      final offset = physical % _pageSize;
      final count = math.min(
        end - index,
        math.min(_pageSize - offset, capacity - physical),
      );
      final page = _pages[physical ~/ _pageSize]!;
      final (low, high) = page.extrema(offset, offset + count);
      final lowValue = page.values[low];
      final highValue = page.values[high];
      if (lowValue < minimum) {
        minimum = lowValue;
        minimumIndex = index + low - offset;
      }
      if (highValue > maximum) {
        maximum = highValue;
        maximumIndex = index + high - offset;
      }
      index += count;
    }
    return (minimumIndex, maximumIndex);
  }

  (double, double)? valueBounds(double minimumTime, double maximumTime) {
    final cached = _bounds;
    if (cached != null &&
        cached.revision == _revision &&
        cached.start == minimumTime &&
        cached.end == maximumTime) {
      return cached.bounds;
    }
    final bounds = _computeValueBounds(minimumTime, maximumTime);
    _bounds = (
      revision: _revision,
      start: minimumTime,
      end: maximumTime,
      bounds: bounds,
    );
    return bounds;
  }

  (double, double)? _computeValueBounds(
    double minimumTime,
    double maximumTime,
  ) {
    final (start, end) = rangeIndices(minimumTime, maximumTime);
    if (start >= end) return null;
    if (_ordered && _finite) {
      final (low, high) = extremaIndices(start, end);
      return (valueAt(low), valueAt(high));
    }
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (var i = start; i < end; i++) {
      final time = timeAt(i);
      if (time < minimumTime || time > maximumTime) continue;
      low = math.min(low, valueAt(i));
      high = math.max(high, valueAt(i));
    }
    return low <= high ? (low, high) : null;
  }

  /// Exact low-density reduction, reading each page sequentially.
  List<Offset> reduceTimeBuckets(
    int start,
    int end,
    double minimumTime,
    double maximumTime,
    int buckets,
  ) {
    RangeError.checkValidRange(start, end, _length);
    if (start == end) return const [];
    final result = <Offset>[];
    void append(int index) {
      final point = this[index];
      if (result.isEmpty || result.last != point) result.add(point);
    }

    var bucket = -1, minimumIndex = start, maximumIndex = start;
    void flush() {
      if (bucket < 0) return;
      append(math.min(minimumIndex, maximumIndex));
      append(math.max(minimumIndex, maximumIndex));
    }

    var minimum = double.infinity, maximum = double.negativeInfinity;
    final span = maximumTime - minimumTime;
    append(start);
    var index = start;
    while (index < end) {
      final physical = _position(index);
      final offset = physical % _pageSize;
      final count = math.min(
        end - index,
        math.min(_pageSize - offset, capacity - physical),
      );
      final page = _pages[physical ~/ _pageSize]!;
      final times = page.times, values = page.values;
      for (var i = 0; i < count; i++) {
        final nextBucket =
            (((times[offset + i] - minimumTime) / span) * buckets)
                .floor()
                .clamp(0, buckets - 1);
        final value = values[offset + i];
        if (nextBucket != bucket) {
          flush();
          bucket = nextBucket;
          minimum = maximum = value;
          minimumIndex = maximumIndex = index + i;
        } else {
          if (value < minimum) {
            minimum = value;
            minimumIndex = index + i;
          }
          if (value > maximum) {
            maximum = value;
            maximumIndex = index + i;
          }
        }
      }
      index += count;
    }
    flush();
    append(end - 1);
    return result;
  }

  /// Wire snapshots retain Float64 precision without per-point objects.
  Float64List packedRange([int start = 0, int? end]) {
    final limit = RangeError.checkValidRange(start, end, _length);
    final result = Float64List((limit - start) * 2);
    for (var i = start; i < limit; i++) {
      final physical = _position(i);
      result[(i - start) * 2] = _time(physical);
      result[(i - start) * 2 + 1] = _value(physical);
    }
    return result;
  }

  @override
  Iterator<Offset> get iterator => _SampleIterator(this, 0);
  @override
  Iterable<Offset> skip(int count) {
    if (count < 0) throw RangeError.range(count, 0, null, 'count');
    return _SampleTail(this, count);
  }
}

class _SamplePage {
  static const size = SampleBuffer._pageSize;
  static const blockSize = 16;
  static const blocks = size ~/ blockSize;
  final Float64List times = Float64List(size);
  final Float64List values = Float64List(size);
  final Uint16List _minima = Uint16List(blocks * 2);
  final Uint16List _maxima = Uint16List(blocks * 2);
  int _dirty = (1 << blocks) - 1;
  bool shared = false;

  _SamplePage copy() => _SamplePage()
    ..times.setAll(0, times)
    ..values.setAll(0, values)
    .._minima.setAll(0, _minima)
    .._maxima.setAll(0, _maxima)
    .._dirty = _dirty;

  void invalidate(int offset) => _dirty |= 1 << (offset ~/ blockSize);

  int _lower(int left, int right) =>
      values[left] < values[right] ||
          values[left] == values[right] && left < right
      ? left
      : right;
  int _higher(int left, int right) =>
      values[left] > values[right] ||
          values[left] == values[right] && left < right
      ? left
      : right;

  (int, int) _scan(int start, int end) {
    var low = start, high = start;
    for (var i = start + 1; i < end; i++) {
      if (values[i] < values[low]) low = i;
      if (values[i] > values[high]) high = i;
    }
    return (low, high);
  }

  void _refresh() {
    if (_dirty == 0) return;
    for (var block = 0; block < blocks; block++) {
      if (_dirty & (1 << block) == 0) continue;
      final (low, high) = _scan(block * blockSize, (block + 1) * blockSize);
      _minima[blocks + block] = low;
      _maxima[blocks + block] = high;
    }
    for (var node = blocks - 1; node > 0; node--) {
      _minima[node] = _lower(_minima[node * 2], _minima[node * 2 + 1]);
      _maxima[node] = _higher(_maxima[node * 2], _maxima[node * 2 + 1]);
    }
    _dirty = 0;
  }

  (int, int) extrema(int start, int end) {
    if (start == 0 && end == size) {
      _refresh();
      return (_minima[1], _maxima[1]);
    }
    var low = start, high = start, index = start;
    if (index % blockSize != 0) {
      final after = math.min(end, (index ~/ blockSize + 1) * blockSize);
      (low, high) = _scan(index, after);
      index = after;
    }
    final fullEnd = end ~/ blockSize * blockSize;
    if (index < fullEnd) {
      _refresh();
      var left = blocks + index ~/ blockSize;
      var right = blocks + fullEnd ~/ blockSize;
      while (left < right) {
        if (left.isOdd) {
          low = _lower(low, _minima[left]);
          high = _higher(high, _maxima[left]);
          left++;
        }
        if (right.isOdd) {
          right--;
          low = _lower(low, _minima[right]);
          high = _higher(high, _maxima[right]);
        }
        left >>= 1;
        right >>= 1;
      }
      index = fullEnd;
    }
    if (index < end) {
      final (a, b) = _scan(index, end);
      low = _lower(low, a);
      high = _higher(high, b);
    }
    return (low, high);
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
    if (revision != buffer._revision) throw ConcurrentModificationError(buffer);
    if (index >= buffer.length) {
      _current = null;
      return false;
    }
    _current = buffer[index++];
    return true;
  }
}
