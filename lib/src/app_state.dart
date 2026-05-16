import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

class TakeALookController extends ChangeNotifier {
  TakeALookController() {
    symbols.addAll(_demoSymbols());
    addLog('前端工作台已就绪，符号表使用示例数据');
  }

  final List<SymbolVariable> symbols = <SymbolVariable>[];
  final List<WatchVariable> watches = <WatchVariable>[];
  final List<EventLogEntry> logs = <EventLogEntry>[];
  final Set<String> selectedSymbolIds = <String>{};

  ProbeConnectionPhase connectionPhase = ProbeConnectionPhase.disconnected;
  String probeType = '自动发现';
  String targetName = 'STM32F407';
  String swdClock = '4 MHz';
  String serialNumber = '';
  String symbolFileName = 'demo_foc_controller.axf';

  bool samplingPaused = false;
  bool plottingPaused = false;
  bool followLatest = true;
  bool showGrid = true;
  String refreshMode = '120 Hz';

  double sampleRateHz = 1000;
  double visibleWindowSeconds = 12;
  double elapsedSeconds = 0;
  double renderHz = 0;
  double frameBudgetMs = 8.3;
  double uiFrameMs = 0;
  int droppedFrames = 0;

  Duration? _lastTick;
  Duration _lastFpsSample = Duration.zero;
  int _frameCounter = 0;
  double _sampleCarry = 0;
  var _disposed = false;
  var _colorCursor = 0;

  List<SymbolVariable> get selectedSymbols =>
      symbols.where((symbol) => selectedSymbolIds.contains(symbol.id)).toList();

  int get plottedSeriesCount => watches.where((watch) => watch.plotting).length;

