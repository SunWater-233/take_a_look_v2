import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import '../controller/controller.dart';
import 'panel_types.dart';
import 'window_sync_target.dart';
import '../protocol/commands.dart';

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
const detachedTabDragStartMethod = 'detachedTabDragStart';
const detachedTabDragUpdateMethod = 'detachedTabDragUpdate';
const detachedTabDragEndMethod = 'detachedTabDragEnd';
const getDetachedWindowBoundsMethod = 'getDetachedWindowBounds';

enum DetachedTabDragPhase { start, update, end }

class DetachedTabDragEvent {
  const DetachedTabDragEvent({
    required this.phase,
    required this.sourceWindowId,
    required this.panel,
    this.screenPosition,
    this.previewSize,
  });

  final DetachedTabDragPhase phase;
  final String sourceWindowId;
  final WorkspacePanelId panel;
  final Offset? screenPosition;
  final Size? previewSize;
}

class MainWindowSync {
  MainWindowSync(this.controller);

  final TakeALookController controller;
  final Map<WorkspacePanelId, WindowController> _windows =
      <WorkspacePanelId, WindowController>{};
  final Map<String, WindowSyncTarget> _targets = {};
  Timer? _stateBroadcastTimer;
  Timer? _telemetryBroadcastTimer;
  bool _started = false;
  final StreamController<String> _detachedWindowReleases =
      StreamController<String>.broadcast(sync: true);
  final StreamController<DetachedTabDragEvent> _detachedTabDrags =
      StreamController<DetachedTabDragEvent>.broadcast(sync: true);

  bool get isStarted => _started;
  Stream<String> get detachedWindowReleases => _detachedWindowReleases.stream;
  Stream<DetachedTabDragEvent> get detachedTabDrags => _detachedTabDrags.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _mainChannel.setMethodCallHandler(_handleCall);
    controller.stateSyncChanges.addListener(_scheduleStateBroadcast);
    controller.symbolLoadChanges.addListener(_broadcastSymbolLoad);
    controller.telemetrySyncChanges.addListener(_scheduleTelemetryBroadcast);
  }

  WindowSyncTarget _target(WindowController window) => _targets.putIfAbsent(
    window.windowId,
    () => WindowSyncTarget(
      controller,
      (method, data) => window.invokeMethod<void>(method, data),
    ),
  );

  Future<void> prepareWindow(
    WindowController window,
    Iterable<WorkspacePanelId> panels,
  ) {
    return _target(window).initialize(
      includeHistory:
          panels.contains(WorkspacePanelId.plot) ||
          panels.contains(WorkspacePanelId.analysis),
      includeAnalysis: panels.contains(WorkspacePanelId.analysis),
    );
  }

  void registerWindow(WorkspacePanelId panel, WindowController window) {
    _windows[panel] = window;
    _target(window).active = true;
    _scheduleStateBroadcast();
    _scheduleTelemetryBroadcast();
  }

  void unregisterWindow(WorkspacePanelId panel) {
    final window = _windows.remove(panel);
    if (window != null &&
        !_windows.values.any((w) => w.windowId == window.windowId)) {
      _targets[window.windowId]?.deactivate();
    }
  }

  Future<void> syncAnalysisSessionTo(WindowController window) =>
      prepareWindow(window, const [WorkspacePanelId.analysis]);

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'targetCatalog') {
      final envelope = Map<String, dynamic>.from(call.arguments as Map);
      return controller.requestTargetCatalog(
        envelope['operation'] as String,
        Map<String, Object?>.from(envelope['arguments'] as Map),
      );
    }
    if (call.method == 'snapshot') {
      // Prewarmed windows need metadata only. Assignment supplies the exact
      // history and analysis dataset before the window becomes visible.
      return controller.snapshot(includeSamples: false);
    }
    if (call.method == 'command') {
      final envelope = Map<String, dynamic>.from(call.arguments as Map);
      final versions = controller.snapshotVersions();
      await controller.handleCommand(
        ControllerCommand.parse(envelope['name'] as String),
        envelope['arguments'],
        includeResultState: false,
      );
      final target = _targets[envelope['windowId']];
      if (target != null && target.active) {
        await target.flushState();
        return null;
      }
      return controller.stateDeltaSnapshot(versions);
    }
    if (call.method == releaseDetachedWindowMethod) {
      final arguments = call.arguments;
      if (arguments is Map && arguments['windowId'] is String) {
        reportDetachedWindowReleased(arguments['windowId'] as String);
      }
      return null;
    }
    final dragPhase = switch (call.method) {
      detachedTabDragStartMethod => DetachedTabDragPhase.start,
      detachedTabDragUpdateMethod => DetachedTabDragPhase.update,
      detachedTabDragEndMethod => DetachedTabDragPhase.end,
      _ => null,
    };
    if (dragPhase != null) {
      final event = _parseDetachedTabDrag(call.arguments, dragPhase);
      if (event != null && !_detachedTabDrags.isClosed) {
        _detachedTabDrags.add(event);
      }
      return null;
    }
    return controller.handleCommand(
      ControllerCommand.parse(call.method),
      call.arguments,
    );
  }

  void reportDetachedWindowReleased(String windowId) {
    controller.removeSourceViewsForWindow(windowId);
    if (!_detachedWindowReleases.isClosed) {
      _detachedWindowReleases.add(windowId);
    }
  }

  void _scheduleStateBroadcast() {
    if (_windows.isEmpty || _stateBroadcastTimer?.isActive == true) return;
    _stateBroadcastTimer = Timer(const Duration(milliseconds: 20), () {
      for (final target in _targets.values) {
        if (target.active) target.requestState();
      }
    });
  }

  void _broadcastSymbolLoad() {
    for (final target in _targets.values) {
      if (target.active) target.requestState();
    }
  }

  void _scheduleTelemetryBroadcast() {
    if (_windows.isEmpty || _telemetryBroadcastTimer?.isActive == true) return;
    _telemetryBroadcastTimer = Timer(const Duration(milliseconds: 80), () {
      for (final target in _targets.values) {
        if (target.active) target.requestTelemetry();
      }
    });
  }

  Future<void> dispose() async {
    for (final window in _windows.values) {
      controller.removeSourceViewsForWindow(window.windowId);
    }
    controller.stateSyncChanges.removeListener(_scheduleStateBroadcast);
    controller.symbolLoadChanges.removeListener(_broadcastSymbolLoad);
    controller.telemetrySyncChanges.removeListener(_scheduleTelemetryBroadcast);
    for (final target in _targets.values) {
      target.dispose();
    }
    _targets.clear();
    _stateBroadcastTimer?.cancel();
    _telemetryBroadcastTimer?.cancel();
    if (_started) await _mainChannel.setMethodCallHandler(null);
    await _detachedWindowReleases.close();
    await _detachedTabDrags.close();
  }
}

