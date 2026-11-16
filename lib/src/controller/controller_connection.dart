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

  double get samplingElapsedSeconds => _samplingClock.elapsedSeconds;
  int get samplingEpoch => state.acquisition.samplingEpoch;

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
