import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../backend/backend_client.dart';
import '../analysis/analysis.dart';
import 'controller_command_router.dart';
import 'controller_signals.dart';
import 'controller_state.dart';
import 'watch_registry.dart';
import 'controller_snapshot_codec.dart';
import 'controller_snapshot_schema.dart';

export 'controller_snapshot_codec.dart';
import '../models/demo_data.dart';
import '../models/models.dart';
import '../models/connection_capabilities.dart';
import '../models/source_tools.dart';
import '../models/freertos.dart';
import '../protocol/commands.dart';
import '../protocol/events.dart';
import '../telemetry/telemetry_store.dart';
import '../telemetry/sample_buffer.dart';
import '../telemetry/numeric_history.dart';
import '../telemetry/plot_history.dart';

export '../models/demo_data.dart';

part 'controller_snapshot.dart';
part 'controller_sync.dart';
part 'controller_telemetry.dart';
part 'controller_connection.dart';
part 'controller_firmware.dart';
part 'controller_plot.dart';
part 'controller_analysis.dart';
part 'controller_watch.dart';
part 'controller_debug.dart';
part 'controller_source_workspace.dart';
part 'controller_source_tools.dart';
part 'controller_targets.dart';
part 'controller_project.dart';
part 'controller_freertos.dart';

typedef RemoteCommand =
    Future<void> Function(ControllerCommand command, Object? arguments);
typedef BackendCommand =
    Future<void> Function(ControllerCommand command, Object? arguments);
typedef PathPicker = Future<String?> Function();
typedef TextFilePicker = Future<String?> Function();
typedef TargetCatalogRequest =
    Future<JsonObject> Function(String operation, JsonObject arguments);

class TakeALookController extends ChangeNotifier {
  static const double standardPlotRefreshRateHz = 60;
  static const double highPlotRefreshRateHz = 120;
  static const double maxRealtimePlotRefreshRateHz = 120;

