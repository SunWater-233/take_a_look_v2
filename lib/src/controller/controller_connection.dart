part of 'controller.dart';

extension TakeALookControllerConnection on TakeALookController {
  void setMonitorRate(double value) {
    if (!value.isFinite || value < 0.5 || value > 10) return;
    if (_dispatchCommand(ControllerCommand.setMonitorRate, value)) return;
    monitorRateHz = value;
    _emitState([signals.sampling]);
  }

  void setUiScale(double value) {
    if (_dispatchRemote(ControllerCommand.setUiScale, value)) return;
    final normalized = value.clamp(0.5, 2).toDouble();
    if ((normalized - _uiScale.value).abs() < 0.001) return;
    _uiScale.value = normalized;
    _appendLog('界面缩放已设置为 ${(normalized * 100).round()}%。');
    _emitState([signals.logs]);
  }

  String get connectionLabel => switch (connectionStatus) {
    ConnectionStatus.disconnected => '连接探针',
    ConnectionStatus.connecting => '连接中...',
    ConnectionStatus.connected => '断开探针',
  };

  String get sampleRateLabel {
    if (sampleRateHz >= 1000) {
      return '${(sampleRateHz / 1000).toStringAsFixed(sampleRateHz % 1000 == 0 ? 0 : 1)} kHz';
    }
    return '${sampleRateHz.toStringAsFixed(0)} Hz';
  }

  String get displayRefreshLabel => switch (displayRefreshMode) {
    'standard' => '标准模式（60 Hz）',
    'high' => '高频模式（120 Hz）',
    _ => '实时模式（自适应）',
  };

  double get plotRefreshRateHz => switch (displayRefreshMode) {
    'standard' => TakeALookController.standardPlotRefreshRateHz,
    'high' => TakeALookController.highPlotRefreshRateHz,
    _ =>
      sampleRateHz
          .clamp(1, TakeALookController.maxRealtimePlotRefreshRateHz)
          .toDouble(),
  };

  double get samplingElapsedSeconds =>
      _samplingElapsedBaseSeconds +
      _samplingElapsedStopwatch.elapsedMicroseconds /
          Duration.microsecondsPerSecond;

  String get elapsedLabel {
    final totalCentiseconds = (samplingElapsedSeconds * 100).round();
    final totalSeconds = totalCentiseconds ~/ 100;
    final centiseconds = totalCentiseconds % 100;
    final totalMinutes = totalSeconds ~/ 60;
    final hours = totalSeconds ~/ 3600;
    final minutes = totalMinutes % 60;
    final seconds = totalSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    if (hours > 0) return '${two(hours)}:${two(minutes)}';
    if (totalMinutes > 0) {
      return '${two(minutes)}:${two(seconds)}:${two(centiseconds)}';
    }
    return '${two(seconds)}:${two(centiseconds)}';
  }

  Future<void> toggleConnection() async {
    if (_restoringProject) return;
    if (_dispatchCommand(ControllerCommand.toggleConnection)) return;
    if (connectionStatus == ConnectionStatus.connected) {
      connectionStatus = ConnectionStatus.disconnected;
      samplingPaused = false;
      _reconcileSamplingClock();
      _resetPlotRefreshSchedule();
      _appendLog('已断开 pyOCD 调试探针。');
      _emitState([signals.connection, signals.sampling, signals.logs]);
      return;
    }
    if (connectionStatus == ConnectionStatus.connecting) return;
    connectionStatus = ConnectionStatus.connecting;
    _appendLog('开始连接 pyOCD：正在枚举探针并初始化目标。');
    _emitState([signals.connection, signals.logs]);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (_disposed) return;
    connectionStatus = ConnectionStatus.connected;
    samplingPaused = true;
    _reconcileSamplingClock();
    _resetPlotRefreshSchedule();
    _appendLog('已连接 pyOCD：target=$targetName，SWD=$swdClock。');
    _emitState([signals.connection, signals.logs]);
  }

  void loadDemoSymbols() {
    if (_dispatchRemote(ControllerCommand.loadSymbols)) return;
    symbolFile = 'motor_control_release.axf';
    _replaceSymbols(demoSymbols);
    _selectedSymbols.clear();
    _appendLog('已读取符号文件：$symbolFile，变量符号 ${_symbols.length} 个。');
    _emitState([signals.symbols, signals.logs]);
  }

