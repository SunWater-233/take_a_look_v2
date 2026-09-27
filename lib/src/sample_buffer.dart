import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Bounded time/value history. Samples are stored as numbers; Offset objects
/// are created only when a UI or serialization consumer reads them.
class SampleBuffer extends IterableBase<Offset> {
  SampleBuffer({this.capacity = defaultCapacity})
    : _times = Float64List(capacity),
      _values = Float64List(capacity) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  static const defaultCapacity = 1800;
  final int capacity;
  final Float64List _times;
  final Float64List _values;
  int _start = 0;
  int _length = 0;
  int _revision = 0;

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
    _revision++;
  }

  /// Scan without allocating an Offset for every input point. No sorted-time
  /// assumption is made: memory and RTT samples can arrive in separate batches.
  (double, double)? valueBounds(double minimumTime, double maximumTime) {
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (var index = 0; index < _length; index++) {
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
