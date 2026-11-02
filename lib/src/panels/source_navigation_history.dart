/// View-local navigation state. The panel owns revealing a location and focus;
/// this object owns bounded history and invalidates the forward branch on jumps.
class SourceNavigationHistory<T extends Object> {
  SourceNavigationHistory({this.limit = 100}) : assert(limit > 0);

  final int limit;
  final List<T> _back = [];
  final List<T> _forward = [];

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  void record(T origin) {
    _back.add(origin);
    if (_back.length > limit) _back.removeAt(0);
    _forward.clear();
  }

  T? travel({required bool back, T? current}) {
    final from = back ? _back : _forward;
    final to = back ? _forward : _back;
    if (from.isEmpty) return null;
    if (current != null) to.add(current);
    return from.removeLast();
  }

  void clear() {
    _back.clear();
    _forward.clear();
  }
}