DetachedTabDragEvent? _parseDetachedTabDrag(
  Object? arguments,
  DetachedTabDragPhase phase,
) {
  if (arguments is! Map ||
      arguments['windowId'] is! String ||
      arguments['panel'] is! String) {
    return null;
  }
  final panelName = arguments['panel'] as String;
  final panel = WorkspacePanelId.values
      .where((candidate) => candidate.name == panelName)
      .firstOrNull;
  if (panel == null) return null;
  final x = arguments['x'];
  final y = arguments['y'];
  final width = arguments['width'];
  final height = arguments['height'];
  return DetachedTabDragEvent(
    phase: phase,
    sourceWindowId: arguments['windowId'] as String,
    panel: panel,
    screenPosition: x is num && y is num
        ? Offset(x.toDouble(), y.toDouble())
        : null,
    previewSize: width is num && height is num
        ? Size(width.toDouble(), height.toDouble())
        : null,
  );
}

Future<void> initializeDetachedWindow(
  TakeALookController controller, {
  Future<void> Function(DetachedPanelLaunch configuration)? onConfigure,
  Future<void> Function(DetachedPanelLaunch configuration, int session)?
  onPrepareTabDragPreview,
  Future<void> Function(Offset screenPosition, int session)?
  onShowTabDragPreview,
  Future<void> Function(int session)? onHideTabDragPreview,
  Future<Rect> Function()? onGetWindowBounds,
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
    } else if (call.method == getDetachedWindowBoundsMethod) {
      final bounds = await onGetWindowBounds?.call();
      return bounds == null
          ? null
          : <String, double>{
              'left': bounds.left,
              'top': bounds.top,
              'width': bounds.width,
              'height': bounds.height,
            };
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

Future<void> sendDetachedTabDrag({
  required DetachedTabDragPhase phase,
  required String windowId,
  required WorkspacePanelId panel,
  Offset? screenPosition,
  Size? previewSize,
}) {
  final method = switch (phase) {
    DetachedTabDragPhase.start => detachedTabDragStartMethod,
    DetachedTabDragPhase.update => detachedTabDragUpdateMethod,
    DetachedTabDragPhase.end => detachedTabDragEndMethod,
  };
  return _mainChannel.invokeMethod<void>(method, {
    'windowId': windowId,
    'panel': panel.name,
    if (screenPosition != null) ...{
      'x': screenPosition.dx,
      'y': screenPosition.dy,
    },
    if (previewSize != null) ...{
      'width': previewSize.width,
      'height': previewSize.height,
    },
  });
}

Future<void> releaseDetachedWindow() async {
  final currentWindow = await WindowController.fromCurrentEngine();
  await _mainChannel.invokeMethod<void>(releaseDetachedWindowMethod, {
    'windowId': currentWindow.windowId,
  });
}

Future<JsonObject> requestTargetCatalogFromMain(
  String operation,
  JsonObject arguments,
) async {
  final result = await _mainChannel.invokeMethod<Map<Object?, Object?>>(
    'targetCatalog',
    {'operation': operation, 'arguments': arguments},
  );
  return Map<String, Object?>.from(result ?? const {});
}

Future<void> sendCommandToMain(
  TakeALookController controller,
  ControllerCommand command,
  Object? arguments,
) async {
  if (command == ControllerCommand.setSourceViewVisible && arguments is Map) {
    final currentWindow = await WindowController.fromCurrentEngine();
    arguments = {
      ...Map<String, Object?>.from(arguments),
      'viewId': [
        'window',
        currentWindow.windowId,
        arguments['viewId'],
      ].join(':'),
    };
  }
  final currentWindow = await WindowController.fromCurrentEngine();
  final state = await _mainChannel
      .invokeMethod<Map<Object?, Object?>>('command', {
        'name': command.wireName,
        'arguments': arguments,
        'windowId': currentWindow.windowId,
      });
  if (state != null) {
    controller.applySnapshot(Map<String, dynamic>.from(state));
  }
}
