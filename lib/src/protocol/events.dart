enum BackendEventType {
  freeRtos,
  state,
  samples,
  watchValues,
  samplesCleared,
  log,
  error,
  perf,
  debug,
  symbolLoadProgress,
  sourceTask;

  String get wireName => name;

  static BackendEventType parse(String value) {
    for (final event in values) {
      if (event.wireName == value) return event;
    }
    throw FormatException('Unknown backend event: $value');
  }
}
