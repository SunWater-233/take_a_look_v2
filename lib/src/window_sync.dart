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
  Timer? _broadcastTimer;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _mainChannel.setMethodCallHandler(_handleCall);
    controller.addListener(_scheduleBroadcast);
  }

  void registerWindow(WorkspacePanelId panel, WindowController window) {
    _windows[panel] = window;
    _scheduleBroadcast();
  }

  void unregisterWindow(WorkspacePanelId panel) {
    _windows.remove(panel);
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'snapshot') return controller.snapshot();
    return controller.handleCommand(call.method, call.arguments);
  }

  void _scheduleBroadcast() {
    if (_windows.isEmpty || _broadcastTimer?.isActive == true) return;
    _broadcastTimer = Timer(const Duration(milliseconds: 80), _broadcast);
  }

  Future<void> _broadcast() async {
    final state = controller.snapshot();
    final failed = <WorkspacePanelId>[];
    for (final entry in _windows.entries) {
      try {
        await entry.value.invokeMethod<void>('state', state);
      } on Object {
        failed.add(entry.key);
      }
    }
    for (final panel in failed) {
      _windows.remove(panel);
    }
  }

  Future<void> dispose() async {
    controller.removeListener(_scheduleBroadcast);
    _broadcastTimer?.cancel();
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