  String get elapsedLabel {
    final totalMs = (elapsedSeconds * 1000).floor();
    final hours = totalMs ~/ 3600000;
    final minutes = (totalMs ~/ 60000) % 60;
    final seconds = (totalMs ~/ 1000) % 60;
    final centiseconds = (totalMs ~/ 10) % 100;
    String two(int value) => value.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)}';
    }
    return '${two(minutes)}:${two(seconds)}.${two(centiseconds)}';
  }

  String get sampleRateLabel {
    if (sampleRateHz >= 1000) {
      return '${(sampleRateHz / 1000).toStringAsFixed(sampleRateHz % 1000 == 0 ? 0 : 1)} kHz';
    }
    return '${sampleRateHz.toStringAsFixed(0)} Hz';
  }

  void pump(Duration timestamp) {
    if (_disposed) {
      return;
    }
    final previous = _lastTick;
    _lastTick = timestamp;
    if (previous == null) {
      return;
    }

    final dtSeconds =
        (timestamp - previous).inMicroseconds.clamp(0, 100000) / 1000000.0;
    _frameCounter += 1;
    if (_lastFpsSample == Duration.zero) {
      _lastFpsSample = timestamp;
    }
    final fpsWindow = (timestamp - _lastFpsSample).inMicroseconds / 1000000.0;
    if (fpsWindow >= 0.5) {
      renderHz = _frameCounter / fpsWindow;
      uiFrameMs = 1000 / math.max(renderHz, 1);
      droppedFrames = math.max(0, (60 - renderHz).round());
      _frameCounter = 0;
      _lastFpsSample = timestamp;
    }

    if (!samplingPaused && watches.isNotEmpty) {
      _appendSamples(dtSeconds);
    }
    _safeNotify();
  }

  Future<void> toggleProbe() async {
    if (connectionPhase == ProbeConnectionPhase.connected) {
      connectionPhase = ProbeConnectionPhase.disconnected;
      addLog('探针已断开', level: LogLevel.warning);
      _safeNotify();
      return;
    }
    if (connectionPhase == ProbeConnectionPhase.connecting) {
      return;
    }
    connectionPhase = ProbeConnectionPhase.connecting;
    addLog('正在连接 $probeType / $targetName / $swdClock');
    _safeNotify();

    await Future<void>.delayed(const Duration(milliseconds: 520));
    if (_disposed) {
      return;
    }
    connectionPhase = ProbeConnectionPhase.connected;
    addLog('探针连接成功，目标已初始化', level: LogLevel.success);
    _safeNotify();
  }

  void loadSymbols() {
    symbolFileName = 'motor_control_release.axf';
    selectedSymbolIds.clear();
    addLog(
      '已加载 $symbolFileName，发现 ${symbols.length} 个全局变量',
      level: LogLevel.success,
    );
    _safeNotify();
  }

  void updateProbeType(String value) {
    probeType = value;
    addLog('探针筛选切换为 $value');
    _safeNotify();
  }

  void updateTargetName(String value) {
    targetName = value;
    _safeNotify();
  }

  void updateSwdClock(String value) {
    swdClock = value;
    addLog('SWD 时钟设置为 $value');
    _safeNotify();
  }

  void updateSerialNumber(String value) {
    serialNumber = value;
  }

  void toggleSymbol(SymbolVariable symbol) {
    if (selectedSymbolIds.contains(symbol.id)) {
      selectedSymbolIds.remove(symbol.id);
    } else {
      selectedSymbolIds.add(symbol.id);
    }
    _safeNotify();
  }

  void selectAllVisible(Iterable<SymbolVariable> visibleSymbols) {
    selectedSymbolIds
      ..clear()
      ..addAll(visibleSymbols.map((symbol) => symbol.id));
    _safeNotify();
  }

  void clearSymbolSelection() {
    selectedSymbolIds.clear();
    _safeNotify();
  }

  void addSelectedToWatch() {
    final existingIds = watches.map((watch) => watch.symbol.id).toSet();
    final candidates = selectedSymbols
        .where((symbol) => !existingIds.contains(symbol.id))
        .take(16 - watches.length)
        .toList();
    if (candidates.isEmpty) {
      addLog('没有新的变量可加入实时调参', level: LogLevel.warning);
      _safeNotify();
      return;
    }
    for (final symbol in candidates) {
      watches.add(_watchFromSymbol(symbol));
    }
    selectedSymbolIds.clear();
    addLog('已加入 ${candidates.length} 个变量到实时调参', level: LogLevel.success);
    _safeNotify();
  }

  void addQuickWatch(SymbolVariable symbol) {
    if (watches.any((watch) => watch.symbol.id == symbol.id)) {
      return;
    }
    if (watches.length >= 16) {
      addLog('实时调参列表已达到 16 个变量上限', level: LogLevel.warning);
      _safeNotify();
      return;
    }
    watches.add(_watchFromSymbol(symbol));
    addLog('${symbol.name} 已加入实时调参', level: LogLevel.success);
    _safeNotify();
  }

  void seedDemoWatches({int count = 4}) {
    final existingIds = watches.map((watch) => watch.symbol.id).toSet();
    final candidates = symbols
        .where((symbol) => !existingIds.contains(symbol.id))
        .take(count)
        .toList(growable: false);
    for (final symbol in candidates) {
      watches.add(_watchFromSymbol(symbol));
    }
    if (candidates.isNotEmpty) {
      addLog('独立窗口已初始化 ${candidates.length} 条示例曲线');
      _safeNotify();
    }
  }

  void removeWatch(WatchVariable watch) {
    watches.remove(watch);
    watch.dispose();
    addLog('${watch.symbol.name} 已移出实时调参');
    _safeNotify();
  }

  void clearWatches() {
    for (final watch in watches) {
      watch.dispose();
    }
    watches.clear();
    addLog('实时调参列表已清空', level: LogLevel.warning);
    _safeNotify();
  }

  void setWatchPlotting(WatchVariable watch, bool value) {
    watch.plotting = value;
    addLog('${watch.symbol.name} ${value ? '加入' : '退出'}绘图');
    _safeNotify();
  }

  void writeWatchValue(WatchVariable watch) {
    final raw = watch.writeController.text.trim();
    final parsed = double.tryParse(raw);
    if (parsed == null) {
      addLog('${watch.symbol.name} 写入值无效：$raw', level: LogLevel.error);
      _safeNotify();
      return;
    }
    watch.baseline = parsed;
    watch.currentValue = parsed;
    addLog('${watch.symbol.name} 写入 $raw 并等待回读验证', level: LogLevel.success);
    _safeNotify();
  }

  void setSampleRate(double value) {
    sampleRateHz = value;
    addLog('采样率切换为 $sampleRateLabel');
    _safeNotify();
  }

  void setRefreshMode(String value) {
    refreshMode = value;
    frameBudgetMs = value == '60 Hz' ? 16.6 : (value == '120 Hz' ? 8.3 : 6.9);
    addLog('刷新模式切换为 $value');
    _safeNotify();
  }

  void setVisibleWindow(double value) {
    visibleWindowSeconds = value;
    _safeNotify();
  }

  void toggleSamplingPaused() {
    samplingPaused = !samplingPaused;
    addLog(samplingPaused ? '采样已暂停' : '采样已继续');
    _safeNotify();
  }

  void togglePlottingPaused() {
    plottingPaused = !plottingPaused;
    addLog(plottingPaused ? '绘图已冻结，后台继续采样' : '绘图已恢复');
    _safeNotify();
  }

  void toggleFollowLatest() {
    followLatest = !followLatest;
    _safeNotify();
  }

  void toggleGrid() {
    showGrid = !showGrid;
    addLog(showGrid ? '图表网格已显示' : '图表网格已隐藏');
    _safeNotify();
  }

  void clearSamples() {
    elapsedSeconds = 0;
    _sampleCarry = 0;
    for (final watch in watches) {
      watch.clearSamples();
    }
    addLog('采样缓存已清空');
    _safeNotify();
  }

  void resetTarget({required bool halt}) {
    addLog(halt ? '目标复位并暂停' : '目标复位并运行');
    _safeNotify();
  }

  void clearLogs() {
    logs.clear();
    _safeNotify();
  }

  void addLog(String message, {LogLevel level = LogLevel.info}) {
    logs.add(
      EventLogEntry(timestamp: DateTime.now(), message: message, level: level),
    );
    if (logs.length > 500) {
      logs.removeRange(0, logs.length - 500);
    }
  }

  void _appendSamples(double dtSeconds) {
    final nextElapsed = elapsedSeconds + dtSeconds;
    final samplesFloat = sampleRateHz * dtSeconds + _sampleCarry;
    final sampleCount = samplesFloat.floor();
    _sampleCarry = samplesFloat - sampleCount;

    if (sampleCount <= 0) {
      elapsedSeconds = nextElapsed;
      return;
    }

    final step = dtSeconds / sampleCount;
    for (var i = 0; i < sampleCount; i += 1) {
      final sampleTime = elapsedSeconds + (i + 1) * step;
      for (final watch in watches) {
        final value = _valueFor(watch, sampleTime);
        watch.currentValue = value;
        watch.series.add(sampleTime, value);
      }
    }
    elapsedSeconds = nextElapsed;
  }

  double _valueFor(WatchVariable watch, double time) {
    if (watch.symbol.type == 'bool') {
      return math.sin(time * watch.frequency * math.pi * 2 + watch.phase) > 0.1
          ? 1
          : 0;
    }
    final primary = math.sin(
      time * watch.frequency * math.pi * 2 + watch.phase,
    );
    final ripple = math.sin(
      time * (watch.frequency * 9.7) + watch.phase * 0.33,
    );
    final slow = math.sin(time * 0.23 + watch.phase);
    return watch.baseline +
        watch.amplitude * primary +
        watch.amplitude * 0.16 * ripple +
        watch.amplitude * 0.08 * slow;
  }

  WatchVariable _watchFromSymbol(SymbolVariable symbol) {
    final seed = symbol.address ^ symbol.name.hashCode;
    final rng = math.Random(seed);
    final baseline = _baselineFor(symbol, rng);
    final amplitude = _amplitudeFor(symbol, baseline, rng);
    final palette = _seriesPalette;
    final color = palette[_colorCursor % palette.length];
    _colorCursor += 1;
    return WatchVariable(
      symbol: symbol,
      color: color,
      baseline: baseline,
      amplitude: amplitude,
      frequency: 0.18 + rng.nextDouble() * 1.8,
      phase: rng.nextDouble() * math.pi * 2,
    );
  }

  double _baselineFor(SymbolVariable symbol, math.Random rng) {
    final name = symbol.name.toLowerCase();
    if (symbol.type == 'bool') {
      return 1;
    }
    if (name.contains('temp')) {
      return 36 + rng.nextDouble() * 24;
    }
    if (name.contains('speed') || name.contains('rpm')) {
      return 1200 + rng.nextDouble() * 2600;
    }
    if (name.contains('volt')) {
      return 12 + rng.nextDouble() * 18;
    }
    if (name.contains('current') ||
        name.contains('iq') ||
        name.contains('id')) {
      return -4 + rng.nextDouble() * 8;
    }
    if (name.contains('duty')) {
      return 0.42 + rng.nextDouble() * 0.28;
    }
    if (symbol.type.contains('uint')) {
      return rng.nextInt(4096).toDouble();
    }
    return -10 + rng.nextDouble() * 20;
  }

  double _amplitudeFor(
    SymbolVariable symbol,
    double baseline,
    math.Random rng,
  ) {
    if (symbol.type == 'bool') {
      return 1;
    }
    if (symbol.type.contains('uint') || symbol.type.contains('int')) {
      return math.max(2, baseline.abs() * (0.02 + rng.nextDouble() * 0.04));
    }
    return math.max(0.05, baseline.abs() * (0.04 + rng.nextDouble() * 0.08));
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final watch in watches) {
      watch.dispose();
    }
    super.dispose();
  }
}

