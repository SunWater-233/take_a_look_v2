part of 'controller.dart';

/// Serialization boundary for main/detached window state synchronization.
class ControllerSnapshotCodec {
  const ControllerSnapshotCodec();

  JsonObject encode(
    TakeALookController controller, {
    bool includeSamples = true,
  }) {
    return controller._encodeSnapshot(includeSamples: includeSamples);
  }

  void apply(TakeALookController controller, JsonObject data) {
    controller._applySnapshot(data);
  }
}

extension TakeALookControllerSnapshot on TakeALookController {
  JsonObject snapshot({bool includeSamples = true}) {
    return snapshotCodec.encode(this, includeSamples: includeSamples);
  }

  void applySnapshot(JsonObject data) => snapshotCodec.apply(this, data);

  JsonObject _encodeSnapshot({bool includeSamples = true}) {
    return {
      'connectionStatus': connectionStatus.name,
      'probeType': probeType,
      'targetName': targetName,
      'swdClock': swdClock,
      'serialNumber': serialNumber,
      'symbolFile': symbolFile,
      'sampleRateHz': sampleRateHz,
      'rttSampleRateHz': rttSampleRateHz,
      'displayRefreshMode': displayRefreshMode,
      'samplingElapsedSeconds': samplingElapsedSeconds,
      'elapsedSeconds': elapsedSeconds,
      'samplingPaused': samplingPaused,
      'plottingPaused': plottingPaused,
      'rttEnabled': rttEnabled,
      'rttProtocol': rttProtocol,
      'followLatest': followLatest,
      'plotVisibleWindowSeconds': plotVisibleWindowSeconds,
      'plotAutoY': plotAutoY,
      'plotYMin': plotYMin,
      'plotYMax': plotYMax,
      'plotShowGrid': plotShowGrid,
      'plotShowLegend': plotShowLegend,
      'plotMouseXEnabled': plotMouseXEnabled,
      'plotMouseYEnabled': plotMouseYEnabled,
      'plotInvertX': plotInvertX,
      'plotInvertY': plotInvertY,
      'plotWindowEndSeconds': plotWindowEndSeconds,
      'uiScale': uiScale,
      'lastBackendError': lastBackendError,
      'selectedSymbols': _selectedSymbols.toList(),
      'symbols': [for (final symbol in _symbols) symbol.toJson()],
      'watches': [
        for (final watch in _watches)
          {
            'key': watch.symbol.key,
            'color': watch.color.toARGB32(),
            'sampling': watch.samplingEnabled,
            'plotted': watch.plotted,
            'value': watch.value,
            'sampleCursor': watch.totalSampleCount,
            if (includeSamples)
              'samples': [
                for (final point in watch.samples.skip(
                  math.max(0, watch.samples.length - 600),
                ))
                  [point.dx, point.dy],
              ],
          },
      ],
      'logs': [for (final entry in _logs) entry.toJson()],
      'analysisSession': analysisSession.toJson(includeData: includeSamples),
      'debug': {
        'executionState': debugState.executionState.name,
        'sourceFiles': debugState.sourceFiles,
        'sourceRoot': debugState.sourceRoot,
        'executableLines': {
          for (final entry in debugState.executableLines.entries)
            entry.key: entry.value.toList()..sort(),
        },
        'breakpoints': [
          for (final breakpoint in debugState.resolvedBreakpoints)
            breakpoint.toJson(),
        ],
        'requestedBreakpoints': {
          for (final entry in debugState.requestedBreakpoints.entries)
            entry.key: entry.value.toList()..sort(),
        },
        'registers': debugState.registers,
        'stoppedLocation': debugState.programCounter == null
            ? null
            : {
                'address': debugState.programCounter,
                if (debugState.currentSource != null)
                  'path': debugState.currentSource,
                if (debugState.currentLine != null)
                  'line': debugState.currentLine,
              },
      },
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
            'sampleCursor': watch.totalSampleCount,
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

  Map<String, int> telemetryCursors() => {
    for (final watch in _watches) watch.symbol.key: watch.totalSampleCount,
  };

  Map<String, dynamic> telemetryDeltaSnapshot(Map<String, int> cursors) {
    return {
      'elapsedSeconds': elapsedSeconds,
      'watches': [
        for (final watch in _watches)
          _watchTelemetryDelta(watch, cursors[watch.symbol.key] ?? 0),
      ],
    };
  }

  Map<String, dynamic> _watchTelemetryDelta(WatchItem watch, int cursor) {
    final retainedStart = watch.totalSampleCount - watch.samples.length;
    final reset = cursor < retainedStart || cursor > watch.totalSampleCount;
    final sampleStart = reset ? retainedStart : cursor;
    final skip = sampleStart - retainedStart;
    return {
      'key': watch.symbol.key,
      'value': watch.value,
      'sampleStart': sampleStart,
      'sampleCursor': watch.totalSampleCount,
      if (reset) 'reset': true,
      'samples': [
        for (final point in watch.samples.skip(skip)) [point.dx, point.dy],
      ],
    };
  }

  void _applySnapshot(JsonObject data) {
    final hasConnectionState = const {
      'connectionStatus',
      'probeType',
      'targetName',
      'swdClock',
      'serialNumber',
      'lastBackendError',
    }.any(data.containsKey);
    final hasSamplingState = const {
      'sampleRateHz',
      'rttSampleRateHz',
      'samplingPaused',
      'rttEnabled',
      'rttProtocol',
    }.any(data.containsKey);
    final hasSymbolState =
        data.containsKey('selectedSymbols') || data.containsKey('symbols');
    final hasWatchState = data.containsKey('watches');
    final hasElapsedState = data.containsKey('elapsedSeconds');
    final hasAnalysisState = data.containsKey('analysisSession');
    final hasDebugState = data.containsKey('debug');
    final hasPlotState =
        hasWatchState ||
        hasElapsedState ||
        const {
          'displayRefreshMode',
          'plottingPaused',
          'followLatest',
          'plotVisibleWindowSeconds',
          'plotAutoY',
          'plotYMin',
          'plotYMax',
          'plotShowGrid',
          'plotShowLegend',
          'plotMouseXEnabled',
          'plotMouseYEnabled',
          'plotInvertX',
          'plotInvertY',
          'plotWindowEndSeconds',
        }.any(data.containsKey);
    final wasPlotFrozen = plottingPaused;
    final previousConnectionStatus = connectionStatus;
    final previousDisplayRefreshMode = displayRefreshMode;
    final previousSampleRateHz = sampleRateHz;
    connectionStatus = ConnectionStatus.values.byName(
      data['connectionStatus'] as String? ?? connectionStatus.name,
    );
    probeType = data['probeType'] as String? ?? probeType;
    targetName = data['targetName'] as String? ?? targetName;
    swdClock = data['swdClock'] as String? ?? swdClock;
    serialNumber = data['serialNumber'] as String? ?? serialNumber;
    symbolFile = data['symbolFile'] as String? ?? symbolFile;
    sampleRateHz = (data['sampleRateHz'] as num?)?.toDouble() ?? sampleRateHz;
    rttSampleRateHz =
        (data['rttSampleRateHz'] as num?)?.toDouble() ?? rttSampleRateHz;
    final nextDisplayRefreshMode = data['displayRefreshMode'] as String?;
    if (const {
      'standard',
      'high',
      'realtime',
    }.contains(nextDisplayRefreshMode)) {
      displayRefreshMode = nextDisplayRefreshMode!;
    }
    if (connectionStatus != previousConnectionStatus ||
        displayRefreshMode != previousDisplayRefreshMode ||
        (displayRefreshMode == 'realtime' &&
            sampleRateHz != previousSampleRateHz)) {
      _resetPlotRefreshSchedule();
    }
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
    plotVisibleWindowSeconds =
        (data['plotVisibleWindowSeconds'] as num?)?.toDouble() ??
        plotVisibleWindowSeconds;
    if (data.containsKey('plotAutoY')) {
      plotAutoY = data['plotAutoY'] != false;
    }
    if (data.containsKey('plotYMin')) {
      plotYMin = (data['plotYMin'] as num?)?.toDouble();
    }
    if (data.containsKey('plotYMax')) {
      plotYMax = (data['plotYMax'] as num?)?.toDouble();
    }
    if (data.containsKey('plotShowGrid')) {
      plotShowGrid = data['plotShowGrid'] != false;
    }
    if (data.containsKey('plotShowLegend')) {
      plotShowLegend = data['plotShowLegend'] != false;
    }
    if (data.containsKey('plotMouseXEnabled')) {
      plotMouseXEnabled = data['plotMouseXEnabled'] != false;
    }
    if (data.containsKey('plotMouseYEnabled')) {
      plotMouseYEnabled = data['plotMouseYEnabled'] != false;
    }
    if (data.containsKey('plotInvertX')) {
      plotInvertX = data['plotInvertX'] == true;
    }
    if (data.containsKey('plotInvertY')) {
      plotInvertY = data['plotInvertY'] == true;
    }
    if (data.containsKey('samplingElapsedSeconds')) {
      _samplingElapsedBaseSeconds =
          (data['samplingElapsedSeconds'] as num?)?.toDouble() ??
          _samplingElapsedBaseSeconds;
      _samplingElapsedStopwatch.reset();
    }
    if (data.containsKey('connectionStatus') ||
        data.containsKey('samplingPaused') ||
        data.containsKey('samplingElapsedSeconds')) {
      _reconcileSamplingClock();
    }
    final nextUiScale = (data['uiScale'] as num?)?.toDouble() ?? uiScale;
    if ((nextUiScale - uiScale).abs() >= 0.001) {
      _uiScale.value = nextUiScale.clamp(0.5, 2).toDouble();
    }
    if (data.containsKey('lastBackendError')) {
      lastBackendError = _asMap(data['lastBackendError']);
    } else if (data.containsKey('connectionStatus') &&
        connectionStatus == ConnectionStatus.connected) {
      lastBackendError = null;
    }

    if (data.containsKey('selectedSymbols')) {
      _selectedSymbols
        ..clear()
        ..addAll((data['selectedSymbols'] as List? ?? const []).cast<String>());
    }
    if (data.containsKey('symbols')) {
      _replaceSymbols(
        (data['symbols'] as List? ?? const []).map((raw) {
          return SymbolItem.fromJson(Map<String, dynamic>.from(raw as Map));
        }),
      );
    }

    if (data.containsKey('watches')) {
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
                WatchItem(symbol: symbol, color: _colorFromValue(item['color']))
                  ..samplingEnabled = item['sampling'] != false
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
            watch.totalSampleCount = samples == null
                ? previousWatches[watch.symbol.key]?.totalSampleCount ?? 0
                : (item['sampleCursor'] as int?) ?? watch.samples.length;
            return watch;
          }).whereType<WatchItem>(),
        );
    }

