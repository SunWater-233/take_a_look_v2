import 'package:flutter/foundation.dart';

class ControllerSignal extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// Domain-specific invalidation channels used by focused UI subtrees.
class ControllerSignals {
  final ControllerSignal connection = ControllerSignal();
  final ControllerSignal sampling = ControllerSignal();
  final ControllerSignal symbols = ControllerSignal();
  final ControllerSignal symbolLoad = ControllerSignal();
  final ControllerSignal watches = ControllerSignal();
  final ControllerSignal telemetry = ControllerSignal();
  final ControllerSignal plot = ControllerSignal();
  final ControllerSignal plotControls = ControllerSignal();
  final ControllerSignal analysis = ControllerSignal();
  final ControllerSignal clock = ControllerSignal();
  final ControllerSignal logs = ControllerSignal();
  final ControllerSignal debug = ControllerSignal();
  final ControllerSignal sourceWorkspace = ControllerSignal();
  final ControllerSignal stateSync = ControllerSignal();
  final ControllerSignal telemetrySync = ControllerSignal();

  void dispose() {
    connection.dispose();
    sampling.dispose();
    symbols.dispose();
    symbolLoad.dispose();
    watches.dispose();
    telemetry.dispose();
    plot.dispose();
    plotControls.dispose();
    analysis.dispose();
    clock.dispose();
    logs.dispose();
    debug.dispose();
    sourceWorkspace.dispose();
    stateSync.dispose();
    telemetrySync.dispose();
  }
}