const List<Color> _seriesPalette = <Color>[
  Color(0xFF51C7F8),
  Color(0xFF7BD88F),
  Color(0xFFFFC857),
  Color(0xFFFF6B8A),
  Color(0xFFA78BFA),
  Color(0xFF4ECDC4),
  Color(0xFFFF9F43),
  Color(0xFFE8EAED),
];

List<SymbolVariable> _demoSymbols() {
  const rows =
      <
        ({
          String path,
          String name,
          String type,
          int address,
          int size,
          String section,
        })
      >[
        (
          path: 'firmware/src/control/foc_current.c',
          name: 'iq_ref',
          type: 'float',
          address: 0x20000010,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/control/foc_current.c',
          name: 'id_ref',
          type: 'float',
          address: 0x20000014,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/control/foc_speed.c',
          name: 'speed_rpm',
          type: 'float',
          address: 0x20000020,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/foc_speed.c',
          name: 'speed_target_rpm',
          type: 'float',
          address: 0x20000024,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/pid.c',
          name: 'speed_pid_kp',
          type: 'float',
          address: 0x20000030,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/pid.c',
          name: 'speed_pid_ki',
          type: 'float',
          address: 0x20000034,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/pid.c',
          name: 'speed_pid_kd',
          type: 'float',
          address: 0x20000038,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/pid.c',
          name: 'current_pid_kp',
          type: 'float',
          address: 0x2000003C,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/control/pid.c',
          name: 'current_pid_ki',
          type: 'float',
          address: 0x20000040,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/driver/adc.c',
          name: 'bus_voltage',
          type: 'float',
          address: 0x20000100,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/adc.c',
          name: 'phase_current_a',
          type: 'float',
          address: 0x20000104,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/adc.c',
          name: 'phase_current_b',
          type: 'float',
          address: 0x20000108,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/adc.c',
          name: 'phase_current_c',
          type: 'float',
          address: 0x2000010C,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/encoder.c',
          name: 'encoder_angle',
          type: 'float',
          address: 0x20000120,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/encoder.c',
          name: 'encoder_raw_count',
          type: 'uint32_t',
          address: 0x20000124,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/driver/pwm.c',
          name: 'pwm_duty_a',
          type: 'float',
          address: 0x20000140,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/driver/pwm.c',
          name: 'pwm_duty_b',
          type: 'float',
          address: 0x20000144,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/driver/pwm.c',
          name: 'pwm_duty_c',
          type: 'float',
          address: 0x20000148,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/safety/fault.c',
          name: 'fault_code',
          type: 'uint32_t',
          address: 0x20000200,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/safety/fault.c',
          name: 'fault_latched',
          type: 'bool',
          address: 0x20000204,
          size: 1,
          section: '.bss',
        ),
        (
          path: 'firmware/src/safety/thermal.c',
          name: 'mos_temp_c',
          type: 'float',
          address: 0x20000220,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/safety/thermal.c',
          name: 'mcu_temp_c',
          type: 'float',
          address: 0x20000224,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/comms/canopen.c',
          name: 'can_rx_count',
          type: 'uint32_t',
          address: 0x20000300,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/comms/canopen.c',
          name: 'can_tx_count',
          type: 'uint32_t',
          address: 0x20000304,
          size: 4,
          section: '.bss',
        ),
        (
          path: 'firmware/src/comms/rtt_scope.c',
          name: 'rtt_stream_enabled',
          type: 'bool',
          address: 0x20000340,
          size: 1,
          section: '.data',
        ),
        (
          path: 'firmware/src/app/tune_profile.c',
          name: 'profile_slot',
          type: 'uint8_t',
          address: 0x20000400,
          size: 1,
          section: '.data',
        ),
        (
          path: 'firmware/src/app/tune_profile.c',
          name: 'torque_limit',
          type: 'float',
          address: 0x20000404,
          size: 4,
          section: '.data',
        ),
        (
          path: 'firmware/src/app/tune_profile.c',
          name: 'regen_limit',
          type: 'float',
          address: 0x20000408,
          size: 4,
          section: '.data',
        ),
      ];

  return [
    for (var i = 0; i < rows.length; i += 1)
      SymbolVariable(
        id: '${rows[i].path}:${rows[i].name}',
        path: rows[i].path,
        name: rows[i].name,
        type: rows[i].type,
        address: rows[i].address,
        size: rows[i].size,
        section: rows[i].section,
      ),
  ];
}
