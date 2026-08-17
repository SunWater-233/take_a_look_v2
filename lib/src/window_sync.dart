import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'panel_types.dart';

const _mainChannel = WindowMethodChannel(
  'take_a_look/main_state',
  mode: ChannelMode.unidirectional,
);

class MainWindowSync {
  MainWindowSync(this.controller);

  final TakeALookController controller;
  final Map<WorkspacePanelId, WindowController> _windows =
      <WorkspacePanelId, WindowController>{};
  Timer? _stateBroadcastTimer;
  Timer? _telemetryBroadcastTimer;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _mainChannel.setMethodCallHandler(_handleCall);
    controller.stateSyncChanges.addListener(_scheduleStateBroadcast);
    controller.telemetrySyncChanges.addListener(_scheduleTelemetryBroadcast);
  }

  void registerWindow(WorkspacePanelId panel, WindowController window) {
    _windows[panel] = window;
    _scheduleStateBroadcast();
    _scheduleTelemetryBroadcast();
  }

  void unregisterWindow(WorkspacePanelId panel) {
    _windows.remove(panel);
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'snapshot') return controller.snapshot();
    return controller.handleCommand(call.method, call.arguments);
  }

  void _scheduleStateBroadcast() {
    if (_windows.isEmpty || _stateBroadcastTimer?.isActive == true) return;
    _stateBroadcastTimer = Timer(
      const Duration(milliseconds: 20),
      () => _broadcast('state', controller.stateSnapshot()),
    );
  }

  void _scheduleTelemetryBroadcast() {
    if (_windows.isEmpty || _telemetryBroadcastTimer?.isActive == true) return;
    _telemetryBroadcastTimer = Timer(
      const Duration(milliseconds: 80),
      () => _broadcast('telemetry', controller.telemetrySnapshot()),
    );
  }

  Future<void> _broadcast(String method, Map<String, dynamic> state) async {
    for (final entry in _windows.entries) {
      try {
        await entry.value.invokeMethod<void>(method, state);
      } on Object {
        // Window lifecycle reconciliation removes closed windows. A newly
        // created window may not have installed its handler yet, so a single
        // failed delivery must not unregister it.
      }
    }
  }

  Future<void> dispose() async {
    controller.stateSyncChanges.removeListener(_scheduleStateBroadcast);
    controller.telemetrySyncChanges.removeListener(_scheduleTelemetryBroadcast);
    _stateBroadcastTimer?.cancel();
    _telemetryBroadcastTimer?.cancel();
    if (_started) await _mainChannel.setMethodCallHandler(null);
  }
}

Future<void> initializeDetachedWindow(TakeALookController controller) async {
  final currentWindow = await WindowController.fromCurrentEngine();
  await currentWindow.setWindowMethodHandler((call) async {
    if (call.method == 'state' && call.arguments is Map) {
      controller.applySnapshot(
        Map<String, dynamic>.from(call.arguments as Map),
      );
    } else if (call.method == 'telemetry' && call.arguments is Map) {
      controller.applyTelemetrySnapshot(
        Map<String, dynamic>.from(call.arguments as Map),
      );
    }
    return null;
  });
  final state = await _mainChannel.invokeMethod<Map<Object?, Object?>>(
    'snapshot',
  );
  if (state != null) {
    controller.applySnapshot(Map<String, dynamic>.from(state));
  }
}

Future<void> sendCommandToMain(
  TakeALookController controller,
  String method,
  Object? arguments,
) async {
  final state = await _mainChannel.invokeMethod<Map<Object?, Object?>>(
    method,
    arguments,
  );
  if (state != null) {
    controller.applySnapshot(Map<String, dynamic>.from(state));
  }
}