  TakeALookController({
    this.remoteCommand,
    this.backendCommand,
    this.projectBackendCommand,
    this.firmwareFilePicker,
    this.sourceRootPicker,
    this.csvExportPathPicker,
    this.csvImportContentsPicker,
    this.csvImportPathPicker,
    this.targetCatalogRequest,
    this.freeRtosRequest,
    this.emberRequest,
    this.targetPackPicker,
    HistoryReader? historyReader,
  }) {
    plotHistory = PlotHistory(
      reader: historyReader,
      onChanged: () {
        if (!_disposed) signals.plot.emit();
      },
    );
    _logs.add(LogEntry('UI 已从 .ui 文件加载，pyOCD 内存读写后端已就绪'));
    _logs.add(LogEntry('读取 .elf / .axf 后，可从符号层级中加入变量到实时调参列表'));
    if (remoteCommand == null && backendCommand == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 33), _tick);
    }
  }

  final RemoteCommand? remoteCommand;
  final BackendCommand? backendCommand;
  final BackendCommand? projectBackendCommand;
  final PathPicker? firmwareFilePicker;
  final PathPicker? sourceRootPicker;
  final PathPicker? csvExportPathPicker;
  final TextFilePicker? csvImportContentsPicker;
  final PathPicker? csvImportPathPicker;
  final TargetCatalogRequest? targetCatalogRequest;
  final TargetCatalogRequest? freeRtosRequest;
  final TargetCatalogRequest? emberRequest;
  final PathPicker? targetPackPicker;
  final List<SymbolItem> _symbols = <SymbolItem>[];
  late final WatchRegistry _watchRegistry = WatchRegistry(
    onExpired: () {
      _syncWatchesBackend();
      _emitState([signals.watches, signals.plot]);
    },
    onDiscard: (key) => _frozenPlotSamples.remove(key),
  );
  List<WatchItem> get _watches => _watchRegistry.watches;
  Set<String> get _removedWatchKeys => _watchRegistry.removedKeys;
  bool _remoteCanUndoWatchDeletion = false;
  bool _remoteCanRedoWatchDeletion = false;
  final List<LogEntry> _logs = <LogEntry>[];
  final Set<String> _selectedSymbols = <String>{};
  final Set<String> _expandedSymbolTreeNodes = <String>{};
  int _symbolRevision = 0;
  bool _pickingFirmwareFile = false;
  bool _restoringProject = false;
  bool get isProjectRestoring => _restoringProject;
  int _nextSymbolLoadId = 0;
  Timer? _ticker;
  Timer? _plotRefreshTimer;
  Timer? _samplingClockTimer;
  final Stopwatch _samplingElapsedStopwatch = Stopwatch();
  double _samplingElapsedBaseSeconds = 0;
  bool _telemetryDisplayPending = false;
  bool _telemetrySyncPending = false;
  bool _disposed = false;
  bool _presentationActive = true;
  double _phase = 0;
  double? _frozenPlotEndSeconds;
  final Map<String, SampleBuffer> _frozenPlotSamples = <String, SampleBuffer>{};
  DateTime? _lastPerformanceLogAt;
  final ValueNotifier<double> _uiScale = ValueNotifier<double>(1);
  final ControllerSignals signals = ControllerSignals();
  final SnapshotRevisions _snapshotRevisions = SnapshotRevisions();
  Map<String, String> get watchInputDrafts => _watchRegistry.drafts;
  String? get compactWatchSelection => _watchRegistry.selection;
  set compactWatchSelection(String? value) => _watchRegistry.selection = value;
  Set<String> get compactExpandedWatches => _watchRegistry.expanded;
  double? compactWatchSummaryFraction;
  String watchSearchQuery = '';
  final Map<String, Set<String>> _watchMonitorScopes = {};
  bool _watchMonitorVisibilityKnown = false;
  bool _watchMonitorSyncPending = false;
  final Map<String, Set<String>?> _pendingRemoteMonitorScopes = {};
  final Set<String> _freeRtosViews = {};
  bool _freeRtosConfigPending = false;
  Set<String>? _lastMonitorEnabledKeys;
  ({String path, int line})? sourceLocationRequest;
  int _analysisDataRevision = 0;
  final Set<String> _visibleSourceViews = <String>{};
  bool _sourceWorkspaceNotificationPending = false;

  final ControllerState state = ControllerState();
  final TelemetryStore telemetryStore = TelemetryStore();
  late final PlotHistory plotHistory;
  double _plotPixelWidth = 1000;
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
  String get connectionKind => state.connection.connectionKind;
  set connectionKind(String value) {
    if (value != connectionKind) state.connection.advertisedCapabilities = null;
    state.connection.connectionKind = value;
  }

  Map<String, String> get remoteConfig => state.connection.remoteConfig;
  bool get isGdbMemoryMode =>
      connectionKind == 'gdb' && remoteConfig['gdbMode'] == 'memory';
  bool get supportsMemoryWrite => state.connection.capabilities.memoryWrite;
  bool get supportsTargetControl => state.connection.capabilities.targetControl;
  bool get supportsFirmwareDownload =>
      state.connection.capabilities.firmwareDownload;
  String get firmwarePath => sourceProject.firmwarePath;
  bool get hasFirmwareSymbols =>
      const {'ready', 'stale'}.contains(state.firmware['status']);
  Map<String, dynamic>? get lastBackendError => state.connection.lastError;
  set lastBackendError(Map<String, dynamic>? value) =>
      state.connection.lastError = value;

  double get sampleRateHz => state.acquisition.sampleRateHz;
  double get monitorRateHz => state.acquisition.monitorRateHz;
  set monitorRateHz(double value) {
    if (value.isFinite && value >= 0.5 && value <= 10) {
      state.acquisition.monitorRateHz = value;
    }
  }

  set sampleRateHz(double value) {
    if (!value.isFinite || value <= 0) return;
    state.acquisition.sampleRateHz = value;
    _configurePlotRetention();
  }

  double get rttSampleRateHz => state.acquisition.rttSampleRateHz;
  set rttSampleRateHz(double value) {
    if (!value.isFinite || value <= 0) return;
    state.acquisition.rttSampleRateHz = value;
    _configurePlotRetention();
  }

  String get displayRefreshMode => state.acquisition.displayRefreshMode;
  set displayRefreshMode(String value) =>
      state.acquisition.displayRefreshMode = value;
  double get elapsedSeconds => state.acquisition.elapsedSeconds;
  set elapsedSeconds(double value) => state.acquisition.elapsedSeconds = value;
  bool get samplingPaused => state.acquisition.samplingPaused;
  set samplingPaused(bool value) => state.acquisition.samplingPaused = value;
  bool get rttEnabled => state.acquisition.rttEnabled;
  set rttEnabled(bool value) {
    state.acquisition.rttEnabled = value;
    _configurePlotRetention();
  }

  String get rttProtocol => state.acquisition.rttProtocol;
  set rttProtocol(String value) {
    state.acquisition.rttProtocol = value;
    _configurePlotRetention();
  }

  Map<String, dynamic> get performanceStats =>
      state.acquisition.performanceStats;
  set performanceStats(Map<String, dynamic> value) =>
      state.acquisition.performanceStats = value;

  String? get plotHighlightedWatchKey => state.plot.highlightedWatchKey;
  int get plotWatchSelectionRevision => state.plot.watchSelectionRevision;
  bool get plottingPaused => state.plot.plottingPaused;
  set plottingPaused(bool value) => state.plot.plottingPaused = value;
  bool get followLatest => state.plot.followLatest;
  set followLatest(bool value) => state.plot.followLatest = value;
  double get plotVisibleWindowSeconds => state.plot.visibleWindowSeconds;
  double get plotRetentionSeconds => state.plot.retentionSeconds;
  Map<String, dynamic> get rawRecording => state.acquisition.rawRecording;
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
  AnalysisSession get analysisSession => state.analysis;

  List<SymbolItem> get symbols => List.unmodifiable(_symbols);
  int get symbolRevision => _symbolRevision;
  bool isSymbolTreeNodeExpanded(String key) =>
      _expandedSymbolTreeNodes.contains(key);
  List<WatchItem> get watches => List.unmodifiable(_watches);

  /// Includes captures retained briefly after removal so undo has no data gap.
  Iterable<WatchItem> get acquisitionWatches => _watchRegistry.acquiring;
  Iterable<WatchItem> get _allRetainedWatches => _watchRegistry.retained;

  bool get canUndoWatchDeletion =>
      _isDetachedRemote ? _remoteCanUndoWatchDeletion : _watchRegistry.canUndo;
  bool get canRedoWatchDeletion =>
      _isDetachedRemote ? _remoteCanRedoWatchDeletion : _watchRegistry.canRedo;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  Set<String> get selectedSymbols => Set.unmodifiable(_selectedSymbols);
  double get uiScale => _uiScale.value;
  ValueListenable<double> get uiScaleListenable => _uiScale;
  Listenable get connectionChanges => signals.connection;
  Listenable get samplingChanges => signals.sampling;
  Listenable get symbolChanges => signals.symbols;
  Listenable get symbolLoadChanges => signals.symbolLoad;
  SymbolLoadProgress? get symbolLoadProgress => state.symbolLoad;
  bool get isSymbolLoading => state.symbolLoad?.isLoading ?? false;
  Listenable get watchChanges => signals.watches;
  int get watchRevision => _snapshotRevisions.revisionOf(SnapshotField.watches);
  Listenable get telemetryChanges => signals.telemetry;
  Listenable get plotChanges => signals.plot;
  Listenable get plotControlChanges => signals.plotControls;
  Listenable get analysisChanges => signals.analysis;
  Listenable get clockChanges => signals.clock;
  Listenable get logChanges => signals.logs;
  Listenable get debugChanges => signals.debug;
  Listenable get sourceWorkspaceChanges => signals.sourceWorkspace;
  Listenable get sourceToolsChanges => signals.sourceTools;
  Listenable get stateSyncChanges => signals.stateSync;
  Listenable get telemetrySyncChanges => signals.telemetrySync;
  double get plotWindowEndSeconds => plottingPaused || !followLatest
      ? (_frozenPlotEndSeconds ?? elapsedSeconds)
      : elapsedSeconds;
  Iterable<Offset> plotSamplesFor(WatchItem watch) {
    final recent = plottingPaused
        ? _frozenPlotSamples[watch.symbol.key] ?? watch.samples
        : watch.samples;
    final history = plotHistory.samplesFor(
      watch.symbol.key,
      minimumTime: watch.historyStartSeconds,
    );
    final start = math.max(
      0.0,
      plotWindowEndSeconds - plotVisibleWindowSeconds,
    );
    if (recent.isNotEmpty &&
        recent.isOrdered &&
        ((recent.first.dx <= start &&
                recent.last.dx >=
                    math.min(plotWindowEndSeconds, elapsedSeconds)) ||
            (!plottingPaused && watch.totalSampleCount == recent.length))) {
      return recent;
    }
    return history ?? recent;
  }

  void _configurePlotRetention() {
    telemetryStore
      ..retentionSeconds = plotRetentionSeconds
      ..sampleRateHz = sampleRateHz
      ..rttSampleRateHz = rttSampleRateHz
      ..rttEnabled = rttEnabled
      ..rttProtocol = rttProtocol;
    for (final watch in acquisitionWatches) {
      telemetryStore.configureWatch(watch);
    }
  }

  void toggleSymbolTreeNodeExpansion(String key) {
    if (!_expandedSymbolTreeNodes.add(key)) {
      _expandedSymbolTreeNodes.remove(key);
    }
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
    if (_restoringProject) return;
    final sender = backendCommand;
    if (sender == null) return;
    _lastMonitorEnabledKeys = _monitorEnabledKeys();
    unawaited(
      sender(ControllerCommand.setWatches, {
        'watches': [
          for (final watch in acquisitionWatches)
            {
              'key': watch.symbol.key,
              'color':
                  '#${watch.color.toARGB32().toRadixString(16).padLeft(8, '0')}',
              'sampling': watch.samplingEnabled,
              'readMode': watch.readMode.name,
              'monitorRateHz': watch.monitorRateHz,
              'monitorEnabled': isWatchMonitorActive(watch),
              'plotted':
                  !_removedWatchKeys.contains(watch.symbol.key) &&
                  watch.plotted,
            },
        ],
      }),
    );
  }

  Future<JsonObject> handleCommand(
    ControllerCommand command,
    Object? arguments, {
    bool includeResultState = true,
  }) {
    return executeControllerCommand(
      this,
      command,
      arguments,
      includeResultState: includeResultState,
    );
  }

  void _tick(Timer timer) {
    if (connectionStatus != ConnectionStatus.connected) {
      return;
    }
    elapsedSeconds += 0.033;
    _phase += 0.033;
    final now = DateTime.now().millisecondsSinceEpoch;
    final acquiring = acquisitionWatches.toList();
    for (var index = 0; index < acquiring.length; index += 1) {
      final watch = acquiring[index];
      if (watch.readMode == WatchReadMode.manual) continue;
      if (watch.readMode == WatchReadMode.monitor &&
          !isWatchMonitorActive(watch)) {
        continue;
      }
      if (watch.samplingEnabled && samplingPaused) continue;
      if (watch.readMode == WatchReadMode.monitor &&
          watch.updatedAtMs != null &&
          now - watch.updatedAtMs! < 1000 / monitorRateFor(watch)) {
        continue;
      }
      final value =
          math.sin(_phase * (1.2 + index * 0.23)) * (index + 1) +
          math.sin(_phase * 8.0 + index) * 0.12;
      watch.value = value;
      watch.updatedAtMs = now;
      if (watch.samplingEnabled) {
        telemetryStore.append(watch, Offset(elapsedSeconds, value));
      }
    }
    _emitTelemetry();
  }

  void addLog(String message, {LogLevel level = LogLevel.info}) {
    _appendLog(message, level: level);
    _emitState([signals.logs]);
  }

  void _appendLog(String message, {LogLevel level = LogLevel.info}) {
    _logs.add(LogEntry(message, level: level));
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
          (watch) => MapEntry(watch.symbol.key, watch.samples.snapshot()),
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
    final changes = changedSignals.toSet();
    if (changes.contains(signals.plot) ||
        changes.contains(signals.watches) ||
        changes.contains(signals.sampling)) {
      preparePlotHistory();
    }
    _recordStateChanges(changes);
    for (final signal in changes) {
      signal.emit();
    }
    if (sync) signals.stateSync.emit();
    notifyListeners();
  }

  void _emitTelemetry({bool sync = true}) {
    _telemetryDisplayPending = true;
    _telemetrySyncPending = _telemetrySyncPending || sync;
    _schedulePlotRefresh();
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
    if (_disposed || !_presentationActive) return;
    preparePlotHistory();
    final telemetryChanged = _telemetryDisplayPending;
    if (telemetryChanged) {
      _telemetryDisplayPending = false;
      signals.telemetry.emit();
    }
    if (!plottingPaused &&
        (followLatest || !plotHistory.hasVisibleWindow) &&
        _watches.any((watch) => watch.plotted)) {
      signals.plot.emit();
    }
    if (_telemetrySyncPending) {
      _telemetrySyncPending = false;
      signals.telemetrySync.emit();
    }
    if (telemetryChanged) notifyListeners();
  }

  void _resetPlotRefreshSchedule() {
    _plotRefreshTimer?.cancel();
    _plotRefreshTimer = null;
    if (_telemetryDisplayPending && !_disposed) {
      _emitDisplayFrame();
    }
    _startPlotRefreshClock();
  }

  void _startPlotRefreshClock() {
    if (_disposed ||
        !_presentationActive ||
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
        _presentationActive &&
        connectionStatus == ConnectionStatus.connected &&
        !samplingPaused;
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
    plotHistory.dispose();
    _ticker?.cancel();
    _plotRefreshTimer?.cancel();
    _samplingClockTimer?.cancel();
    _clearWatchDeletionHistory();
    _samplingElapsedStopwatch.stop();
    _uiScale.dispose();
    signals.dispose();
    super.dispose();
  }
}