    if (data.containsKey('logs')) {
      _logs
        ..clear()
        ..addAll(
          (data['logs'] as List? ?? const []).map((raw) {
            return LogEntry.fromJson(Map<String, dynamic>.from(raw as Map));
          }),
        );
    }
    if (hasAnalysisState) {
      analysisSession.applyJson(
        Map<String, dynamic>.from(data['analysisSession']! as Map),
      );
    }
    if (hasDebugState && data['debug'] is Map) {
      applyDebugState(
        Map<String, dynamic>.from(data['debug'] as Map),
        emit: false,
      );
    }
    if (hasPlotState) {
      _frozenPlotEndSeconds = plottingPaused || !followLatest
          ? (data['plotWindowEndSeconds'] as num?)?.toDouble() ?? elapsedSeconds
          : null;
      if (plottingPaused) {
        if (!wasPlotFrozen || _frozenPlotSamples.isEmpty) {
          _capturePlotSamples();
        }
      } else {
        _frozenPlotSamples.clear();
      }
    }
    _emitState([
      if (hasConnectionState) signals.connection,
      if (hasSamplingState) signals.sampling,
      if (hasSymbolState) signals.symbols,
      if (hasWatchState) signals.watches,
      if (hasWatchState || hasElapsedState) signals.telemetry,
      if (hasPlotState) signals.plot,
      if (hasPlotState) signals.plotControls,
      if (data.containsKey('logs')) signals.logs,
      if (hasAnalysisState) signals.analysis,
      if (hasDebugState) signals.debug,
    ], sync: false);
  }
}
