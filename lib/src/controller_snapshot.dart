part of 'controller.dart';

extension TakeALookControllerSnapshot on TakeALookController {
  Map<String, dynamic> snapshot({bool includeSamples = true}) {
    return {
      'connectionStatus': connectionStatus.name,
      'probeType': probeType,
      'targetName': targetName,
      'swdClock': swdClock,
      'serialNumber': serialNumber,
      'symbolFile': symbolFile,
      'sampleRateHz': sampleRateHz,
      'rttSampleRateHz': rttSampleRateHz,
      'elapsedSeconds': elapsedSeconds,
      'samplingPaused': samplingPaused,
      'plottingPaused': plottingPaused,
      'rttEnabled': rttEnabled,
      'rttProtocol': rttProtocol,
      'followLatest': followLatest,
      'plotWindowEndSeconds': plotWindowEndSeconds,
      'uiScale': uiScale,
      'lastBackendError': lastBackendError,
      'selectedSymbols': _selectedSymbols.toList(),
      'symbols': [
        for (final symbol in _symbols)
          {
            'source': symbol.source,
            'name': symbol.name,
            'address': symbol.address,
            'type': symbol.type,
            'size': symbol.size,
            'key': symbol.key,
            'writable': symbol.writable,
            'dataSource': symbol.dataSource,
          },
      ],
      'watches': [
        for (final watch in _watches)
          {
            'key': watch.symbol.key,
            'color': watch.color.toARGB32(),
            'plotted': watch.plotted,
            'value': watch.value,
            if (includeSamples)
              'samples': [
                for (final point in watch.samples.skip(
                  math.max(0, watch.samples.length - 600),
                ))
                  [point.dx, point.dy],
              ],
          },
      ],
      'logs': [
        for (final entry in _logs)
          {
            'timestamp': entry.timestamp.millisecondsSinceEpoch,
            'message': entry.message,
          },
      ],
    };
  }

  Map<String, dynamic> stateSnapshot() => snapshot(includeSamples: false);

  Map<String, dynamic> telemetrySnapshot() {
    return {
      'elapsedSeconds': elapsedSeconds,
      'watches': [
        for (final watch in _watches)
          {
            'key': watch.symbol.key,
            'value': watch.value,
            'samples': [
              for (final point in watch.samples.skip(
                math.max(0, watch.samples.length - 600),
              ))
                [point.dx, point.dy],
            ],
          },
      ],
    };
  }

