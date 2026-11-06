part of 'controller.dart';

extension TakeALookControllerWatches on TakeALookController {
  void clearSamples() {
    if (_dispatchCommand(ControllerCommand.clearSamples)) return;
    plotHistory.clear();
    state.acquisition.rawRecording = {};
    elapsedSeconds = 0;
    _resetSamplingElapsedClock();
    for (final watch in _allRetainedWatches) {
      watch.samples.clear();
      watch.totalSampleCount = 0;
      watch.historyStartSeconds = 0;
    }
    _frozenPlotSamples.clear();
    if (plottingPaused || !followLatest) _frozenPlotEndSeconds = 0;
    _appendLog('当前采样缓存已清空。');
    _emitState([
      signals.sampling,
      signals.telemetry,
      signals.plot,
      signals.logs,
    ]);
    signals.telemetrySync.emit();
  }

  void clearLogs() {
    if (_dispatchRemote(ControllerCommand.clearLogs)) return;
    _logs.clear();
    _emitState([signals.logs]);
  }

  void resetTarget({required bool halt}) {
    if (_dispatchCommand(ControllerCommand.resetTarget, halt)) return;
    _appendLog(halt ? '目标已复位并暂停。' : '目标已复位并运行。');
    _emitState([signals.logs]);
  }

  Future<void> exportCsv() async {
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.exportCsv);
      return;
    }
    final picker = csvExportPathPicker;
    if (picker != null) {
      final path = await picker();
      if (path == null || path.isEmpty) return;
      if (_dispatchCommand(ControllerCommand.exportCsv, path)) return;
    }
    _appendLog('导出原始 CSV 任务已创建。');
    _emitState([signals.logs]);
  }

  void toggleSymbol(String key) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.toggleSymbol, key)) {
      return;
    }
    if (!_selectedSymbols.add(key)) {
      _selectedSymbols.remove(key);
    }
    _emitState([signals.symbols]);
  }

  void selectSymbols(Iterable<String> keys) {
    final selected = keys.toSet();
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.selectSymbols, selected.toList())) {
      return;
    }
    _selectedSymbols
      ..clear()
      ..addAll(selected);
    _emitState([signals.symbols]);
  }

  void activateSymbol(String key) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.activateSymbol, key)) {
      return;
    }
    selectSymbols([key]);
    addSelectedToWatch();
  }

  void addSelectedToWatch({WatchReadMode mode = WatchReadMode.capture}) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.addSelectedToWatch, mode.name)) {
      return;
    }
    final existing = _watches.map((item) => item.symbol.key).toSet();
    final selectedRoots = _symbols
        .where((item) => _selectedSymbols.contains(item.key))
        .toList();
    final aggregateRootKeys = <String>{};
    final selectedKeys = <String>{};
    for (final root in selectedRoots) {
      selectedKeys.add(root.key);
      for (final candidate in _symbols) {
        if (!_isDescendantSymbol(candidate, root)) continue;
        aggregateRootKeys.add(root.key);
        selectedKeys.add(candidate.key);
      }
    }
    final selected = _symbols
        .where((item) => selectedKeys.contains(item.key))
        .where((item) => !existing.contains(item.key))
        .toList();
    if (selected.isNotEmpty) _watchRegistry.clearRedos();
    for (final symbol in selected) {
      final isAggregateMember = selectedRoots.any(
        (root) =>
            aggregateRootKeys.contains(root.key) &&
            (symbol.key == root.key || _isDescendantSymbol(symbol, root)),
      );
      _insertWatchSymbol(
        symbol,
        mode: isAggregateMember ? WatchReadMode.monitor : mode,
      );
    }
    _selectedSymbols.clear();
    compactExpandedWatches.addAll(aggregateRootKeys);
    _configurePlotRetention();
    _syncWatchesBackend();
    _appendLog('已加入 ${selected.length} 个变量到变量监视列表。');
    _emitState([signals.symbols, signals.watches, signals.plot, signals.logs]);
  }

  void _insertWatchSymbol(
    SymbolItem symbol, {
    required WatchReadMode mode,
    int? index,
  }) {
    // Re-adding a retained variable is equivalent to undoing its removal.
    final retained = _watchRegistry.takeDeleted(symbol.key);
    final previouslyRemoved = _removedWatchKeys.remove(symbol.key);
    if (retained != null) {
      _restoreDeletedWatch(retained, index: index ?? _watches.length);
      return;
    }
    final watch =
        WatchItem(
            symbol: symbol,
            color: seriesColors[_watches.length % seriesColors.length],
          )
          ..historyStartSeconds = previouslyRemoved ? elapsedSeconds + 1e-9 : 0
          ..readMode = mode;
    _watches.insert(index ?? _watches.length, watch);
    final previous = state.plot.visibilityBeforeIsolation;
    if (previous != null) {
      previous.putIfAbsent(symbol.key, () => watch.plotted);
      watch.plotted = false;
    }
  }

  Iterable<SymbolItem> _watchMemberSymbols(String key) {
    final root = _watchByKey(key)?.symbol;
    if (root == null) return const [];
    return _symbols.where((symbol) => _isDescendantSymbol(symbol, root));
  }

  bool isAggregateWatch(String key) => _watchMemberSymbols(key).isNotEmpty;

  bool canRestoreWatchMembers(String key) {
    final existing = _watches.map((watch) => watch.symbol.key).toSet();
    return _watchMemberSymbols(
      key,
    ).any((symbol) => !existing.contains(symbol.key));
  }

  void restoreWatchMembers(String key) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.restoreWatchMembers, key)) {
      return;
    }
    if (!canRestoreWatchMembers(key)) return;
    _watchRegistry.clearRedos();
    var index = _watches.indexWhere((watch) => watch.symbol.key == key) + 1;
    for (final symbol in _watchMemberSymbols(key)) {
      final existingIndex = _watches.indexWhere(
        (watch) => watch.symbol.key == symbol.key,
      );
      if (existingIndex >= 0) {
        index = existingIndex + 1;
      } else {
        _insertWatchSymbol(symbol, mode: WatchReadMode.monitor, index: index++);
      }
    }
    _configurePlotRetention();
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
    signals.telemetrySync.emit();
  }

  void removeWatch(String key) {
    removeWatches([key]);
  }

  void removeWatches(Iterable<String> keys) {
    final removedKeys = keys.toSet();
    if (_isDetachedRemote &&
        _dispatchRemote(
          ControllerCommand.removeWatches,
          removedKeys.toList(),
        )) {
      return;
    }
    final roots = _watches
        .where((watch) => removedKeys.contains(watch.symbol.key))
        .map((watch) => watch.symbol)
        .toList();
    for (final watch in _watches) {
      if (removedKeys.contains(watch.symbol.key)) continue;
      if (roots.any((root) => _isDescendantSymbol(watch.symbol, root))) {
        removedKeys.add(watch.symbol.key);
      }
    }
    if (!_watchRegistry.remove(
      removedKeys,
      samplingPaused: samplingPaused,
      highlightedKey: plotHighlightedWatchKey,
    )) {
      return;
    }
    if (removedKeys.contains(plotHighlightedWatchKey)) {
      state.plot.highlightedWatchKey = null;
    }
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void undoWatchDeletion() {
    if (_dispatchRemote(ControllerCommand.undoWatchDeletion)) return;
    if (!_watchRegistry.canUndo) return;
    for (final entry in _watchRegistry.undo()) {
      _restoreWatchHighlight(entry);
    }
    _configurePlotRetention();
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
    signals.telemetrySync.emit();
  }

  void redoWatchDeletion() {
    if (_dispatchRemote(ControllerCommand.redoWatchDeletion)) return;
    if (!_watchRegistry.redo(
      samplingPaused: samplingPaused,
      highlightedKey: plotHighlightedWatchKey,
    )) {
      return;
    }
    if (!_watches.any((watch) => watch.symbol.key == plotHighlightedWatchKey)) {
      state.plot.highlightedWatchKey = null;
    }
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void _restoreDeletedWatch(DeletedWatch entry, {int? index}) {
    _watchRegistry.restore(entry, index: index);
    _restoreWatchHighlight(entry);
  }

  void _restoreWatchHighlight(DeletedWatch entry) {
    if (entry.highlighted) {
      state.plot.highlightedWatchKey = entry.watch.symbol.key;
      state.plot.watchSelectionRevision++;
    }
  }

  void _clearWatchDeletionHistory() => _watchRegistry.clearHistory();

  void reorderWatch(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _watches.length) return;
    if (newIndex < 0 || newIndex >= _watches.length) return;
    if (oldIndex == newIndex) return;
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.reorderWatch, {
          'oldIndex': oldIndex,
          'newIndex': newIndex,
        })) {
      return;
    }
    final watch = _watches.removeAt(oldIndex);
    _watches.insert(newIndex, watch);
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void clearWatches() {
    if (_isDetachedRemote && _dispatchRemote(ControllerCommand.clearWatches)) {
      return;
    }
    removeWatches(_watches.map((watch) => watch.symbol.key));
    _appendLog('已清空实时调参列表。');
    _emitState([signals.watches, signals.plot, signals.logs]);
  }

  void toggleWatchSampling(String key, bool value) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.toggleWatchSampling, {
          'key': key,
          'value': value,
        })) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch == null || watch.samplingEnabled == value) return;
    setWatchReadMode(
      key,
      value ? WatchReadMode.capture : WatchReadMode.monitor,
    );
  }

  bool usesDevicePush(WatchItem watch) =>
      watch.symbol.dataSource == 'rtt' || (rttEnabled && rttProtocol == 'plus');

  bool isWatchMonitorActive(WatchItem watch) =>
      usesDevicePush(watch) ||
      watch.pinned ||
      !_watchMonitorVisibilityKnown ||
      _watchMonitorScopes.values.any((keys) => keys.contains(watch.symbol.key));

  /// Once the workspace exists, no visible inspectors means no memory polling.
  /// Headless controllers retain their previous policy until visibility is known.
  void initializeWatchMonitorVisibility() {
    if (_disposed || _watchMonitorVisibilityKnown) return;
    _watchMonitorVisibilityKnown = true;
    _scheduleWatchMonitorSync();
  }

  /// Union the members displayed by all open inspectors, including detached ones.
  /// This is a temporary read policy; it never changes a variable's chosen mode.
  void setWatchMonitorScope(String scope, Iterable<String>? keys) {
    if (_disposed) return;
    final next = keys?.toSet();
    if (next == null
        ? !_watchMonitorScopes.containsKey(scope)
        : setEquals(_watchMonitorScopes[scope], next)) {
      return;
    }
    if (next == null) {
      _watchMonitorScopes.remove(scope);
    } else {
      _watchMonitorScopes[scope] = next;
      _watchMonitorVisibilityKnown = true;
    }
    if (_isDetachedRemote) {
      _pendingRemoteMonitorScopes[scope] = next;
    }
    _scheduleWatchMonitorSync();
  }

  void removeWatchMonitorScopesForWindow(String windowId) {
    final prefix = 'window:$windowId:';
    final scopes = _watchMonitorScopes.keys
        .where((scope) => scope.startsWith(prefix))
        .toList();
    for (final scope in scopes) {
      setWatchMonitorScope(scope, null);
    }
  }

  Set<String> _monitorEnabledKeys() => {
    for (final watch in acquisitionWatches)
      if (watch.readMode == WatchReadMode.monitor &&
          isWatchMonitorActive(watch))
        watch.symbol.key,
  };

  void _scheduleWatchMonitorSync() {
    if (_watchMonitorSyncPending || _disposed) return;
    _watchMonitorSyncPending = true;
    scheduleMicrotask(() {
      _watchMonitorSyncPending = false;
      if (_disposed) return;
      if (_isDetachedRemote) {
        final pending = Map<String, Set<String>?>.of(
          _pendingRemoteMonitorScopes,
        );
        _pendingRemoteMonitorScopes.clear();
        for (final entry in pending.entries) {
          _dispatchRemote(ControllerCommand.setWatchMonitorScope, {
            'scope': entry.key,
            'keys': entry.value?.toList(),
          });
        }
        return;
      }
      if (_restoringProject || backendCommand == null) return;
      final enabled = _monitorEnabledKeys();
      if (setEquals(_lastMonitorEnabledKeys, enabled)) return;
      _lastMonitorEnabledKeys = enabled;
      unawaited(
        backendCommand!(ControllerCommand.setMonitorVisibility, {
          'enabledKeys': enabled.toList(),
        }),
      );
    });
  }

  void setWatchPinned(String key, bool value) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.setWatchPinned, {
          'key': key,
          'value': value,
        })) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch == null || watch.pinned == value) return;
    watch.pinned = value;
    _scheduleWatchMonitorSync();
    _emitState([signals.watches]);
  }

  double monitorRateFor(WatchItem watch) =>
      watch.monitorRateHz ?? monitorRateHz;

  void setWatchReadMode(String key, WatchReadMode mode) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.setWatchReadMode, {
          'key': key,
          'mode': mode.name,
        })) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch == null || watch.readMode == mode) return;
    watch.readMode = mode;
    watch.plotted = mode == WatchReadMode.capture;
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void setWatchMonitorRate(String key, double? value) {
    if (value != null && (!value.isFinite || value < 0.5 || value > 10)) return;
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.setWatchMonitorRate, {
          'key': key,
          'rateHz': value,
        })) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch == null || watch.monitorRateHz == value) return;
    watch.monitorRateHz = value;
    _syncWatchesBackend();
    _emitState([signals.watches]);
  }

  void readWatch(String key) {
    if (_dispatchCommand(ControllerCommand.readWatch, key)) return;
    final watch = _watchByKey(key);
    if (watch == null || connectionStatus != ConnectionStatus.connected) return;
    watch.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    _emitTelemetry();
  }

  void toggleWatchPlot(String key, bool value) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.toggleWatchPlot, {
          'key': key,
          'value': value,
        })) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch != null) watch.plotted = value && watch.samplingEnabled;
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void setWatchColor(String key, Color color) {
    setWatchColors([key], color);
  }

  void setWatchColors(Iterable<String> keys, Color color) {
    final colorKeys = keys.toSet();
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.setWatchColors, {
          'keys': colorKeys.toList(),
          'color': color.toARGB32(),
        })) {
      return;
    }
    var changed = false;
    for (final watch in _watches) {
      if (colorKeys.contains(watch.symbol.key) && watch.color != color) {
        watch.color = color;
        changed = true;
      }
    }
    if (!changed) return;
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void setOnlyWatchesPlotted(Iterable<String> keys) {
    final plottedKeys = keys.toSet();
    _setWatchPlotStates(
      ControllerCommand.setOnlyWatchesPlotted,
      plottedKeys.toList(),
      (watch) => plottedKeys.contains(watch.symbol.key),
    );
  }

  bool get watchPlotsIsolated => state.plot.visibilityBeforeIsolation != null;

  void isolateWatchPlots(Iterable<String> keys) {
    final isolatedKeys = keys.toSet();
    if (_isDetachedRemote &&
        _dispatchRemote(
          ControllerCommand.isolateWatchPlots,
          isolatedKeys.toList(),
        )) {
      return;
    }
    if (!_watches.any(
      (watch) =>
          isolatedKeys.contains(watch.symbol.key) && watch.samplingEnabled,
    )) {
      return;
    }
    final previous = state.plot.visibilityBeforeIsolation ??= {};
    for (final watch in _watches) {
      previous.putIfAbsent(watch.symbol.key, () => watch.plotted);
      watch.plotted =
          watch.samplingEnabled && isolatedKeys.contains(watch.symbol.key);
    }
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void exitWatchPlotIsolation() {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.exitWatchPlotIsolation)) {
      return;
    }
    final previous = state.plot.visibilityBeforeIsolation;
    if (previous == null) return;
    state.plot.visibilityBeforeIsolation = null;
    // Retained deletions can be restored later through Undo as well.
    for (final watch in _allRetainedWatches) {
      final plotted = previous[watch.symbol.key];
      if (plotted != null) watch.plotted = plotted && watch.samplingEnabled;
    }
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  void setAllWatchesPlotted(bool plotted) {
    _setWatchPlotStates(
      ControllerCommand.setAllWatchesPlotted,
      plotted,
      (_) => plotted,
    );
  }

  void invertWatchPlots(Iterable<String> keys) {
    final invertedKeys = keys.toSet();
    _setWatchPlotStates(
      ControllerCommand.invertWatchPlots,
      invertedKeys.toList(),
      (watch) => invertedKeys.contains(watch.symbol.key)
          ? !watch.plotted
          : watch.plotted,
    );
  }

  void _setWatchPlotStates(
    ControllerCommand remoteCommand,
    Object? remoteArguments,
    bool Function(WatchItem watch) plottedForWatch,
  ) {
    if (_isDetachedRemote && _dispatchRemote(remoteCommand, remoteArguments)) {
      return;
    }
    var changed = false;
    for (final watch in _watches) {
      final plotted = watch.samplingEnabled && plottedForWatch(watch);
      if (watch.plotted != plotted) {
        watch.plotted = plotted;
        changed = true;
      }
    }
    if (!changed) return;
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  Future<bool> writeWatch(String key, String input) async {
    watchInputDrafts[key] = input;
    try {
      final sender = backendCommand ?? remoteCommand;
      if (sender != null) {
        await sender(ControllerCommand.writeWatch, {
          'key': key,
          'value': input,
        });
        return true;
      }
      final value = double.tryParse(input);
      final watch = _watchByKey(key);
      if (value == null || !value.isFinite || watch == null) {
        throw const BackendException('invalid_value', '请输入有效数值。');
      }
      watch.value = value;
      watch.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      _appendLog('${watch.symbol.name} 已写入 $input，并完成回读验证。');
      _emitState([signals.telemetry, signals.plot, signals.logs]);
      return true;
    } catch (error) {
      if (!_disposed) {
        applyBackendEvent(BackendEventType.error, {
          'code': error is BackendException ? error.code : 'write_failed',
          'operation': 'writeWatch',
          'message': error is BackendException ? error.message : '变量写入失败。',
          'details': error is BackendException
              ? error.details
              : error.toString(),
        });
      }
      return false;
    }
  }
}

bool _isDescendantSymbol(SymbolItem candidate, SymbolItem root) {
  if (candidate.source != root.source || candidate.key == root.key) {
    return false;
  }
  return candidate.name.startsWith('${root.name}.') ||
      candidate.name.startsWith('${root.name}[');
}
