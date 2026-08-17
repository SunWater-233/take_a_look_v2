import 'package:flutter/foundation.dart';

class ControllerSignal extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// Domain-specific invalidation channels used by focused UI subtrees.
class ControllerSignals {
  final ControllerSignal connection = ControllerSignal();
  final ControllerSignal sampling = ControllerSignal();
  final ControllerSignal symbols = ControllerSignal();
  final ControllerSignal watches = ControllerSignal();
  final ControllerSignal telemetry = ControllerSignal();
  final ControllerSignal plot = ControllerSignal();
  final ControllerSignal plotControls = ControllerSignal();
  final ControllerSignal clock = ControllerSignal();
  final ControllerSignal logs = ControllerSignal();
  final ControllerSignal stateSync = ControllerSignal();
  final ControllerSignal telemetrySync = ControllerSignal();

  void dispose() {
    connection.dispose();
    sampling.dispose();
    symbols.dispose();
    watches.dispose();
    telemetry.dispose();
    plot.dispose();
    plotControls.dispose();
    clock.dispose();
    logs.dispose();
    stateSync.dispose();
    telemetrySync.dispose();
  }
}
