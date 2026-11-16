/// Smooth presentation of a backend acquisition-time anchor.
/// A hidden view stops repainting, not the underlying passage of time.
class SamplingDisplayClock {
  SamplingDisplayClock({double Function()? now}) {
    if (now == null) {
      final stopwatch = Stopwatch()..start();
      _now = () =>
          stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
    } else {
      _now = now;
    }
  }

  late final double Function() _now;
  double _base = 0;
  double? _startedAt;

  bool get running => _startedAt != null;
  double get elapsedSeconds =>
      _base +
      (_startedAt == null
          ? 0
          : (_now() - _startedAt!).clamp(0, double.infinity));

  void synchronize(double seconds, {required bool running}) {
    if (!seconds.isFinite || seconds < 0) return;
    _base = seconds;
    _startedAt = running ? _now() : null;
  }

  void setRunning(bool value) {
    if (value == running) return;
    synchronize(elapsedSeconds, running: value);
  }

  void reset() => synchronize(0, running: running);
}
