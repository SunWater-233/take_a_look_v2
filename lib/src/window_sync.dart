import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'panel_types.dart';
import 'protocol/commands.dart';

const _mainChannel = WindowMethodChannel(
  'take_a_look/main_state',
  mode: ChannelMode.unidirectional,
);

const configureDetachedPanelMethod = 'configureDetachedPanel';
const releaseDetachedWindowMethod = 'releaseDetachedWindow';
const prepareTabDragPreviewMethod = 'prepareTabDragPreview';
const showTabDragPreviewMethod = 'showTabDragPreview';
const hideTabDragPreviewMethod = 'hideTabDragPreview';
const tabDragPreviewSessionKey = 'previewSession';

class MainWindowSync {
  MainWindowSync(this.controller);

  final TakeALookController controller;
  final Map<WorkspacePanelId, WindowController> _windows =
      <WorkspacePanelId, WindowController>{};
  final Map<WorkspacePanelId, Map<String, int>> _telemetryCursors =
      <WorkspacePanelId, Map<String, int>>{};
  Timer? _stateBroadcastTimer;
  Timer? _telemetryBroadcastTimer;
  bool _telemetryBroadcasting = false;
  bool _telemetryBroadcastPending = false;
  bool _started = false;
  final StreamController<String> _detachedWindowReleases =
      StreamController<String>.broadcast(sync: true);

  bool get isStarted => _started;
  Stream<String> get detachedWindowReleases => _detachedWindowReleases.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _mainChannel.setMethodCallHandler(_handleCall);
    controller.stateSyncChanges.addListener(_scheduleStateBroadcast);
    controller.telemetrySyncChanges.addListener(_scheduleTelemetryBroadcast);
  }

  void registerWindow(WorkspacePanelId panel, WindowController window) {
    _windows[panel] = window;
    _telemetryCursors[panel] = controller.telemetryCursors();
    _scheduleStateBroadcast();
    _scheduleTelemetryBroadcast();
  }

  void unregisterWindow(WorkspacePanelId panel) {
    _windows.remove(panel);
    _telemetryCursors.remove(panel);
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'snapshot') return controller.snapshot();
    if (call.method == releaseDetachedWindowMethod) {
      final arguments = call.arguments;
      if (arguments is Map && arguments['windowId'] is String) {
        reportDetachedWindowReleased(arguments['windowId'] as String);
      }
      return null;
    }
    return controller.handleCommand(
      ControllerCommand.parse(call.method),
      call.arguments,
    );
  }

  void reportDetachedWindowReleased(String windowId) {
    if (!_detachedWindowReleases.isClosed) {
      _detachedWindowReleases.add(windowId);
    }
  }

  void _scheduleStateBroadcast() {
    if (_windows.isEmpty || _stateBroadcastTimer?.isActive == true) return;
    _stateBroadcastTimer = Timer(
      const Duration(milliseconds: 20),
      () => _broadcast('state', controller.stateSnapshot()),
    );
  }

  void _scheduleTelemetryBroadcast() {
    if (_telemetryBroadcasting) {
      _telemetryBroadcastPending = true;
      return;
    }
    if (_windows.isEmpty || _telemetryBroadcastTimer?.isActive == true) return;
    _telemetryBroadcastTimer = Timer(
      const Duration(milliseconds: 80),
      _broadcastTelemetry,
    );
  }

  Future<void> _broadcastTelemetry() async {
    _telemetryBroadcasting = true;
    try {
      for (final entry in _windows.entries) {
        final data = controller.telemetryDeltaSnapshot(
          _telemetryCursors[entry.key] ?? const <String, int>{},
        );
        try {
          await entry.value.invokeMethod<void>('telemetryDelta', data);
          final nextCursors = <String, int>{};
          for (final raw in data['watches'] as List? ?? const []) {
            final watch = Map<String, dynamic>.from(raw as Map);
            final key = watch['key'];
            final cursor = watch['sampleCursor'];
            if (key is String && cursor is int) nextCursors[key] = cursor;
          }
          _telemetryCursors[entry.key] = nextCursors;
        } on Object {
          // The next successful delivery resumes from the last acknowledged cursor.
        }
      }
    } finally {
      _telemetryBroadcasting = false;
      if (_telemetryBroadcastPending) {
        _telemetryBroadcastPending = false;
        _scheduleTelemetryBroadcast();
      }
    }
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
    await _detachedWindowReleases.close();
  }
}

Future<void> initializeDetachedWindow(
  TakeALookController controller, {
  Future<void> Function(DetachedPanelLaunch configuration)? onConfigure,
  Future<void> Function(DetachedPanelLaunch configuration, int session)?
  onPrepareTabDragPreview,
  Future<void> Function(Offset screenPosition, int session)?
  onShowTabDragPreview,
  Future<void> Function(int session)? onHideTabDragPreview,
}) async {
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
    } else if (call.method == 'telemetryDelta' && call.arguments is Map) {
      controller.applyTelemetryDelta(
        Map<String, dynamic>.from(call.arguments as Map),
      );
    } else if (call.method == configureDetachedPanelMethod) {
      final configuration = detachedPanelLaunchFromJson(call.arguments);
      if (configuration == null) {
        throw ArgumentError.value(call.arguments, 'configuration');
      }
      await onConfigure?.call(configuration);
    } else if (call.method == prepareTabDragPreviewMethod) {
      final configuration = detachedPanelLaunchFromJson(call.arguments);
      final arguments = call.arguments;
      final session = arguments is Map
          ? arguments[tabDragPreviewSessionKey]
          : null;
      if (configuration == null ||
          configuration.role != SecondaryWindowRole.dragPreview ||
          session is! int) {
        throw ArgumentError.value(call.arguments, 'preview');
      }
      await onPrepareTabDragPreview?.call(configuration, session);
    } else if (call.method == showTabDragPreviewMethod) {
      final arguments = call.arguments;
      if (arguments is! Map ||
          arguments[tabDragPreviewSessionKey] is! int ||
          arguments['x'] is! num ||
          arguments['y'] is! num) {
        throw ArgumentError.value(arguments, 'position');
      }
      await onShowTabDragPreview?.call(
        Offset(
          (arguments['x'] as num).toDouble(),
          (arguments['y'] as num).toDouble(),
        ),
        arguments[tabDragPreviewSessionKey] as int,
      );
    } else if (call.method == hideTabDragPreviewMethod) {
      final arguments = call.arguments;
      if (arguments is! Map || arguments[tabDragPreviewSessionKey] is! int) {
        throw ArgumentError.value(arguments, 'preview session');
      }
      await onHideTabDragPreview?.call(
        arguments[tabDragPreviewSessionKey] as int,
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

Future<void> releaseDetachedWindow() async {
  final currentWindow = await WindowController.fromCurrentEngine();
  await _mainChannel.invokeMethod<void>(releaseDetachedWindowMethod, {
    'windowId': currentWindow.windowId,
  });
}

Future<void> sendCommandToMain(
  TakeALookController controller,
  ControllerCommand command,
  Object? arguments,
) async {
  final state = await _mainChannel.invokeMethod<Map<Object?, Object?>>(
    command.wireName,
    arguments,
  );
  if (state != null) {
    controller.applySnapshot(Map<String, dynamic>.from(state));
  }
}