  void _replaceSymbols(Iterable<SymbolItem> symbols) {
    final next = symbols.toList(growable: false);
    if (_symbols.length == next.length) {
      var unchanged = true;
      for (var index = 0; index < next.length; index += 1) {
        final current = _symbols[index];
        final replacement = next[index];
        if (current.source != replacement.source ||
            current.name != replacement.name ||
            current.address != replacement.address ||
            current.type != replacement.type ||
            current.size != replacement.size ||
            current.section != replacement.section ||
            current.key != replacement.key ||
            current.writable != replacement.writable ||
            current.dataSource != replacement.dataSource) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return;
    }
    final removedNames = {
      for (final symbol in _symbols)
        if (_removedWatchKeys.contains(symbol.key))
          (symbol.source, symbol.name),
    };
    // An undo entry belongs to one symbol table/recording, never a new binary.
    _clearWatchDeletionHistory();
    _removedWatchKeys.addAll(
      next
          .where(
            (symbol) => removedNames.contains((symbol.source, symbol.name)),
          )
          .map((symbol) => symbol.key),
    );
    _symbols
      ..clear()
      ..addAll(next);
    _expandedSymbolTreeNodes.clear();
    _symbolRevision += 1;
  }

  Future<void> chooseSymbolFile() async {
    if (isSymbolLoading || _pickingSymbolFile) return;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.loadSymbols);
      return;
    }
    final picker = symbolFilePicker;
    if (picker == null) {
      loadDemoSymbols();
      return;
    }
    _pickingSymbolFile = true;
    try {
      final path = await picker();
      if (_disposed || path == null || path.isEmpty) return;
      unawaited(loadSymbolsFromPath(path));
    } finally {
      _pickingSymbolFile = false;
    }
  }

  Future<void> loadSymbolsFromPath(String path) async {
    if (_disposed || isSymbolLoading || path.isEmpty) return;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.loadSymbols, path);
      return;
    }
    final sender = backendCommand;
    if (sender == null) {
      loadDemoSymbols();
      return;
    }
    final startedAt = DateTime.now();
    final loadId = '${startedAt.microsecondsSinceEpoch}-${_nextSymbolLoadId++}';
    lastBackendError = null;
    _setSymbolLoad(
      SymbolLoadProgress(loadId: loadId, path: path, startedAt: startedAt),
    );
    try {
      await sender(ControllerCommand.loadSymbols, {
        'path': path,
        'loadId': loadId,
      });
      if (_disposed || state.symbolLoad?.loadId != loadId) return;
      _setSymbolLoad(
        state.symbolLoad!.copyWith(
          phase: 'ui',
          current: 0,
          total: 0,
          status: SymbolLoadStatus.complete,
          finishedAt: DateTime.now(),
        ),
      );
    } catch (error) {
      if (_disposed || state.symbolLoad?.loadId != loadId) return;
      _setSymbolLoad(
        state.symbolLoad!.copyWith(
          status: SymbolLoadStatus.failed,
          finishedAt: DateTime.now(),
        ),
      );
      final failure = error is BackendException
          ? error
          : BackendException(
              'symbol_load_failed',
              '无法读取 ELF 文件。',
              error.toString(),
            );
      // A process exit is also reported globally by the client.
      if (lastBackendError?['code'] != failure.code) {
        applyBackendEvent(BackendEventType.error, {
          'code': failure.code,
          'operation': 'loadSymbols',
          'message': failure.message,
          if (failure.details != null) 'details': failure.details,
        });
      }
    }
  }

  void _setSymbolLoad(SymbolLoadProgress progress) {
    final wasLoading = isSymbolLoading;
    state.symbolLoad = progress;
    _touchSnapshotFields(['symbolLoad']);
    signals.symbolLoad.emit();
    if (wasLoading != isSymbolLoading) signals.symbols.emit();
  }

  void applySymbolLoadProgress(Map<String, dynamic> payload) {
    final current = state.symbolLoad;
    if (_disposed ||
        current == null ||
        !current.isLoading ||
        payload['loadId'] != current.loadId) {
      return;
    }
    final phase = payload['phase'];
    if (phase is! String ||
        !const {
          'check',
          'debug',
          'scan',
          'variables',
          'source',
          'ui',
        }.contains(phase)) {
      return;
    }
    _setSymbolLoad(
      current.copyWith(
        phase: phase,
        current: math.max(0, (payload['current'] as num?)?.toInt() ?? 0),
        total: math.max(0, (payload['total'] as num?)?.toInt() ?? 0),
      ),
    );
  }

  void applySymbolLoadSnapshot(Map<String, dynamic> payload) {
    if (_disposed) return;
    final next = SymbolLoadProgress.fromJson(payload);
    final current = state.symbolLoad;
    if (current != null &&
        (next.startedAt.isBefore(current.startedAt) ||
            (next.loadId == current.loadId &&
                next.revision <= current.revision))) {
      return;
    }
    _setSymbolLoad(next);
  }

  void refreshSymbols() {
    if (symbolFile.isEmpty || isSymbolLoading) return;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.loadSymbols, symbolFile);
      return;
    }
    loadSymbolsFromPath(symbolFile);
  }

  void setSampleRate(double value) {
    if (_dispatchCommand(ControllerCommand.setSampleRate, value)) return;
    sampleRateHz = value;
    if (displayRefreshMode == 'realtime') _resetPlotRefreshSchedule();
    _appendLog('采样率已设置为 $sampleRateLabel。');
    _emitState([signals.sampling, signals.logs]);
  }

  void setDisplayRefreshMode(String mode) {
    if (!const {'standard', 'high', 'realtime'}.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', '未知的绘图刷新率模式');
    }
    if (_dispatchRemote(ControllerCommand.setDisplayRefreshMode, mode)) return;
    if (displayRefreshMode == mode) return;
    displayRefreshMode = mode;
    _resetPlotRefreshSchedule();
    _appendLog('绘图刷新率已切换为$displayRefreshLabel。');
    _emitState([signals.plot, signals.logs]);
  }

  void setRttSampleRate(double value) {
    if (_dispatchCommand(ControllerCommand.setRttSampleRate, value)) return;
    rttSampleRateHz = value;
    _emitState([signals.sampling]);
  }

  void setProbeType(String value) {
    if (_dispatchCommand(ControllerCommand.setProbeType, value)) return;
    probeType = value;
    _emitState([signals.connection]);
  }

  void setTargetName(String value) {
    if (_dispatchCommand(ControllerCommand.setTargetName, value)) return;
    targetName = value;
    state.connection.targetPackId = '';
    state.connection.targetPartNumber = value;
    state.connection.targetPackLabel = '内置';
    state.connection.targetPackMissing = false;
    _emitState([signals.connection]);
  }

  void setSwdClock(String value) {
    if (_dispatchCommand(ControllerCommand.setSwdClock, value)) return;
    swdClock = value;
    _emitState([signals.connection]);
  }

  void setSerialNumber(String value) {
    if (_dispatchCommand(ControllerCommand.setSerialNumber, value)) return;
    if (serialNumber == value) return;
    serialNumber = value;
    _emitState([signals.connection]);
  }

  void setConnectionKind(String value) {
    if (connectionStatus != ConnectionStatus.disconnected) return;
    if (!const {'local', 'ember', 'emberGdb', 'gdb'}.contains(value)) return;
    if (_dispatchCommand(ControllerCommand.setConnectionKind, value)) return;
    connectionKind = value;
    _emitState([signals.connection, signals.watches]);
  }

  void setRemoteConfig(Map<String, String> values) {
    if (connectionStatus != ConnectionStatus.disconnected) return;
    if (_dispatchCommand(ControllerCommand.setRemoteConfig, values)) return;
    state.connection.advertisedCapabilities = null;
    remoteConfig.addAll(values);
    _emitState([signals.connection, signals.watches, signals.debug]);
  }

  Future<JsonObject> requestEmber(
    String operation, [
    JsonObject arguments = const {},
  ]) async {
    final request = emberRequest;
    if (request == null) {
      throw const BackendException('backend_unavailable', '请启动本机硬件后端后再配对手机。');
    }
    if (const {'pair', 'forget'}.contains(operation) &&
        connectionStatus != ConnectionStatus.disconnected) {
      throw const BackendException('already_connected', '请先断开目标连接，再管理手机配对。');
    }
    return request(operation, arguments);
  }

  void toggleSampling() {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.toggleSampling)) {
      return;
    }
    final sender = backendCommand;
    samplingPaused = !samplingPaused;
    _reconcileSamplingClock();
    if (sender != null) {
      unawaited(sender(ControllerCommand.setSamplingPaused, samplingPaused));
      _emitState([signals.sampling]);
      return;
    }
    _appendLog(samplingPaused ? '采样已暂停。' : '采样已继续。');
    _emitState([signals.sampling, signals.logs]);
  }
}
