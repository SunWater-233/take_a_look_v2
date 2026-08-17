import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'demo_data.dart';
import 'models.dart';

export 'demo_data.dart';

part 'controller_snapshot.dart';

typedef RemoteCommand = Future<void> Function(String method, Object? arguments);
typedef BackendCommand =
    Future<void> Function(String method, Object? arguments);
typedef PathPicker = Future<String?> Function();

class _ControllerSignal extends ChangeNotifier {
  void emit() => notifyListeners();
}

class TakeALookController extends ChangeNotifier {
  TakeALookController({
    this.remoteCommand,
    this.backendCommand,
    this.symbolFilePicker,
    this.csvExportPathPicker,
  }) {
    _logs.add(LogEntry('UI 已从 .ui 文件加载，pyOCD 内存读写后端已就绪。'));
    _logs.add(LogEntry('读取 .elf / .axf 后，可从符号层级中加入变量到实时调参列表。'));
    if (remoteCommand == null && backendCommand == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 33), _tick);
    }
  }

  final RemoteCommand? remoteCommand;
  final BackendCommand? backendCommand;
  final PathPicker? symbolFilePicker;
  final PathPicker? csvExportPathPicker;
  final List<SymbolItem> _symbols = <SymbolItem>[];
  final List<WatchItem> _watches = <WatchItem>[];
  final List<LogEntry> _logs = <LogEntry>[];
  final Set<String> _selectedSymbols = <String>{};
  Timer? _ticker;
  bool _disposed = false;
  double _phase = 0;
  double? _frozenPlotEndSeconds;
  final Map<String, List<Offset>> _frozenPlotSamples = <String, List<Offset>>{};
  DateTime? _lastPerformanceLogAt;
  final ValueNotifier<double> _uiScale = ValueNotifier<double>(1);
  final _ControllerSignal _connectionChanges = _ControllerSignal();
  final _ControllerSignal _samplingChanges = _ControllerSignal();
  final _ControllerSignal _symbolChanges = _ControllerSignal();
  final _ControllerSignal _watchChanges = _ControllerSignal();
  final _ControllerSignal _telemetryChanges = _ControllerSignal();
  final _ControllerSignal _plotChanges = _ControllerSignal();
  final _ControllerSignal _logChanges = _ControllerSignal();
  final _ControllerSignal _stateSyncChanges = _ControllerSignal();
  final _ControllerSignal _telemetrySyncChanges = _ControllerSignal();

  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;
  String probeType = '自动发现任意探针';
  String targetName = 'auto';
  String swdClock = '4 MHz';
  String serialNumber = '';
  String symbolFile = '';
  double sampleRateHz = 50;
  double rttSampleRateHz = 1000;
  double elapsedSeconds = 0;
  bool samplingPaused = false;
  bool plottingPaused = false;
  bool rttEnabled = false;
  String rttProtocol = 'normal';
  bool followLatest = true;
  Map<String, dynamic> performanceStats = <String, dynamic>{};
  Map<String, dynamic>? lastBackendError;

  List<SymbolItem> get symbols => List.unmodifiable(_symbols);
  List<WatchItem> get watches => List.unmodifiable(_watches);
  List<LogEntry> get logs => List.unmodifiable(_logs);
  Set<String> get selectedSymbols => Set.unmodifiable(_selectedSymbols);
  double get uiScale => _uiScale.value;
  ValueListenable<double> get uiScaleListenable => _uiScale;
  Listenable get connectionChanges => _connectionChanges;
  Listenable get samplingChanges => _samplingChanges;
  Listenable get symbolChanges => _symbolChanges;
  Listenable get watchChanges => _watchChanges;
  Listenable get telemetryChanges => _telemetryChanges;
  Listenable get plotChanges => _plotChanges;
  Listenable get logChanges => _logChanges;
  Listenable get stateSyncChanges => _stateSyncChanges;
  Listenable get telemetrySyncChanges => _telemetrySyncChanges;
  double get plotWindowEndSeconds => plottingPaused || !followLatest
      ? (_frozenPlotEndSeconds ?? elapsedSeconds)
      : elapsedSeconds;
  Iterable<Offset> plotSamplesFor(WatchItem watch) {
    if (!plottingPaused && followLatest) return watch.samples;
    return _frozenPlotSamples[watch.symbol.key] ?? watch.samples;
  }

  void setUiScale(double value) {
    if (_dispatchRemote('setUiScale', value)) return;
    final normalized = value.clamp(0.5, 2).toDouble();
    if ((normalized - _uiScale.value).abs() < 0.001) return;
    _uiScale.value = normalized;
    _appendLog('界面缩放已设置为 ${(normalized * 100).round()}%。');
    _emitState([_logChanges]);
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

  String get elapsedLabel {
    final totalCentiseconds = (elapsedSeconds * 100).round();
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
    if (_dispatchCommand('toggleConnection')) return;
    if (connectionStatus == ConnectionStatus.connected) {
      connectionStatus = ConnectionStatus.disconnected;
      samplingPaused = false;
      _appendLog('已断开 pyOCD 调试探针。');
      _emitState([_connectionChanges, _samplingChanges, _logChanges]);
      return;
    }
    if (connectionStatus == ConnectionStatus.connecting) return;
    connectionStatus = ConnectionStatus.connecting;
    _appendLog('开始连接 pyOCD：正在枚举探针并初始化目标。');
    _emitState([_connectionChanges, _logChanges]);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (_disposed) return;
    connectionStatus = ConnectionStatus.connected;
    _appendLog('已连接 pyOCD：target=$targetName，SWD=$swdClock。');
    _emitState([_connectionChanges, _logChanges]);
  }

  void loadDemoSymbols() {
    if (_dispatchRemote('loadSymbols')) return;
    symbolFile = 'motor_control_release.axf';
    _symbols
      ..clear()
      ..addAll(demoSymbols);
    _selectedSymbols.clear();
    _appendLog('已读取符号文件：$symbolFile，变量符号 ${_symbols.length} 个。');
    _emitState([_symbolChanges, _logChanges]);
  }

  Future<void> chooseSymbolFile() async {
    if (_isDetachedRemote) {
      _dispatchRemote('loadSymbols');
      return;
    }
    final picker = symbolFilePicker;
    if (picker == null) {
      loadDemoSymbols();
      return;
    }
    final path = await picker();
    if (path == null || path.isEmpty) return;
    loadSymbolsFromPath(path);
  }

  void loadSymbolsFromPath(String path) {
    if (_dispatchCommand('loadSymbols', path)) return;
    loadDemoSymbols();
  }

  void refreshSymbols() {
    if (symbolFile.isEmpty) return;
    if (_isDetachedRemote) {
      _dispatchRemote('loadSymbols', symbolFile);
      return;
    }
    loadSymbolsFromPath(symbolFile);
  }

  void setSampleRate(double value) {
    if (_dispatchCommand('setSampleRate', value)) return;
    sampleRateHz = value;
    _appendLog('采样率已设置为 $sampleRateLabel。');
    _emitState([_samplingChanges, _logChanges]);
  }

  void setRttSampleRate(double value) {
    if (_dispatchCommand('setRttSampleRate', value)) return;
    rttSampleRateHz = value;
    _emitState([_samplingChanges]);
  }

  void setProbeType(String value) {
    if (_dispatchCommand('setProbeType', value)) return;
    probeType = value;
    _emitState([_connectionChanges]);
  }

  void setTargetName(String value) {
    if (_dispatchCommand('setTargetName', value)) return;
    targetName = value;
    _emitState([_connectionChanges]);
  }

  void setSwdClock(String value) {
    if (_dispatchCommand('setSwdClock', value)) return;
    swdClock = value;
    _emitState([_connectionChanges]);
  }

  void setSerialNumber(String value) {
    if (_dispatchCommand('setSerialNumber', value)) return;
    if (serialNumber == value) return;
    serialNumber = value;
    _emitState([_connectionChanges]);
  }

  void toggleSampling() {
    if (_dispatchCommand('toggleSampling')) return;
    samplingPaused = !samplingPaused;
    _appendLog(samplingPaused ? '采样已暂停。' : '采样已继续。');
    _emitState([_samplingChanges, _logChanges]);
  }

  void togglePlotting() {
    if (_dispatchRemote('togglePlotting')) return;
    plottingPaused = !plottingPaused;
    if (plottingPaused) {
      _freezePlotIfNeeded();
    } else if (followLatest) {
      _clearFrozenPlot();
    }
    _appendLog(plottingPaused ? '绘图已暂停，后台继续采样。' : '绘图已恢复。');
    _emitState([_plotChanges, _logChanges]);
  }

  void toggleRtt(bool value) {
    if (_dispatchCommand('toggleRtt', value)) return;
    rttEnabled = value;
    _appendLog(value ? 'RTT 采样已启用。' : 'RTT 采样已关闭。');
    _emitState([_samplingChanges, _logChanges]);
  }

  void setRttProtocol(String value) {
    if (value != 'normal' && value != 'plus') return;
    if (_dispatchCommand('setRttProtocol', value)) return;
    rttProtocol = value;
    _appendLog('RTT 协议已设置为 ${value == 'normal' ? 'RTT-Normal' : 'RTT-Plus'}。');
    _emitState([_samplingChanges, _logChanges]);
  }

  void toggleFollowLatest() {
    if (_dispatchRemote('toggleFollowLatest')) return;
    if (followLatest) {
      _freezePlotIfNeeded();
    } else if (!plottingPaused) {
      _clearFrozenPlot();
    }
    followLatest = !followLatest;
    _emitState([_plotChanges]);
  }

  void clearSamples() {
    if (_dispatchCommand('clearSamples')) return;
    elapsedSeconds = 0;
    for (final watch in _watches) {
      watch.samples.clear();
    }
    _frozenPlotSamples.clear();
    if (plottingPaused || !followLatest) _frozenPlotEndSeconds = 0;
    _appendLog('当前采样缓存已清空。');
    _emitState([
      _samplingChanges,
      _telemetryChanges,
      _plotChanges,
      _logChanges,
    ]);
    _telemetrySyncChanges.emit();
  }

  void clearLogs() {
    if (_dispatchRemote('clearLogs')) return;
    _logs.clear();
    _emitState([_logChanges]);
  }

  void resetTarget({required bool halt}) {
    if (_dispatchCommand('resetTarget', halt)) return;
    _appendLog(halt ? '目标已复位并暂停。' : '目标已复位并运行。');
    _emitState([_logChanges]);
  }

  Future<void> exportCsv() async {
    if (_isDetachedRemote) {
      _dispatchRemote('exportCsv');
      return;
    }
    final picker = csvExportPathPicker;
    if (picker != null) {
      final path = await picker();
      if (path == null || path.isEmpty) return;
      if (_dispatchCommand('exportCsv', path)) return;
    }
    _appendLog('导出原始 CSV 任务已创建。');
    _emitState([_logChanges]);
  }

  void toggleSymbol(String key) {
    if (_isDetachedRemote && _dispatchRemote('toggleSymbol', key)) return;
    if (!_selectedSymbols.add(key)) {
      _selectedSymbols.remove(key);
    }
    _emitState([_symbolChanges]);
  }

  void addSelectedToWatch() {
    if (_isDetachedRemote && _dispatchRemote('addSelectedToWatch')) return;
    final existing = _watches.map((item) => item.symbol.key).toSet();
    final selected = _symbols
        .where((item) => _selectedSymbols.contains(item.key))
        .where((item) => !existing.contains(item.key))
        .toList();
    for (final symbol in selected) {
      _watches.add(
        WatchItem(
          symbol: symbol,
          color: seriesColors[_watches.length % seriesColors.length],
        ),
      );
    }
    _selectedSymbols.clear();
    _syncWatchesBackend();
    _appendLog('已加入 ${selected.length} 个变量到实时调参列表。');
    _emitState([_symbolChanges, _watchChanges, _plotChanges, _logChanges]);
  }

  void removeWatch(String key) {
    if (_isDetachedRemote && _dispatchRemote('removeWatch', key)) return;
    _watches.removeWhere((item) => item.symbol.key == key);
    _syncWatchesBackend();
    _emitState([_watchChanges, _plotChanges]);
  }

  void clearWatches() {
    if (_isDetachedRemote && _dispatchRemote('clearWatches')) return;
    _watches.clear();
    _syncWatchesBackend();
    _appendLog('已清空实时调参列表。');
    _emitState([_watchChanges, _plotChanges, _logChanges]);
  }

  void toggleWatchPlot(String key, bool value) {
    if (_isDetachedRemote &&
        _dispatchRemote('toggleWatchPlot', {'key': key, 'value': value})) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch != null) watch.plotted = value;
    _syncWatchesBackend();
    _emitState([_watchChanges, _plotChanges]);
  }

  void writeWatch(String key, String input) {
    if (_dispatchCommand('writeWatch', {'key': key, 'value': input})) return;
    final value = double.tryParse(input);
    final watch = _watchByKey(key);
    if (value == null || watch == null) {
      _appendLog('变量写入失败：$input 不是有效数值。');
    } else {
      watch.value = value;
      _appendLog('${watch.symbol.name} 已写入 $input，并完成回读验证。');
    }
    _emitState([_telemetryChanges, _plotChanges, _logChanges]);
  }

  WatchItem? _watchByKey(String key) {
    for (final watch in _watches) {
      if (watch.symbol.key == key) return watch;
    }
    return null;
  }

  bool _dispatchRemote(String method, [Object? arguments]) {
    final sender = remoteCommand;
    if (sender == null) return false;
    unawaited(sender(method, arguments));
    return true;
  }

  bool _dispatchCommand(String method, [Object? arguments]) {
    final sender = backendCommand;
    if (sender != null) {
      unawaited(sender(method, arguments));
      return true;
    }
    return _dispatchRemote(method, arguments);
  }

  bool get _isDetachedRemote => remoteCommand != null && backendCommand == null;

  void _syncWatchesBackend() {
    final sender = backendCommand;
    if (sender == null) return;
    unawaited(
      sender('setWatches', {
        'watches': [
          for (final watch in _watches)
            {
              'key': watch.symbol.key,
              'color':
                  '#${watch.color.toARGB32().toRadixString(16).padLeft(8, '0')}',
              'plotted': watch.plotted,
            },
        ],
      }),
    );
  }

  Future<Map<String, dynamic>> handleCommand(
    String method,
    Object? arguments,
  ) async {
    switch (method) {
      case 'toggleConnection':
        await toggleConnection();
      case 'loadSymbols':
        if (arguments is String && arguments.isNotEmpty) {
          loadSymbolsFromPath(arguments);
        } else {
          await chooseSymbolFile();
        }
      case 'setSampleRate':
        setSampleRate((arguments as num).toDouble());
      case 'setRttSampleRate':
        setRttSampleRate((arguments as num).toDouble());
      case 'setProbeType':
        setProbeType(arguments as String);
      case 'setTargetName':
        setTargetName(arguments as String);
      case 'setSwdClock':
        setSwdClock(arguments as String);
      case 'setSerialNumber':
        setSerialNumber(arguments as String);
      case 'setUiScale':
        setUiScale((arguments as num).toDouble());
      case 'toggleSampling':
        toggleSampling();
      case 'togglePlotting':
        togglePlotting();
      case 'toggleRtt':
        toggleRtt(arguments == true);
      case 'setRttProtocol':
        setRttProtocol(arguments as String);
      case 'toggleFollowLatest':
        toggleFollowLatest();
      case 'clearSamples':
        clearSamples();
      case 'clearLogs':
        clearLogs();
      case 'resetTarget':
        resetTarget(halt: arguments == true);
      case 'exportCsv':
        await exportCsv();
      case 'toggleSymbol':
        toggleSymbol(arguments as String);
      case 'addSelectedToWatch':
        addSelectedToWatch();
      case 'removeWatch':
        removeWatch(arguments as String);
      case 'clearWatches':
        clearWatches();
      case 'toggleWatchPlot':
        final values = Map<String, dynamic>.from(arguments as Map);
        toggleWatchPlot(values['key'] as String, values['value'] as bool);
      case 'writeWatch':
        final values = Map<String, dynamic>.from(arguments as Map);
        writeWatch(values['key'] as String, values['value'] as String);
    }
    return stateSnapshot();
  }

  void _tick(Timer timer) {
    if (connectionStatus != ConnectionStatus.connected || samplingPaused) {
      return;
    }
    elapsedSeconds += 0.033;
    _phase += 0.033;
    for (var index = 0; index < _watches.length; index += 1) {
      final watch = _watches[index];
      final value =
          math.sin(_phase * (1.2 + index * 0.23)) * (index + 1) +
          math.sin(_phase * 8.0 + index) * 0.12;
      watch.value = value;
      watch.samples.add(Offset(elapsedSeconds, value));
      if (watch.samples.length > 1800) {
        watch.samples.removeAt(0);
      }
    }
    _emitTelemetry();
  }

  void addLog(String message) {
    _appendLog(message);
    _emitState([_logChanges]);
  }

  void _appendLog(String message) {
    _logs.add(LogEntry(message));
    if (_logs.length > 500) _logs.removeAt(0);
  }

  void _freezePlotIfNeeded() {
    _frozenPlotEndSeconds ??= elapsedSeconds;
    if (_frozenPlotSamples.isEmpty) _capturePlotSamples();
  }

  void _capturePlotSamples() {
    _frozenPlotSamples
      ..clear()
      ..addEntries(
        _watches.map(
          (watch) => MapEntry(watch.symbol.key, List<Offset>.of(watch.samples)),
        ),
      );
  }

  void _clearFrozenPlot() {
    _frozenPlotEndSeconds = null;
    _frozenPlotSamples.clear();
  }

  void report(String message) {
    addLog(message);
  }

  void _emitState(Iterable<_ControllerSignal> signals, {bool sync = true}) {
    for (final signal in signals.toSet()) {
      signal.emit();
    }
    if (sync) _stateSyncChanges.emit();
    notifyListeners();
  }

  void _emitTelemetry({bool sync = true}) {
    _telemetryChanges.emit();
    if (!plottingPaused && followLatest) _plotChanges.emit();
    if (sync) _telemetrySyncChanges.emit();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _uiScale.dispose();
    _connectionChanges.dispose();
    _samplingChanges.dispose();
    _symbolChanges.dispose();
    _watchChanges.dispose();
    _telemetryChanges.dispose();
    _plotChanges.dispose();
    _logChanges.dispose();
    _stateSyncChanges.dispose();
    _telemetrySyncChanges.dispose();
    super.dispose();
  }
}
