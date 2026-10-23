part of 'controller.dart';

extension TakeALookControllerSnapshot on TakeALookController {
  JsonObject snapshot({
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
  }) {
    return _encodeSnapshot(
      includeSamples: includeSamples,
      packedSamples: packedSamples,
      includeAnalysisData: includeAnalysisData,
    );
  }

  void applySnapshot(JsonObject data) => _applySnapshot(data);

  JsonObject _encodeSnapshot({
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
    Set<String>? fields,
  }) {
    return snapshotCodec.encode(
      ControllerSnapshotView(
        state: state,
        symbols: _symbols,
        selectedSymbols: _selectedSymbols,
        watches: _watches,
        logs: _logs,
        uiScale: uiScale,
        samplingElapsedSeconds: samplingElapsedSeconds,
        plotWindowEndSeconds: plotWindowEndSeconds,
        canUndoWatchDeletion: canUndoWatchDeletion,
        canRedoWatchDeletion: canRedoWatchDeletion,
      ),
      fields: fields,
      includeSamples: includeSamples,
      packedSamples: packedSamples,
      includeAnalysisData: includeAnalysisData,
    );
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
            'updatedAtMs': watch.updatedAtMs,
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
      'updatedAtMs': watch.updatedAtMs,
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
    final previousSymbolRevision = _symbolRevision;
    final hadDeletedWatches = _watchRegistry.canUndo;
    _touchSnapshotFields(data.keys);
    final hasConnectionState = ControllerSnapshotSchema.containsDomain(
      data,
      SnapshotDomain.connection,
      except: {SnapshotField.symbolFile},
    );
    final hasSamplingState = ControllerSnapshotSchema.containsDomain(
      data,
      SnapshotDomain.sampling,
    );
    final hasSymbolState = ControllerSnapshotSchema.containsDomain(
      data,
      SnapshotDomain.symbols,
      except: {SnapshotField.symbolFile},
      include: {SnapshotField.symbols},
    );
    final hasWatchState = ControllerSnapshotSchema.containsDomain(
      data,
      SnapshotDomain.watches,
    );
    if (_isDetachedRemote && data.containsKey('canUndoWatchDeletion')) {
      _remoteCanUndoWatchDeletion = data['canUndoWatchDeletion'] == true;
    }
    if (_isDetachedRemote && data.containsKey('canRedoWatchDeletion')) {
      _remoteCanRedoWatchDeletion = data['canRedoWatchDeletion'] == true;
    }
    final hasPlotHighlightState = data.containsKey('plotHighlightedWatchKey');
    final hasPlotWatchSelection = data.containsKey(
      'plotWatchSelectionRevision',
    );
    final hasElapsedState = data.containsKey('elapsedSeconds');
    final hasAnalysisState = data.containsKey('analysisSession');
    final hasDebugState = data.containsKey('debug');
    final hasSourceWorkspace = data['sourceWorkspace'] is Map;
    final hasSourceTools =
        data['sourceProject'] is Map || data['sourceTask'] is Map;
    final hasPlotState =
        hasWatchState ||
        hasElapsedState ||
        ControllerSnapshotSchema.containsDomain(
          data,
          SnapshotDomain.plot,
          except: {
            SnapshotField.plotHighlightedWatchKey,
            SnapshotField.plotWatchSelectionRevision,
          },
        );
    final wasPlotFrozen = plottingPaused;
    final previousConnectionStatus = connectionStatus;
    final previousDisplayRefreshMode = displayRefreshMode;
    final previousSampleRateHz = sampleRateHz;
    connectionStatus = ConnectionStatus.values.byName(
      data['connectionStatus'] as String? ?? connectionStatus.name,
    );
    probeType = data['probeType'] as String? ?? probeType;
    targetName = data['targetName'] as String? ?? targetName;
    state.connection.targetPackId =
        data['targetPackId'] as String? ?? targetPackId;
    state.connection.targetPartNumber =
        data['targetPartNumber'] as String? ??
        data['targetName'] as String? ??
        targetPartNumber;
    state.connection.targetPackLabel =
        data['targetPackLabel'] as String? ?? targetPackLabel;
    state.connection.targetPackMissing =
        data['targetPackMissing'] as bool? ?? targetPackMissing;
    final hasTargetCatalog =
        data.containsKey('targetCatalogRevision') &&
        data['targetCatalogRevision'] != targetCatalogRevision;
    state.connection.targetCatalogRevision =
        data['targetCatalogRevision'] as int? ?? targetCatalogRevision;
    swdClock = data['swdClock'] as String? ?? swdClock;
    serialNumber = data['serialNumber'] as String? ?? serialNumber;
    connectionKind = data['connectionKind'] as String? ?? connectionKind;
    if (data.containsKey('gatewayProtocolVersion')) {
      state.connection.gatewayProtocolVersion =
          data['gatewayProtocolVersion'] as int?;
    }
    if (data['remoteConfig'] case final Map config) {
      final values = Map<String, String>.from(config);
      if (values.entries.any(
        (entry) => remoteConfig[entry.key] != entry.value,
      )) {
        state.connection.advertisedCapabilities = null;
      }
      remoteConfig.addAll(values);
    }
    if (data.containsKey('connectionCapabilities')) {
      final capabilities = data['connectionCapabilities'];
      state.connection.advertisedCapabilities = capabilities is Map
          ? ConnectionCapabilities.fromJson(
              capabilities,
              fallback: ConnectionCapabilities.forConfiguration(
                connectionKind,
                remoteConfig,
              ),
            )
          : null;
    }
    symbolFile = data['symbolFile'] as String? ?? symbolFile;
    sampleRateHz = (data['sampleRateHz'] as num?)?.toDouble() ?? sampleRateHz;
    monitorRateHz =
        (data['monitorRateHz'] as num?)?.toDouble() ?? monitorRateHz;
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
            // Backend state includes captures held for the undo grace period.
            // A delayed echo must never bring a deleted row back into the UI.
            if (_removedWatchKeys.contains(item['key'])) return null;
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
                  ..historyStartSeconds =
                      (item['historyStartSeconds'] as num?)?.toDouble() ??
                      previousWatches[symbol.key]?.historyStartSeconds ??
                      0
                  ..readMode = WatchReadMode.parse(
                    item['readMode'],
                    sampling: item['sampling'] != false,
                  )
                  ..monitorRateHz = (item['monitorRateHz'] as num?)?.toDouble()
                  ..updatedAtMs =
                      (item['updatedAtMs'] as num?)?.toInt() ??
                      previousWatches[symbol.key]?.updatedAtMs
                  ..plotted = item['plotted'] == true
                  ..pinned =
                      item['pinned'] as bool? ??
                      previousWatches[symbol.key]?.pinned ??
                      false
                  ..value = _numericValue(
                    item['value'],
                    fallback: previousWatches[symbol.key]?.value ?? 0,
                  );
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

    if (data.containsKey('plotVisibilityBeforeIsolation')) {
      state.plot.visibilityBeforeIsolation =
          (data['plotVisibilityBeforeIsolation'] as Map?)?.cast<String, bool>();
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
    if (data['sourceProject'] case final Map project) {
      sourceProject.applyJson(Map<String, dynamic>.from(project));
      debugState.sourceRoot = sourceProject.sourceRoot;
    }
    if (data['sourceTask'] case final Map task) {
      sourceTask.applyJson(Map<String, dynamic>.from(task));
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
    final deletedWatchesInvalidated =
        hadDeletedWatches && previousSymbolRevision != _symbolRevision;
    if (deletedWatchesInvalidated && !_isDetachedRemote) _syncWatchesBackend();
    _emitState([
      if (hasConnectionState) signals.connection,
      if (hasTargetCatalog) signals.targetCatalog,
      if (hasSamplingState) signals.sampling,
      if (hasSymbolState) signals.symbols,
      if (hasWatchState ||
          deletedWatchesInvalidated ||
          hasPlotWatchSelection ||
          data.containsKey('connectionKind'))
        signals.watches,
      if (hasWatchState || hasElapsedState) signals.telemetry,
      if (hasPlotState || hasPlotHighlightState) signals.plot,
      if (hasPlotState) signals.plotControls,
      if (data.containsKey('logs')) signals.logs,
      if (hasAnalysisState) signals.analysis,
      if (hasDebugState) signals.debug,
      if (data['sourceProject'] is Map && !hasDebugState) signals.debug,
      if (hasSourceTools) signals.sourceTools,
      if (hasSourceWorkspace) signals.sourceWorkspace,
    ], sync: false);
  }
}
