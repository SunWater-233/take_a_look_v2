part of 'controller.dart';

extension TakeALookControllerTelemetry on TakeALookController {
  void applyTelemetrySnapshot(Map<String, dynamic> data) {
    elapsedSeconds =
        (data['elapsedSeconds'] as num?)?.toDouble() ?? elapsedSeconds;
    final watchesByKey = {
      for (final watch in _watches) watch.symbol.key: watch,
    };
    for (final raw in data['watches'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final watch = watchesByKey[item['key'] as String?];
      if (watch == null) continue;
      watch.value = _numericValue(item['value'], fallback: watch.value);
      watch.updatedAtMs =
          (item['updatedAtMs'] as num?)?.toInt() ?? watch.updatedAtMs;
      final samples = item['samples'];
      if (samples != null) {
        watch.samples.clear();
        _appendWireSamples(watch.samples, samples);
        watch.totalSampleCount =
            (item['sampleCursor'] as int?) ?? _sampleWireLength(samples);
      }
    }
    _emitTelemetry(sync: false);
  }

  void applyTelemetryDelta(Map<String, dynamic> data) {
    elapsedSeconds =
        (data['elapsedSeconds'] as num?)?.toDouble() ?? elapsedSeconds;
    final watchesByKey = {
      for (final watch in _watches) watch.symbol.key: watch,
    };
    for (final raw in data['watches'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final watch = watchesByKey[item['key'] as String?];
      if (watch == null) continue;
      watch.value = _numericValue(item['value'], fallback: watch.value);
      watch.updatedAtMs =
          (item['updatedAtMs'] as num?)?.toInt() ?? watch.updatedAtMs;
      final sampleStart = item['sampleStart'] as int? ?? 0;
      final sampleCursor = item['sampleCursor'] as int? ?? sampleStart;
      if (item['reset'] == true ||
          watch.totalSampleCount < sampleStart ||
          watch.totalSampleCount > sampleCursor) {
        watch.samples.clear();
        watch.totalSampleCount = sampleStart;
      }
      final rawSamples = item['samples'];
      final alreadyApplied = (watch.totalSampleCount - sampleStart)
          .clamp(0, _sampleWireLength(rawSamples))
          .toInt();
      telemetryStore.configureWatch(watch);
      _appendWireSamples(watch.samples, rawSamples, skip: alreadyApplied);
      watch.totalSampleCount = sampleCursor;
    }
    _emitTelemetry(sync: false);
  }

  void applyBackendEvent(BackendEventType event, Object? params) {
    switch (event) {
      case BackendEventType.freeRtos:
        if (params is Map) {
          state.freeRtos = FreeRtosSnapshot(params);
          _emitState([signals.freeRtos]);
        }
      case BackendEventType.state:
        final state = _asMap(params);
        if (state != null) {
          applySnapshot(state);
          signals.stateSync.emit();
        }
      case BackendEventType.samples:
        if (params is BackendSampleBatch) {
          applyBackendSampleBatch(params);
        } else {
          final payload = _asMap(params);
          if (payload != null) applyBackendSamples(payload);
        }
      case BackendEventType.samplesCleared:
        applyBackendSamplesCleared();
      case BackendEventType.watchValues:
        final payload = _asMap(params);
        if (payload != null) applyWatchValues(payload);
      case BackendEventType.log:
        final payload = _asMap(params);
        final message = payload?['message'];
        if (message is String && message.isNotEmpty) {
          addLog(message, level: LogLevel.parse(payload?['level'] as String?));
        }
      case BackendEventType.error:
        final payload = _asMap(params);
        if (payload == null) break;
        lastBackendError = payload;
        final message = payload['message'] as String? ?? '后端操作失败。';
        final details = payload['details'];
        _appendLog(
          details == null ? message : '$message（$details）',
          level: LogLevel.error,
        );
        _emitState([signals.connection, signals.logs]);
      case BackendEventType.perf:
        final payload = _asMap(params);
        if (payload == null) break;
        performanceStats = payload;
        final effectiveHz = (payload['effectiveHz'] as num?)?.toDouble() ?? 0;
        final sampleCount = (payload['sampleCount'] as num?)?.toInt() ?? 0;
        // Keep idle performance events out of the user-facing log, matching
        // the original desktop application.
        if (sampleCount <= 0 && effectiveHz <= 0) break;
        final now = DateTime.now();
        if (_lastPerformanceLogAt == null ||
            now.difference(_lastPerformanceLogAt!) >=
                const Duration(seconds: 5)) {
          _lastPerformanceLogAt = now;
          final watchCount = (payload['watchCount'] as num?)?.toInt() ?? 0;
          final blockCount = (payload['readBlockCount'] as num?)?.toInt() ?? 0;
          final byteCount = (payload['readByteCount'] as num?)?.toInt() ?? 0;
          final memoryDropped =
              (payload['memoryDroppedSamples'] as num?)?.toInt() ?? 0;
          final memorySkipped =
              (payload['memorySkippedTicks'] as num?)?.toInt() ?? 0;
          final memoryTiming = connectionKind == 'ember'
              ? '，传输跳样 $memoryDropped，采样错过周期 $memorySkipped'
              : '';
          final phoneReadUs =
              (payload['memoryPhoneReadUs'] as num?)?.toInt() ?? 0;
          final samplingMode = payload['memorySamplingMode'] as String?;
          final modeLabel = samplingMode == 'full' ? '全速' : '定时';
          final burst = (payload['memoryBurst'] as num?)?.toInt() ?? 1;
          final burstTiming =
              payload['memoryTimeQuality'] == 'transaction_window';
          final deliveredLabel = burstTiming
              ? '读取吞吐 ${effectiveHz.toStringAsFixed(1)} 次/秒（每批 $burst 次，子读时刻未知）'
              : '实际 ${effectiveHz.toStringAsFixed(1)} Hz';
          final ceiling = samplingMode != null && phoneReadUs > 0
              ? '，手机每批读取 ${(phoneReadUs / 1000).toStringAsFixed(1)} ms'
                    '（$modeLabel）'
              : '';
          _appendLog(
            '采样性能：目标 ${sampleRateHz.toStringAsFixed(0)} Hz，'
            '$deliveredLabel，'
            '样本 $sampleCount，变量 $watchCount，'
            '读块 $blockCount，字节 $byteCount$memoryTiming$ceiling。',
          );
          _emitState([signals.logs]);
        }
      case BackendEventType.debug:
        final payload = _asMap(params);
        if (payload != null) applyDebugState(payload);
      case BackendEventType.symbolLoadProgress:
        final payload = _asMap(params);
        if (payload != null) applySymbolLoadProgress(payload);
      case BackendEventType.sourceTask:
        final payload = _asMap(params);
        if (payload != null) applySourceTask(payload);
    }
  }

  void applyWatchValues(Map<String, dynamic> payload) {
    final byKey = {
      for (final watch in acquisitionWatches) watch.symbol.key: watch,
    };
    for (final raw in payload['values'] as List? ?? const []) {
      if (raw is! Map) continue;
      final watch = byKey[raw['key']];
      if (watch == null) continue;
      final updated = (raw['updatedAtMs'] as num?)?.toInt();
      if (updated != null &&
          watch.updatedAtMs != null &&
          updated < watch.updatedAtMs!) {
        continue;
      }
      watch.value = _numericValue(raw['value'], fallback: watch.value);
      watch.updatedAtMs = updated ?? DateTime.now().millisecondsSinceEpoch;
    }
    // Latest-only values never enter the plot buffer or recording history.
    _emitTelemetry();
  }

  void applyBackendSamples(Map<String, dynamic> payload) {
    elapsedSeconds = telemetryStore.applyJsonFrames(
      payload,
      acquisitionWatches,
      currentElapsed: elapsedSeconds,
    );
    _emitTelemetry();
  }

  void applyBackendSampleBatch(BackendSampleBatch batch) {
    elapsedSeconds = telemetryStore.applyBinaryBatch(
      batch,
      acquisitionWatches,
      currentElapsed: elapsedSeconds,
    );
    _emitTelemetry();
  }

  void applyBackendSamplesCleared() {
    plotHistory.clear();
    state.acquisition.rawRecording = {};
    elapsedSeconds = 0;
    telemetryStore.clear(_allRetainedWatches);
    _frozenPlotSamples.clear();
    if (plottingPaused || !followLatest) _frozenPlotEndSeconds = 0;
    _emitState([signals.sampling, signals.telemetry, signals.plot]);
    signals.telemetrySync.emit();
  }
}

Map<String, dynamic>? _asMap(Object? value) {
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

double _numericValue(Object? value, {double fallback = 0}) {
  return TelemetryStore.numericValue(value, fallback: fallback);
}

Color _colorFromValue(Object? value) {
  if (value is int) return Color(value);
  if (value is String) {
    final normalized = value.replaceFirst('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed != null) {
      return Color(normalized.length <= 6 ? 0xFF000000 | parsed : parsed);
    }
  }
  return seriesColors.first;
}
