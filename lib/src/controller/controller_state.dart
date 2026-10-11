import '../models/models.dart';
import '../analysis/analysis.dart';

/// Aggregate state owned by the application controller.
///
/// Each slice changes for a different reason. Keeping them explicit prevents
/// connection, acquisition and presentation state from becoming one bag of
/// unrelated mutable fields again.
class ControllerState {
  final ConnectionState connection = ConnectionState();
  final AcquisitionState acquisition = AcquisitionState();
  final PlotState plot = PlotState();
  final AnalysisSession analysis = AnalysisSession();
  final DebugState debug = DebugState();
  final SourceWorkspaceState sourceWorkspace = SourceWorkspaceState();
  SymbolLoadProgress? symbolLoad;
}

/// Presentation state is separate from the target's stopped source location.
class SourceWorkspaceState {
  final List<String> openPaths = <String>[];
  final Set<String> unreadPaths = <String>{};
  String? selectedPath;
  int viewedStopRevision = -1;
  int additionRevision = 0;
  int attentionStartedAtMs = 0;
  int attentionUntilMs = 0;

  Map<String, Object?> toJson() => {
    'openPaths': List<String>.of(openPaths),
    'unreadPaths': unreadPaths.toList(),
    'selectedPath': selectedPath,
    'viewedStopRevision': viewedStopRevision,
    'additionRevision': additionRevision,
    'attentionStartedAtMs': attentionStartedAtMs,
    'attentionUntilMs': attentionUntilMs,
  };

  void applyJson(Map<String, dynamic> data) {
    openPaths
      ..clear()
      ..addAll(
        (data['openPaths'] as List? ?? const [])
            .whereType<String>()
            .where((path) => path.isNotEmpty)
            .toSet(),
      );
    unreadPaths
      ..clear()
      ..addAll(
        (data['unreadPaths'] as List? ?? const []).whereType<String>().where(
          openPaths.contains,
        ),
      );
    final selected = data['selectedPath'];
    selectedPath = selected is String && openPaths.contains(selected)
        ? selected
        : null;
    viewedStopRevision = (data['viewedStopRevision'] as int?) ?? -1;
    additionRevision = (data['additionRevision'] as int?) ?? 0;
    attentionStartedAtMs = (data['attentionStartedAtMs'] as int?) ?? 0;
    attentionUntilMs = (data['attentionUntilMs'] as int?) ?? 0;
  }
}

class DebugState {
  DebugExecutionState executionState = DebugExecutionState.unavailable;
  final List<String> sourceFiles = <String>[];
  final Map<String, Set<int>> executableLines = <String, Set<int>>{};
  final Map<String, Set<int>> requestedBreakpoints = <String, Set<int>>{};
  final List<DebugBreakpoint> resolvedBreakpoints = <DebugBreakpoint>[];
  final Map<String, int> registers = <String, int>{};
  String? currentSource;
  int? currentLine;
  int? programCounter;
  int stopRevision = 0;
  String sourceRoot = '';
}

class ConnectionState {
  ConnectionStatus status = ConnectionStatus.disconnected;
  String probeType = '自动发现任意探针';
  String targetName = 'auto';
  String swdClock = '4 MHz';
  String serialNumber = '';
  String connectionKind = 'local';
  int? gatewayProtocolVersion;
  final Map<String, String> remoteConfig = {
    'host': '127.0.0.1',
    'gatewayPort': '4242',
    'gdbPort': '3333',
    'token': '',
    'gdbPath': '',
    'core': '0',
    'rttDelivery': 'reliable',
  };
  String symbolFile = '';
  Map<String, dynamic>? lastError;
}

class AcquisitionState {
  Map<String, dynamic> rawRecording = <String, dynamic>{};
  double sampleRateHz = 50;
  double rttSampleRateHz = 1000;
  String displayRefreshMode = 'standard';
  double elapsedSeconds = 0;
  bool samplingPaused = false;
  bool rttEnabled = false;
  String rttProtocol = 'normal';
  Map<String, dynamic> performanceStats = <String, dynamic>{};
}

class PlotState {
  String? highlightedWatchKey;
  int watchSelectionRevision = 0;
  bool plottingPaused = false;
  bool followLatest = true;
  double visibleWindowSeconds = 12;
  double retentionSeconds = 60;
  bool autoY = true;
  double? yMin;
  double? yMax;
  bool showGrid = true;
  bool showLegend = true;
  bool mouseXEnabled = true;
  bool mouseYEnabled = true;
  bool invertX = false;
  bool invertY = false;
}
