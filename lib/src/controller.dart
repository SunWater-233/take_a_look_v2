import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'backend_client.dart';
import 'controller_command_router.dart';
import 'controller_signals.dart';
import 'controller_state.dart';
import 'demo_data.dart';
import 'models.dart';
import 'protocol/commands.dart';
import 'protocol/events.dart';
import 'telemetry_store.dart';

export 'demo_data.dart';

part 'controller_snapshot.dart';
part 'controller_telemetry.dart';
part 'controller_connection.dart';
part 'controller_plot.dart';
part 'controller_watch.dart';

typedef RemoteCommand =
    Future<void> Function(ControllerCommand command, Object? arguments);
typedef BackendCommand =
    Future<void> Function(ControllerCommand command, Object? arguments);
typedef PathPicker = Future<String?> Function();
typedef TextFilePicker = Future<String?> Function();

class TakeALookController extends ChangeNotifier {
  static const double standardPlotRefreshRateHz = 60;
  static const double highPlotRefreshRateHz = 120;
  static const double maxRealtimePlotRefreshRateHz = 120;

  TakeALookController({
    this.remoteCommand,
    this.backendCommand,
    this.symbolFilePicker,
    this.csvExportPathPicker,
    this.csvImportContentsPicker,
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
  final TextFilePicker? csvImportContentsPicker;
  final List<SymbolItem> _symbols = <SymbolItem>[];
  final List<WatchItem> _watches = <WatchItem>[];
  final List<LogEntry> _logs = <LogEntry>[];
  final Set<String> _selectedSymbols = <String>{};
  int _symbolRevision = 0;
  Timer? _ticker;
  Timer? _plotRefreshTimer;
  Timer? _samplingClockTimer;
  final Stopwatch _samplingElapsedStopwatch = Stopwatch();
  double _samplingElapsedBaseSeconds = 0;
  bool _telemetryDisplayPending = false;
  bool _disposed = false;
  double _phase = 0;
  double? _frozenPlotEndSeconds;
  final Map<String, List<Offset>> _frozenPlotSamples = <String, List<Offset>>{};
  DateTime? _lastPerformanceLogAt;
  final ValueNotifier<double> _uiScale = ValueNotifier<double>(1);
  final ControllerSignals signals = ControllerSignals();

  final ControllerState state = ControllerState();
  final TelemetryStore telemetryStore = TelemetryStore();
  final ControllerSnapshotCodec snapshotCodec = const ControllerSnapshotCodec();

  ConnectionStatus get connectionStatus => state.connection.status;
  set connectionStatus(ConnectionStatus value) =>
      state.connection.status = value;
  String get probeType => state.connection.probeType;
  set probeType(String value) => state.connection.probeType = value;
  String get targetName => state.connection.targetName;
  set targetName(String value) => state.connection.targetName = value;
  String get swdClock => state.connection.swdClock;
  set swdClock(String value) => state.connection.swdClock = value;
  String get serialNumber => state.connection.serialNumber;
  set serialNumber(String value) => state.connection.serialNumber = value;
  String get symbolFile => state.connection.symbolFile;
  set symbolFile(String value) => state.connection.symbolFile = value;
  Map<String, dynamic>? get lastBackendError => state.connection.lastError;
  set lastBackendError(Map<String, dynamic>? value) =>
      state.connection.lastError = value;

  double get sampleRateHz => state.acquisition.sampleRateHz;
  set sampleRateHz(double value) => state.acquisition.sampleRateHz = value;
  double get rttSampleRateHz => state.acquisition.rttSampleRateHz;
  set rttSampleRateHz(double value) =>
      state.acquisition.rttSampleRateHz = value;
  String get displayRefreshMode => state.acquisition.displayRefreshMode;
  set displayRefreshMode(String value) =>
      state.acquisition.displayRefreshMode = value;
  double get elapsedSeconds => state.acquisition.elapsedSeconds;
  set elapsedSeconds(double value) => state.acquisition.elapsedSeconds = value;
  bool get samplingPaused => state.acquisition.samplingPaused;
  set samplingPaused(bool value) => state.acquisition.samplingPaused = value;
  bool get rttEnabled => state.acquisition.rttEnabled;
  set rttEnabled(bool value) => state.acquisition.rttEnabled = value;
  String get rttProtocol => state.acquisition.rttProtocol;
  set rttProtocol(String value) => state.acquisition.rttProtocol = value;
  Map<String, dynamic> get performanceStats =>
      state.acquisition.performanceStats;
  set performanceStats(Map<String, dynamic> value) =>
      state.acquisition.performanceStats = value;

  bool get plottingPaused => state.plot.plottingPaused;
  set plottingPaused(bool value) => state.plot.plottingPaused = value;
  bool get followLatest => state.plot.followLatest;
  set followLatest(bool value) => state.plot.followLatest = value;
  double get plotVisibleWindowSeconds => state.plot.visibleWindowSeconds;
  set plotVisibleWindowSeconds(double value) =>
      state.plot.visibleWindowSeconds = value;
  bool get plotAutoY => state.plot.autoY;
  set plotAutoY(bool value) => state.plot.autoY = value;
  double? get plotYMin => state.plot.yMin;
  set plotYMin(double? value) => state.plot.yMin = value;
  double? get plotYMax => state.plot.yMax;
  set plotYMax(double? value) => state.plot.yMax = value;
  bool get plotShowGrid => state.plot.showGrid;
  set plotShowGrid(bool value) => state.plot.showGrid = value;
  bool get plotShowLegend => state.plot.showLegend;
  set plotShowLegend(bool value) => state.plot.showLegend = value;
  bool get plotMouseXEnabled => state.plot.mouseXEnabled;
  set plotMouseXEnabled(bool value) => state.plot.mouseXEnabled = value;
  bool get plotMouseYEnabled => state.plot.mouseYEnabled;
  set plotMouseYEnabled(bool value) => state.plot.mouseYEnabled = value;
  bool get plotInvertX => state.plot.invertX;
  set plotInvertX(bool value) => state.plot.invertX = value;
  bool get plotInvertY => state.plot.invertY;
  set plotInvertY(bool value) => state.plot.invertY = value;

  List<SymbolItem> get symbols => List.unmodifiable(_symbols);
  int get symbolRevision => _symbolRevision;
  List<WatchItem> get watches => List.unmodifiable(_watches);
  List<LogEntry> get logs => List.unmodifiable(_logs);
  Set<String> get selectedSymbols => Set.unmodifiable(_selectedSymbols);
  double get uiScale => _uiScale.value;
  ValueListenable<double> get uiScaleListenable => _uiScale;
  Listenable get connectionChanges => signals.connection;
  Listenable get samplingChanges => signals.sampling;
  Listenable get symbolChanges => signals.symbols;
  Listenable get watchChanges => signals.watches;
  Listenable get telemetryChanges => signals.telemetry;
  Listenable get plotChanges => signals.plot;
  Listenable get plotControlChanges => signals.plotControls;
  Listenable get clockChanges => signals.clock;
  Listenable get logChanges => signals.logs;
  Listenable get stateSyncChanges => signals.stateSync;
  Listenable get telemetrySyncChanges => signals.telemetrySync;
  double get plotWindowEndSeconds => plottingPaused || !followLatest
      ? (_frozenPlotEndSeconds ?? elapsedSeconds)
      : elapsedSeconds;
  Iterable<Offset> plotSamplesFor(WatchItem watch) {
    if (!plottingPaused) return watch.samples;
    return _frozenPlotSamples[watch.symbol.key] ?? watch.samples;
  }

  WatchItem? _watchByKey(String key) {
    for (final watch in _watches) {
      if (watch.symbol.key == key) return watch;
    }
    return null;
  }

  bool _dispatchRemote(ControllerCommand command, [Object? arguments]) {
    final sender = remoteCommand;
    if (sender == null) return false;
    unawaited(sender(command, arguments));
    return true;
  }

  bool _dispatchCommand(ControllerCommand command, [Object? arguments]) {
    final sender = backendCommand;
    if (sender != null) {
      unawaited(sender(command, arguments));
      return true;
    }
    return _dispatchRemote(command, arguments);
  }

  bool get _isDetachedRemote => remoteCommand != null && backendCommand == null;

  void _syncWatchesBackend() {
    final sender = backendCommand;
    if (sender == null) return;
    unawaited(
      sender(ControllerCommand.setWatches, {
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

  Future<JsonObject> handleCommand(
    ControllerCommand command,
    Object? arguments,
  ) {
    return executeControllerCommand(this, command, arguments);
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
      telemetryStore.append(watch, Offset(elapsedSeconds, value));
    }
    _emitTelemetry();
  }

  void addLog(String message) {
    _appendLog(message);
    _emitState([signals.logs]);
  }

  void _appendLog(String message) {
    _logs.add(LogEntry(message));
    if (_logs.length > 500) _logs.removeAt(0);
  }

  void _freezePlotIfNeeded() {
    _frozenPlotEndSeconds ??= elapsedSeconds;
    if (_frozenPlotSamples.isEmpty) _capturePlotSamples();
  }

  void _freezePlotViewportIfNeeded() {
    _frozenPlotEndSeconds ??= elapsedSeconds;
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

  void _emitState(
    Iterable<ControllerSignal> changedSignals, {
    bool sync = true,
  }) {
    for (final signal in changedSignals.toSet()) {
      signal.emit();
    }
    if (sync) signals.stateSync.emit();
    notifyListeners();
  }

  void _emitTelemetry({bool sync = true}) {
    _telemetryDisplayPending = true;
    _schedulePlotRefresh();
    if (sync) signals.telemetrySync.emit();
    notifyListeners();
  }

  Duration get _plotRefreshInterval => Duration(
    microseconds: (Duration.microsecondsPerSecond / plotRefreshRateHz).round(),
  );

  void _schedulePlotRefresh() {
    if (_plotRefreshTimer?.isActive != true) {
      _emitDisplayFrame();
      _startPlotRefreshClock();
    }
  }

  void _emitDisplayFrame() {
    if (_telemetryDisplayPending) {
      _telemetryDisplayPending = false;
      signals.telemetry.emit();
    }
    if (!plottingPaused && _watches.any((watch) => watch.plotted)) {
      signals.plot.emit();
    }
  }

  void _resetPlotRefreshSchedule() {
    _plotRefreshTimer?.cancel();
    _plotRefreshTimer = null;
    if (_telemetryDisplayPending && !_disposed) {
      _telemetryDisplayPending = false;
      signals.telemetry.emit();
    }
    _startPlotRefreshClock();
  }

  void _startPlotRefreshClock() {
    if (_disposed ||
        connectionStatus != ConnectionStatus.connected ||
        _plotRefreshTimer?.isActive == true) {
      return;
    }
    _plotRefreshTimer = Timer.periodic(
      _plotRefreshInterval,
      (_) => _emitDisplayFrame(),
    );
  }

  void _reconcileSamplingClock() {
    final shouldRun =
        connectionStatus == ConnectionStatus.connected && !samplingPaused;
    if (!shouldRun) {
      if (_samplingElapsedStopwatch.isRunning) {
        _samplingElapsedStopwatch.stop();
        _samplingElapsedBaseSeconds +=
            _samplingElapsedStopwatch.elapsedMicroseconds /
            Duration.microsecondsPerSecond;
        _samplingElapsedStopwatch.reset();
      }
      _samplingClockTimer?.cancel();
      _samplingClockTimer = null;
      if (connectionStatus == ConnectionStatus.disconnected) {
        _samplingElapsedBaseSeconds = 0;
      }
      signals.clock.emit();
      return;
    }
    if (!_samplingElapsedStopwatch.isRunning) {
      _samplingElapsedStopwatch.start();
    }
    _samplingClockTimer ??= Timer.periodic(const Duration(milliseconds: 10), (
      _,
    ) {
      if (!_disposed) signals.clock.emit();
    });
  }

  void _resetSamplingElapsedClock() {
    _samplingElapsedBaseSeconds = 0;
    _samplingElapsedStopwatch.reset();
    signals.clock.emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _plotRefreshTimer?.cancel();
    _samplingClockTimer?.cancel();
    _samplingElapsedStopwatch.stop();
    _uiScale.dispose();
    signals.dispose();
    super.dispose();
  }
}
