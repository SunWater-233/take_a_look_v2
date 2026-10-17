part of 'controller.dart';

extension TakeALookControllerWatches on TakeALookController {
  void clearSamples() {
    if (_dispatchCommand(ControllerCommand.clearSamples)) return;
    plotHistory.clear();
    state.acquisition.rawRecording = {};
    elapsedSeconds = 0;
    _resetSamplingElapsedClock();
    for (final watch in _watches) {
      watch.samples.clear();
      watch.totalSampleCount = 0;
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
    for (final symbol in selected) {
      final isAggregateMember = selectedRoots.any(
        (root) =>
            aggregateRootKeys.contains(root.key) &&
            (symbol.key == root.key || _isDescendantSymbol(symbol, root)),
      );
      _watches.add(
        WatchItem(
            symbol: symbol,
            color: seriesColors[_watches.length % seriesColors.length],
          )
          ..samplingEnabled = !isAggregateMember
          ..readMode = isAggregateMember ? WatchReadMode.monitor : mode
          ..plotted = !isAggregateMember && mode == WatchReadMode.capture,
      );
    }
    _selectedSymbols.clear();
    _configurePlotRetention();
    _syncWatchesBackend();
    _appendLog('已加入 ${selected.length} 个变量到变量监视列表。');
    _emitState([signals.symbols, signals.watches, signals.plot, signals.logs]);
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
    final previousLength = _watches.length;
    _watches.removeWhere((item) => removedKeys.contains(item.symbol.key));
    watchInputDrafts.removeWhere((key, _) => removedKeys.contains(key));
    compactExpandedWatches.removeAll(removedKeys);
    if (removedKeys.contains(compactWatchSelection)) {
      compactWatchSelection = null;
    }
    if (_watches.length == previousLength) return;
    if (removedKeys.contains(plotHighlightedWatchKey)) {
      state.plot.highlightedWatchKey = null;
    }
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

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
    _watches.clear();
    watchInputDrafts.clear();
    compactExpandedWatches.clear();
    compactWatchSelection = null;
    state.plot.highlightedWatchKey = null;
    _syncWatchesBackend();
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
    watch.samplingEnabled = value;
    watch.plotted = value;
    _syncWatchesBackend();
    _emitState([signals.watches, signals.plot]);
  }

  bool usesDevicePush(WatchItem watch) =>
      watch.symbol.dataSource == 'rtt' || (rttEnabled && rttProtocol == 'plus');

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

  void writeWatch(String key, String input) {
    watchInputDrafts[key] = input;
    if (_dispatchCommand(ControllerCommand.writeWatch, {
      'key': key,
      'value': input,
    })) {
      return;
    }
    final value = double.tryParse(input);
    final watch = _watchByKey(key);
    if (value == null || watch == null) {
      _appendLog('变量写入失败：$input 不是有效数值。');
    } else {
      watch.value = value;
      watch.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      _appendLog('${watch.symbol.name} 已写入 $input，并完成回读验证。');
    }
    _emitState([signals.telemetry, signals.plot, signals.logs]);
  }
}

bool _isDescendantSymbol(SymbolItem candidate, SymbolItem root) {
  if (candidate.source != root.source || candidate.key == root.key) {
    return false;
  }
  return candidate.name.startsWith('${root.name}.') ||
      candidate.name.startsWith('${root.name}[');
}