  void applySnapshot(Map<String, dynamic> data) {
    final wasPlotFrozen = plottingPaused || !followLatest;
    connectionStatus = ConnectionStatus.values.byName(
      data['connectionStatus'] as String? ?? ConnectionStatus.disconnected.name,
    );
    probeType = data['probeType'] as String? ?? probeType;
    targetName = data['targetName'] as String? ?? targetName;
    swdClock = data['swdClock'] as String? ?? swdClock;
    serialNumber = data['serialNumber'] as String? ?? serialNumber;
    symbolFile = data['symbolFile'] as String? ?? symbolFile;
    sampleRateHz = (data['sampleRateHz'] as num?)?.toDouble() ?? sampleRateHz;
    rttSampleRateHz =
        (data['rttSampleRateHz'] as num?)?.toDouble() ?? rttSampleRateHz;
    elapsedSeconds =
        (data['elapsedSeconds'] as num?)?.toDouble() ?? elapsedSeconds;
    if (data.containsKey('samplingPaused')) {
      samplingPaused = data['samplingPaused'] == true;
    }
    if (data.containsKey('plottingPaused')) {
      plottingPaused = data['plottingPaused'] == true;
    }
    if (data.containsKey('rttEnabled')) {
      rttEnabled = data['rttEnabled'] == true;
    }
    rttProtocol = data['rttProtocol'] as String? ?? rttProtocol;
    if (data.containsKey('followLatest')) {
      followLatest = data['followLatest'] != false;
    }
    final nextUiScale = (data['uiScale'] as num?)?.toDouble() ?? uiScale;
    if ((nextUiScale - uiScale).abs() >= 0.001) {
      _uiScale.value = nextUiScale.clamp(0.5, 2).toDouble();
    }
    if (data.containsKey('lastBackendError')) {
      lastBackendError = _asMap(data['lastBackendError']);
    } else if (connectionStatus == ConnectionStatus.connected) {
      lastBackendError = null;
    }

    if (data.containsKey('selectedSymbols')) {
      _selectedSymbols
        ..clear()
        ..addAll((data['selectedSymbols'] as List? ?? const []).cast<String>());
    }
    if (data.containsKey('symbols')) {
      _symbols
        ..clear()
        ..addAll(
          (data['symbols'] as List? ?? const []).map((raw) {
            final item = Map<String, dynamic>.from(raw as Map);
            return SymbolItem(
              source: item['source'] as String,
              name: item['name'] as String,
              address: item['address'] as int,
              type: item['type'] as String,
              size: item['size'] as int,
              backendKey: item['key'] as String?,
              writable: item['writable'] != false,
              dataSource: item['dataSource'] as String? ?? 'memory',
            );
          }),
        );
    }

    final symbolsByKey = {for (final symbol in _symbols) symbol.key: symbol};
    final previousWatches = {
      for (final watch in _watches) watch.symbol.key: watch,
    };
    if (data.containsKey('watches')) {
      _watches
        ..clear()
        ..addAll(
          (data['watches'] as List? ?? const []).map((raw) {
            final item = Map<String, dynamic>.from(raw as Map);
            final symbol = symbolsByKey[item['key'] as String];
            if (symbol == null) return null;
            final watch =
                WatchItem(symbol: symbol, color: _colorFromValue(item['color']))
                  ..plotted = item['plotted'] == true
                  ..value = _numericValue(item['value']);
            final samples = item['samples'] as List?;
            if (samples == null) {
              watch.samples.addAll(
                previousWatches[watch.symbol.key]?.samples ?? [],
              );
            }
            for (final rawPoint in samples ?? const []) {
              final point = rawPoint as List;
              watch.samples.add(
                Offset(
                  (point[0] as num).toDouble(),
                  (point[1] as num).toDouble(),
                ),
              );
            }
            return watch;
          }).whereType<WatchItem>(),
        );
    }

    if (data.containsKey('logs')) {
      _logs
        ..clear()
        ..addAll(
          (data['logs'] as List? ?? const []).map((raw) {
            final item = Map<String, dynamic>.from(raw as Map);
            return LogEntry.at(
              item['message'] as String,
              DateTime.fromMillisecondsSinceEpoch(item['timestamp'] as int),
            );
          }),
        );
    }
    _frozenPlotEndSeconds = plottingPaused || !followLatest
        ? (data['plotWindowEndSeconds'] as num?)?.toDouble() ?? elapsedSeconds
        : null;
    if (plottingPaused || !followLatest) {
      if (!wasPlotFrozen || _frozenPlotSamples.isEmpty) {
        _capturePlotSamples();
      }
    } else {
      _frozenPlotSamples.clear();
    }
    _emitState([
      _connectionChanges,
      _samplingChanges,
      _symbolChanges,
      _watchChanges,
      _telemetryChanges,
      _plotChanges,
      _logChanges,
    ], sync: false);
  }

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
      final samples = item['samples'] as List?;
      if (samples != null) {
        watch.samples
          ..clear()
          ..addAll(
            samples.map((rawPoint) {
              final point = rawPoint as List;
              return Offset(
                (point[0] as num).toDouble(),
                (point[1] as num).toDouble(),
              );
            }),
          );
      }
    }
    _emitTelemetry(sync: false);
  }

  void applyBackendEvent(String event, Object? params) {
    switch (event) {
      case 'state':
        final state = _asMap(params);
        if (state != null) applySnapshot(state);
      case 'samples':
        final payload = _asMap(params);
        if (payload != null) applyBackendSamples(payload);
      case 'samplesCleared':
        applyBackendSamplesCleared();
      case 'log':
        final payload = _asMap(params);
        final message = payload?['message'];
        if (message is String && message.isNotEmpty) addLog(message);
      case 'error':
        final payload = _asMap(params);
        if (payload == null) break;
        lastBackendError = payload;
        final message = payload['message'] as String? ?? '后端操作失败。';
        final details = payload['details'];
        _appendLog(details == null ? message : '$message（$details）');
        _emitState([_connectionChanges, _logChanges]);
      case 'perf':
        final payload = _asMap(params);
        if (payload == null) break;
        performanceStats = payload;
        final now = DateTime.now();
        if (_lastPerformanceLogAt == null ||
            now.difference(_lastPerformanceLogAt!) >=
                const Duration(seconds: 5)) {
          _lastPerformanceLogAt = now;
          final effectiveHz = (payload['effectiveHz'] as num?)?.toDouble() ?? 0;
          final sampleCount = payload['sampleCount'] as int? ?? 0;
          final blockCount = payload['readBlockCount'] as int? ?? 0;
          _appendLog(
            '采样性能：${effectiveHz.toStringAsFixed(1)} Hz，'
            '$sampleCount 帧，$blockCount 个读取块。',
          );
          _emitState([_logChanges]);
        }
    }
  }

  void applyBackendSamples(Map<String, dynamic> payload) {
    final watchesByKey = {
      for (final watch in _watches) watch.symbol.key: watch,
    };
    final frames = payload['frames'] as List? ?? const [];
    for (final rawFrame in frames) {
      final frame = _asMap(rawFrame);
      if (frame == null) continue;
      final elapsed = (frame['elapsed'] as num?)?.toDouble();
      final values = _asMap(frame['values']);
      if (elapsed == null || values == null) continue;
      elapsedSeconds = math.max(elapsedSeconds, elapsed);
      for (final entry in values.entries) {
        final watch = watchesByKey[entry.key];
        if (watch == null) continue;
        watch.value = _numericValue(entry.value, fallback: watch.value);
        watch.samples.add(Offset(elapsed, watch.value));
        if (watch.samples.length > 1800) watch.samples.removeAt(0);
      }
    }
    _emitTelemetry();
  }

  void applyBackendSamplesCleared() {
    elapsedSeconds = 0;
    for (final watch in _watches) {
      watch.samples.clear();
    }
    _frozenPlotSamples.clear();
    if (plottingPaused || !followLatest) _frozenPlotEndSeconds = 0;
    _emitState([_samplingChanges, _telemetryChanges, _plotChanges]);
    _telemetrySyncChanges.emit();
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  static double _numericValue(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is bool) return value ? 1 : 0;
    return fallback;
  }

  static Color _colorFromValue(Object? value) {
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
}
