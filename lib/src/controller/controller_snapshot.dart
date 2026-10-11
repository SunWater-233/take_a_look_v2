part of 'controller.dart';

/// Serialization boundary for main/detached window state synchronization.
class ControllerSnapshotCodec {
  const ControllerSnapshotCodec();

  JsonObject encode(
    TakeALookController controller, {
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
  }) {
    return controller._encodeSnapshot(
      includeSamples: includeSamples,
      packedSamples: packedSamples,
      includeAnalysisData: includeAnalysisData,
    );
  }

  void apply(TakeALookController controller, JsonObject data) {
    controller._applySnapshot(data);
  }
}

extension TakeALookControllerSnapshot on TakeALookController {
  JsonObject snapshot({
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
  }) {
    return snapshotCodec.encode(
      this,
      includeSamples: includeSamples,
      packedSamples: packedSamples,
      includeAnalysisData: includeAnalysisData,
    );
  }

  void applySnapshot(JsonObject data) => snapshotCodec.apply(this, data);

  JsonObject _encodeSnapshot({
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
    Set<String>? fields,
  }) {
    bool wants(String key) => fields == null || fields.contains(key);
    return {
      if (wants('connectionStatus')) 'connectionStatus': connectionStatus.name,
      if (wants('probeType')) 'probeType': probeType,
      if (wants('targetName')) 'targetName': targetName,
      if (wants('swdClock')) 'swdClock': swdClock,
      if (wants('serialNumber')) 'serialNumber': serialNumber,
      if (wants('connectionKind')) 'connectionKind': connectionKind,
      if (wants('gatewayProtocolVersion'))
        'gatewayProtocolVersion': state.connection.gatewayProtocolVersion,
      if (wants('remoteConfig'))
        'remoteConfig': Map<String, String>.from(remoteConfig),
      if (wants('symbolFile')) 'symbolFile': symbolFile,
      if (wants('symbolLoad') && symbolLoadProgress != null)
        'symbolLoad': symbolLoadProgress!.toJson(),
      if (wants('sampleRateHz')) 'sampleRateHz': sampleRateHz,
      if (wants('rttSampleRateHz')) 'rttSampleRateHz': rttSampleRateHz,
      if (wants('displayRefreshMode')) 'displayRefreshMode': displayRefreshMode,
      if (wants('samplingElapsedSeconds'))
        'samplingElapsedSeconds': samplingElapsedSeconds,
      if (wants('elapsedSeconds')) 'elapsedSeconds': elapsedSeconds,
      if (wants('samplingPaused')) 'samplingPaused': samplingPaused,
      if (wants('rawRecording')) 'rawRecording': rawRecording,
      if (wants('plottingPaused')) 'plottingPaused': plottingPaused,
      if (wants('plotHighlightedWatchKey'))
        'plotHighlightedWatchKey': plotHighlightedWatchKey,
      if (wants('plotWatchSelectionRevision'))
        'plotWatchSelectionRevision': plotWatchSelectionRevision,
      if (wants('rttEnabled')) 'rttEnabled': rttEnabled,
      if (wants('rttProtocol')) 'rttProtocol': rttProtocol,
      if (wants('followLatest')) 'followLatest': followLatest,
      if (wants('plotVisibleWindowSeconds'))
        'plotVisibleWindowSeconds': plotVisibleWindowSeconds,
      if (wants('plotRetentionSeconds'))
        'plotRetentionSeconds': plotRetentionSeconds,
      if (wants('plotAutoY')) 'plotAutoY': plotAutoY,
      if (wants('plotYMin')) 'plotYMin': plotYMin,
      if (wants('plotYMax')) 'plotYMax': plotYMax,
      if (wants('plotShowGrid')) 'plotShowGrid': plotShowGrid,
      if (wants('plotShowLegend')) 'plotShowLegend': plotShowLegend,
      if (wants('plotMouseXEnabled')) 'plotMouseXEnabled': plotMouseXEnabled,
      if (wants('plotMouseYEnabled')) 'plotMouseYEnabled': plotMouseYEnabled,
      if (wants('plotInvertX')) 'plotInvertX': plotInvertX,
      if (wants('plotInvertY')) 'plotInvertY': plotInvertY,
      if (wants('plotWindowEndSeconds'))
        'plotWindowEndSeconds': plotWindowEndSeconds,
      if (wants('uiScale')) 'uiScale': uiScale,
      if (wants('lastBackendError')) 'lastBackendError': lastBackendError,
      if (wants('selectedSymbols'))
        'selectedSymbols': _selectedSymbols.toList(),
      if (wants('symbols'))
        'symbols': [for (final symbol in _symbols) symbol.toJson()],
      if (wants('watches'))
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
                'samples': packedSamples
                    ? watch.samples.packedRange()
                    : [
                        for (final point in watch.samples) [point.dx, point.dy],
                      ],
            },
        ],
      if (wants('logs')) 'logs': [for (final entry in _logs) entry.toJson()],
      if (wants('analysisSession'))
        'analysisSession': analysisSession.toJson(
          includeData: includeAnalysisData ?? includeSamples,
          packed: packedSamples,
        ),
      if (wants('sourceWorkspace')) 'sourceWorkspace': sourceWorkspace.toJson(),
      if (wants('debug'))
        'debug': {
          'stopRevision': debugState.stopRevision,
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
              for (final point in watch.samples) [point.dx, point.dy],
            ],
          },
      ],
    };
  }

  Map<String, int> telemetryCursors() => {
    for (final watch in _watches) watch.symbol.key: watch.totalSampleCount,
  };

  Map<String, dynamic> telemetryDeltaSnapshot(
    Map<String, int> cursors, {
    bool packedSamples = false,
    bool includeSamples = true,
  }) {
    return {
      'elapsedSeconds': elapsedSeconds,
      'watches': [
        for (final watch in _watches)
          _watchTelemetryDelta(
            watch,
            cursors[watch.symbol.key] ?? 0,
            packedSamples: packedSamples,
            includeSamples: includeSamples,
          ),
      ],
    };
  }

  Map<String, dynamic> _watchTelemetryDelta(
    WatchItem watch,
    int cursor, {
    required bool packedSamples,
    required bool includeSamples,
  }) {
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
      if (includeSamples)
        'samples': packedSamples
            ? watch.samples.packedRange(skip)
            : [
                for (final point in watch.samples.skip(skip))
                  [point.dx, point.dy],
              ],
    };
  }

  void _applySnapshot(JsonObject data) {
    _touchSnapshotFields(data.keys);
    final hasConnectionState = const {
      'connectionStatus',
      'probeType',
      'targetName',
      'swdClock',
      'serialNumber',
      'connectionKind',
      'gatewayProtocolVersion',
      'remoteConfig',
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
    final hasPlotHighlightState = data.containsKey('plotHighlightedWatchKey');
    final hasPlotWatchSelection = data.containsKey(
      'plotWatchSelectionRevision',
    );
    final hasElapsedState = data.containsKey('elapsedSeconds');
    final hasAnalysisState = data.containsKey('analysisSession');
    final hasDebugState = data.containsKey('debug');
    final hasSourceWorkspace = data['sourceWorkspace'] is Map;
    final hasPlotState =
        hasWatchState ||
        hasElapsedState ||
        const {
          'displayRefreshMode',
          'plottingPaused',
          'followLatest',
          'plotVisibleWindowSeconds',
          'plotRetentionSeconds',
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
    connectionKind = data['connectionKind'] as String? ?? connectionKind;
    if (data.containsKey('gatewayProtocolVersion')) {
      state.connection.gatewayProtocolVersion =
          data['gatewayProtocolVersion'] as int?;
    }
    if (data['remoteConfig'] case final Map config) {
      remoteConfig.addAll(Map<String, String>.from(config));
    }
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
    final retention = (data['plotRetentionSeconds'] as num?)?.toDouble();
    if (retention != null && retention.isFinite && retention > 0) {
      state.plot.retentionSeconds = retention.clamp(1, 120).toDouble();
      _configurePlotRetention();
    }
    if (data['rawRecording'] is Map) {
      state.acquisition.rawRecording = Map<String, dynamic>.from(
        data['rawRecording'] as Map,
      );
    }
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
            final samples = item['samples'];
            final watch =
                WatchItem(
                    symbol: symbol,
                    color: _colorFromValue(item['color']),
                    samples: samples == null
                        ? previousWatches[symbol.key]?.samples
                        : null,
                  )
                  ..samplingEnabled = item['sampling'] != false
                  ..plotted = item['plotted'] == true
                  ..value = _numericValue(item['value']);
            telemetryStore.configureWatch(watch);
            _appendWireSamples(watch.samples, samples);
            watch.totalSampleCount = samples == null
                ? previousWatches[watch.symbol.key]?.totalSampleCount ?? 0
                : (item['sampleCursor'] as int?) ?? _sampleWireLength(samples);
            return watch;
          }).whereType<WatchItem>(),
        );
    }

    if (data['discardSampleHistory'] == true) {
      for (final watch in _watches) {
        watch.samples.clear();
      }
      _frozenPlotSamples.clear();
    }

    if (hasPlotHighlightState) {
      state.plot.highlightedWatchKey =
          data['plotHighlightedWatchKey'] as String?;
    }
    if (hasPlotWatchSelection) {
      state.plot.watchSelectionRevision =
          data['plotWatchSelectionRevision'] as int;
    }
    if ((hasWatchState || hasPlotHighlightState) &&
        _watchByKey(plotHighlightedWatchKey ?? '') == null) {
      state.plot.highlightedWatchKey = null;
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
      if ((data['analysisSession'] as Map).containsKey('series')) {
        _analysisDataRevision++;
      }
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
    if (hasSourceWorkspace) {
      sourceWorkspace.applyJson(
        Map<String, dynamic>.from(data['sourceWorkspace'] as Map),
      );
    }
    // Apply after symbol/source data so a detached window cannot finish early.
    if (data['symbolLoad'] is Map) {
      applySymbolLoadSnapshot(
        Map<String, dynamic>.from(data['symbolLoad'] as Map),
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
      if (hasWatchState ||
          hasPlotWatchSelection ||
          data.containsKey('connectionKind'))
        signals.watches,
      if (hasWatchState || hasElapsedState) signals.telemetry,
      if (hasPlotState || hasPlotHighlightState) signals.plot,
      if (hasPlotState) signals.plotControls,
      if (data.containsKey('logs')) signals.logs,
      if (hasAnalysisState) signals.analysis,
      if (hasDebugState) signals.debug,
      if (hasSourceWorkspace) signals.sourceWorkspace,
    ], sync: false);
  }
}
