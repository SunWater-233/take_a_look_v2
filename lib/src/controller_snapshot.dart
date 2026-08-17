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
      'followLatest': followLatest,
      'plotWindowEndSeconds': plotWindowEndSeconds,
      'uiScale': uiScale,
      'selectedSymbols': _selectedSymbols.toList(),
      'symbols': [
        for (final symbol in _symbols)
          {
            'source': symbol.source,
            'name': symbol.name,
            'address': symbol.address,
            'type': symbol.type,
            'size': symbol.size,
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
    symbolFile = data['symbolFile'] as String? ?? '';
    sampleRateHz = (data['sampleRateHz'] as num?)?.toDouble() ?? 50;
    rttSampleRateHz = (data['rttSampleRateHz'] as num?)?.toDouble() ?? 1000;
    elapsedSeconds = (data['elapsedSeconds'] as num?)?.toDouble() ?? 0;
    samplingPaused = data['samplingPaused'] == true;
    plottingPaused = data['plottingPaused'] == true;
    rttEnabled = data['rttEnabled'] == true;
    followLatest = data['followLatest'] != false;
    final nextUiScale = (data['uiScale'] as num?)?.toDouble() ?? uiScale;
    if ((nextUiScale - uiScale).abs() >= 0.001) {
      _uiScale.value = nextUiScale.clamp(0.5, 2).toDouble();
    }

    _selectedSymbols
      ..clear()
      ..addAll((data['selectedSymbols'] as List? ?? const []).cast<String>());
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
          );
        }),
      );

    final symbolsByKey = {for (final symbol in _symbols) symbol.key: symbol};
    final previousWatches = {
      for (final watch in _watches) watch.symbol.key: watch,
    };
    _watches
      ..clear()
      ..addAll(
        (data['watches'] as List? ?? const []).map((raw) {
          final item = Map<String, dynamic>.from(raw as Map);
          final symbol = symbolsByKey[item['key'] as String];
          if (symbol == null) return null;
          final watch =
              WatchItem(symbol: symbol, color: Color(item['color'] as int))
                ..plotted = item['plotted'] == true
                ..value = (item['value'] as num).toDouble();
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
      watch.value = (item['value'] as num?)?.toDouble() ?? watch.value;
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
}
