import 'models.dart';
import 'analysis.dart';

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
}

class ConnectionState {
  ConnectionStatus status = ConnectionStatus.disconnected;
  String probeType = '自动发现任意探针';
  String targetName = 'auto';
  String swdClock = '4 MHz';
  String serialNumber = '';
  String symbolFile = '';
  Map<String, dynamic>? lastError;
}

class AcquisitionState {
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
  bool plottingPaused = false;
  bool followLatest = true;
  double visibleWindowSeconds = 12;
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
