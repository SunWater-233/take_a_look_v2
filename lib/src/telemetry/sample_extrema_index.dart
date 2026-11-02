part of 'sample_buffer.dart';

/// Range tree over physical pages. Writes dirty a page once; queries refresh
/// only those leaves. Snapshots own their tree and share immutable sample pages.
class _PageExtremaIndex {
  _PageExtremaIndex(this._pages) {
    var base = 1;
    while (base < _pages.length) {
      base *= 2;
    }
    _base = base;
    _minima = Int32List(_base * 2)..fillRange(0, _base * 2, -1);
    _maxima = Int32List(_base * 2)..fillRange(0, _base * 2, -1);
    _lowValues = Float64List(_base * 2)
      ..fillRange(0, _base * 2, double.infinity);
    _highValues = Float64List(_base * 2)
      ..fillRange(0, _base * 2, double.negativeInfinity);
    for (var page = 0; page < _pages.length; page++) {
      _refreshPage(page);
    }
    for (var node = _base - 1; node > 0; node--) {
      _merge(node);
    }
  }

  _PageExtremaIndex._copy(_PageExtremaIndex source, this._pages)
    : _base = source._base,
      _minima = source._minima,
      _maxima = source._maxima,
      _lowValues = source._lowValues,
      _highValues = source._highValues {
    source._shared = _shared = true;
    _dirty.addAll(source._dirty);
  }

  final List<_SamplePage?> _pages;
  late final int _base;
  late Int32List _minima;
  late Int32List _maxima;
  late Float64List _lowValues;
  late Float64List _highValues;
  bool _shared = false;
  final Set<int> _dirty = {};
  int _lastDirtyPage = -1;

  _PageExtremaIndex copyFor(List<_SamplePage?> pages) =>
      _PageExtremaIndex._copy(this, pages);

  void invalidate(int page) {
    if (page == _lastDirtyPage) return;
    _dirty.add(page);
    _lastDirtyPage = page;
  }

  void _refreshPage(int index) {
    final page = _pages[index];
    if (page == null) return;
    final (low, high) = page.extrema(0, _SamplePage.size);
    _minima[_base + index] = index * _SamplePage.size + low;
    _maxima[_base + index] = index * _SamplePage.size + high;
    _lowValues[_base + index] = page.values[low];
    _highValues[_base + index] = page.values[high];
  }

  void _merge(int node) {
    final left = node * 2, right = left + 1;
    final low =
        _lowValues[left] < _lowValues[right] ||
            _lowValues[left] == _lowValues[right] &&
                _minima[left] < _minima[right]
        ? left
        : right;
    final high =
        _highValues[left] > _highValues[right] ||
            _highValues[left] == _highValues[right] &&
                _maxima[left] < _maxima[right]
        ? left
        : right;
    _minima[node] = _minima[low];
    _maxima[node] = _maxima[high];
    _lowValues[node] = _lowValues[low];
    _highValues[node] = _highValues[high];
  }

  (int, int) extrema(int firstPage, int afterLastPage) {
    // Freezing a view shares the tree as well as the sample pages. Copy once
    // only when a subsequent query needs to publish changed summaries.
    if (_shared && _dirty.isNotEmpty) {
      _minima = Int32List.fromList(_minima);
      _maxima = Int32List.fromList(_maxima);
      _lowValues = Float64List.fromList(_lowValues);
      _highValues = Float64List.fromList(_highValues);
      _shared = false;
    }
    for (final page in _dirty) {
      _refreshPage(page);
      for (var node = (_base + page) ~/ 2; node > 0; node ~/= 2) {
        _merge(node);
      }
    }
    _dirty.clear();
    _lastDirtyPage = -1;
    var left = _base + firstPage, right = _base + afterLastPage;
    var low = -1, high = -1;
    var minimum = double.infinity, maximum = double.negativeInfinity;
    void include(int node) {
      final a = _lowValues[node], b = _highValues[node];
      if (a < minimum || a == minimum && (low < 0 || _minima[node] < low)) {
        minimum = a;
        low = _minima[node];
      }
      if (b > maximum || b == maximum && (high < 0 || _maxima[node] < high)) {
        maximum = b;
        high = _maxima[node];
      }
    }

    while (left < right) {
      if (left.isOdd) {
        include(left++);
      }
      if (right.isOdd) {
        right--;
        include(right);
      }
      left >>= 1;
      right >>= 1;
    }
    return (low, high);
  }
}
