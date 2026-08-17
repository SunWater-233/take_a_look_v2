import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

typedef RemoteCommand = Future<void> Function(String method, Object? arguments);

class TakeALookController extends ChangeNotifier {
  TakeALookController({this.remoteCommand}) {
    _logs.add(LogEntry('UI 已从 .ui 文件加载，pyOCD 内存读写后端已就绪。'));
    _logs.add(LogEntry('读取 .elf / .axf 后，可从符号层级中加入变量到实时调参列表。'));
    if (remoteCommand == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 33), _tick);
    }
  }

  final RemoteCommand? remoteCommand;
  final List<SymbolItem> _symbols = <SymbolItem>[];
  final List<WatchItem> _watches = <WatchItem>[];
  final List<LogEntry> _logs = <LogEntry>[];
  final Set<String> _selectedSymbols = <String>{};
  Timer? _ticker;
  bool _disposed = false;
  double _phase = 0;
  final ValueNotifier<double> _uiScale = ValueNotifier<double>(1);

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
  bool followLatest = true;

  List<SymbolItem> get symbols => List.unmodifiable(_symbols);
  List<WatchItem> get watches => List.unmodifiable(_watches);
  List<LogEntry> get logs => List.unmodifiable(_logs);
  Set<String> get selectedSymbols => Set.unmodifiable(_selectedSymbols);
  double get uiScale => _uiScale.value;
  ValueListenable<double> get uiScaleListenable => _uiScale;

  void setUiScale(double value) {
    if (_dispatchRemote('setUiScale', value)) return;
    final normalized = value.clamp(0.5, 2).toDouble();
    if ((normalized - _uiScale.value).abs() < 0.001) return;
    _uiScale.value = normalized;
    addLog('界面缩放已设置为 ${(normalized * 100).round()}%。');
    notifyListeners();
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
    if (_dispatchRemote('toggleConnection')) return;
    if (connectionStatus == ConnectionStatus.connected) {
      connectionStatus = ConnectionStatus.disconnected;
      samplingPaused = false;
      addLog('已断开 pyOCD 调试探针。');
      notifyListeners();
      return;
    }
    if (connectionStatus == ConnectionStatus.connecting) return;
    connectionStatus = ConnectionStatus.connecting;
    addLog('开始连接 pyOCD：正在枚举探针并初始化目标。');
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (_disposed) return;
    connectionStatus = ConnectionStatus.connected;
    addLog('已连接 pyOCD：target=$targetName，SWD=$swdClock。');
    notifyListeners();
  }

  void loadDemoSymbols() {
    if (_dispatchRemote('loadSymbols')) return;
    symbolFile = 'motor_control_release.axf';
    _symbols
      ..clear()
      ..addAll(demoSymbols);
    _selectedSymbols.clear();
    addLog('已读取符号文件：$symbolFile，变量符号 ${_symbols.length} 个。');
    notifyListeners();
  }

  void setSampleRate(double value) {
    if (_dispatchRemote('setSampleRate', value)) return;
    sampleRateHz = value;
    addLog('采样率已设置为 $sampleRateLabel。');
    notifyListeners();
  }

  void setRttSampleRate(double value) {
    if (_dispatchRemote('setRttSampleRate', value)) return;
    rttSampleRateHz = value;
    notifyListeners();
  }

  void setProbeType(String value) {
    if (_dispatchRemote('setProbeType', value)) return;
    probeType = value;
    notifyListeners();
  }

  void setTargetName(String value) {
    if (_dispatchRemote('setTargetName', value)) return;
    targetName = value;
    notifyListeners();
  }

  void setSwdClock(String value) {
    if (_dispatchRemote('setSwdClock', value)) return;
    swdClock = value;
    notifyListeners();
  }

  void setSerialNumber(String value) {
    if (_dispatchRemote('setSerialNumber', value)) return;
    serialNumber = value;
  }

  void toggleSampling() {
    if (_dispatchRemote('toggleSampling')) return;
    samplingPaused = !samplingPaused;
    addLog(samplingPaused ? '采样已暂停。' : '采样已继续。');
    notifyListeners();
  }

  void togglePlotting() {
    if (_dispatchRemote('togglePlotting')) return;
    plottingPaused = !plottingPaused;
    addLog(plottingPaused ? '绘图已暂停，后台继续采样。' : '绘图已恢复。');
    notifyListeners();
  }

  void toggleRtt(bool value) {
    if (_dispatchRemote('toggleRtt', value)) return;
    rttEnabled = value;
    addLog(value ? 'RTT 采样已启用。' : 'RTT 采样已关闭。');
    notifyListeners();
  }

  void toggleFollowLatest() {
    if (_dispatchRemote('toggleFollowLatest')) return;
    followLatest = !followLatest;
    notifyListeners();
  }

  void clearSamples() {
    if (_dispatchRemote('clearSamples')) return;
    elapsedSeconds = 0;
    for (final watch in _watches) {
      watch.samples.clear();
    }
    addLog('当前采样缓存已清空。');
    notifyListeners();
  }

  void clearLogs() {
    if (_dispatchRemote('clearLogs')) return;
    _logs.clear();
    notifyListeners();
  }

  void resetTarget({required bool halt}) {
    if (_dispatchRemote('resetTarget', halt)) return;
    addLog(halt ? '目标已复位并暂停。' : '目标已复位并运行。');
    notifyListeners();
  }

  void exportCsv() {
    if (_dispatchRemote('exportCsv')) return;
    addLog('导出原始 CSV 任务已创建。');
    notifyListeners();
  }

  void toggleSymbol(String key) {
    if (_dispatchRemote('toggleSymbol', key)) return;
    if (!_selectedSymbols.add(key)) {
      _selectedSymbols.remove(key);
    }
    notifyListeners();
  }

  void addSelectedToWatch() {
    if (_dispatchRemote('addSelectedToWatch')) return;
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
    addLog('已加入 ${selected.length} 个变量到实时调参列表。');
    notifyListeners();
  }

  void removeWatch(String key) {
    if (_dispatchRemote('removeWatch', key)) return;
    _watches.removeWhere((item) => item.symbol.key == key);
    notifyListeners();
  }

  void clearWatches() {
    if (_dispatchRemote('clearWatches')) return;
    _watches.clear();
    addLog('已清空实时调参列表。');
    notifyListeners();
  }

  void toggleWatchPlot(String key, bool value) {
    if (_dispatchRemote('toggleWatchPlot', {'key': key, 'value': value})) {
      return;
    }
    final watch = _watchByKey(key);
    if (watch != null) watch.plotted = value;
    notifyListeners();
  }

  void writeWatch(String key, String input) {
    if (_dispatchRemote('writeWatch', {'key': key, 'value': input})) return;
    final value = double.tryParse(input);
    final watch = _watchByKey(key);
    if (value == null || watch == null) {
      addLog('变量写入失败：$input 不是有效数值。');
    } else {
      watch.value = value;
      addLog('${watch.symbol.name} 已写入 $input，并完成回读验证。');
    }
    notifyListeners();
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

  Future<Map<String, dynamic>> handleCommand(
    String method,
    Object? arguments,
  ) async {
    switch (method) {
      case 'toggleConnection':
        await toggleConnection();
      case 'loadSymbols':
        loadDemoSymbols();
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
      case 'toggleFollowLatest':
        toggleFollowLatest();
      case 'clearSamples':
        clearSamples();
      case 'clearLogs':
        clearLogs();
      case 'resetTarget':
        resetTarget(halt: arguments == true);
      case 'exportCsv':
        exportCsv();
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
    return snapshot();
  }

  Map<String, dynamic> snapshot() {
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

  void applySnapshot(Map<String, dynamic> data) {
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
          for (final rawPoint in item['samples'] as List? ?? const []) {
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
    notifyListeners();
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
    notifyListeners();
  }

  void addLog(String message) {
    _logs.add(LogEntry(message));
    if (_logs.length > 500) _logs.removeAt(0);
  }

  void report(String message) {
    addLog(message);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _uiScale.dispose();
    super.dispose();
  }
}

const seriesColors = <Color>[
  TalColors.accent,
  TalColors.success,
  TalColors.blue,
  TalColors.amber,
  Color(0xFFC026D3),
  Color(0xFF0891B2),
  Color(0xFFDB2777),
];

const demoSymbols = <SymbolItem>[
  SymbolItem(
    source: 'control/foc_current.c',
    name: 'iq_ref',
    address: 0x20000010,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'control/foc_current.c',
    name: 'id_ref',
    address: 0x20000014,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'control/foc_speed.c',
    name: 'speed_rpm',
    address: 0x20000020,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'control/pid.c',
    name: 'speed_pid_kp',
    address: 0x20000030,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'driver/adc.c',
    name: 'bus_voltage',
    address: 0x20000100,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'driver/adc.c',
    name: 'phase_current_a',
    address: 0x20000104,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'driver/encoder.c',
    name: 'encoder_angle',
    address: 0x20000120,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'driver/pwm.c',
    name: 'pwm_duty_a',
    address: 0x20000140,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'safety/fault.c',
    name: 'fault_code',
    address: 0x20000200,
    type: 'uint32_t',
    size: 4,
  ),
  SymbolItem(
    source: 'safety/fault.c',
    name: 'fault_latched',
    address: 0x20000204,
    type: 'bool',
    size: 1,
  ),
  SymbolItem(
    source: 'safety/thermal.c',
    name: 'mos_temp_c',
    address: 0x20000220,
    type: 'float',
    size: 4,
  ),
  SymbolItem(
    source: 'comms/canopen.c',
    name: 'can_rx_count',
    address: 0x20000300,
    type: 'uint32_t',
    size: 4,
  ),
];
