enum BackendEventType {
  state,
  samples,
  samplesCleared,
  log,
  error,
  perf;

  String get wireName => name;

  static BackendEventType parse(String value) {
    for (final event in values) {
      if (event.wireName == value) return event;
    }
    throw FormatException('Unknown backend event: $value');
  }
}
