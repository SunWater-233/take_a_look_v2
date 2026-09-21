import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'panel_types.dart';
import 'window_sync.dart';

class DetachedWindowCoordinator {
  DetachedWindowCoordinator(this.windowSync) {
    _windowChangesSubscription = onWindowsChanged.listen((_) {
      if (!_disposed) _changes.add(null);
    });
    _releaseSubscription = windowSync.detachedWindowReleases.listen(
      _releaseWindow,
    );
  }

  static const _warmWindowSize = Size(640, 480);
  static const _configureRetryDelay = Duration(milliseconds: 25);
  static const _configureAttempts = 200;

  final MainWindowSync windowSync;
  final Map<String, _PooledDetachedWindow> _pool =
      <String, _PooledDetachedWindow>{};
  final Map<WorkspacePanelId, _PooledDetachedWindow> _assignedWindows =
      <WorkspacePanelId, _PooledDetachedWindow>{};
  final List<WorkspacePanelId> _pendingReleasedPanels = <WorkspacePanelId>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  StreamSubscription<void>? _windowChangesSubscription;
  StreamSubscription<String>? _releaseSubscription;
  Future<void>? _prewarming;
  bool _disposed = false;

  Map<WorkspacePanelId, WindowController> get windows => {
    for (final entry in _assignedWindows.entries)
      entry.key: entry.value.controller,
  };

  Stream<void> get changes => _changes.stream;

  Future<void> prewarm() async {
    if (_disposed || _idleWindow != null) return;
    final running = _prewarming;
    if (running != null) return running;
    final future = _createIdleWindow();
    _prewarming = future;
    try {
      await future;
    } on Object {
      // Prewarming is only an optimization. Acquisition retries the normal
      // creation path and surfaces a real error if a window is actually used.
    } finally {
      if (identical(_prewarming, future)) _prewarming = null;
    }
  }

  Future<bool> showIfOpen(WorkspacePanelId panel) async {
    final entry = _assignedWindows[panel];
    if (entry == null) return false;
    await entry.controller.show();
    return true;
  }

  Future<String?> windowAt(
    Offset screenPosition, {
    String? excludingWindowId,
  }) async {
    for (final entry in _pool.values) {
      if ((excludingWindowId != null &&
              entry.controller.windowId == excludingWindowId) ||
          entry.panels.isEmpty ||
          entry.reserved) {
        continue;
      }
      final bounds = await _windowBounds(entry.controller);
      if (bounds?.contains(screenPosition) == true) {
        return entry.controller.windowId;
      }
    }
    return null;
  }

  Future<bool> mergePanelIntoWindow({
    required String sourceWindowId,
    required WorkspacePanelId panel,
    required String targetWindowId,
  }) async {
    final source = _pool[sourceWindowId];
    final target = _pool[targetWindowId];
    if (source == null ||
        target == null ||
        identical(source, target) ||
        !source.panels.contains(panel)) {
      return false;
    }

    final sourcePanels = List<WorkspacePanelId>.of(source.panels)
      ..remove(panel);
    final targetPanels = List<WorkspacePanelId>.of(target.panels);
    if (!targetPanels.contains(panel)) targetPanels.add(panel);
    final sourceBounds = await _windowBounds(source.controller);
    final targetBounds = await _windowBounds(target.controller);

    await _configure(
      target.controller,
      DetachedPanelLaunch(
        panel: panel,
        panels: targetPanels,
        initialSize: targetBounds?.size ?? panel.preferredWindowSize,
      ),
    );
    if (sourcePanels.isEmpty) {
      await source.controller.hide();
    } else {
      await _configure(
        source.controller,
        DetachedPanelLaunch(
          panel: sourcePanels.first,
          panels: sourcePanels,
          initialSize:
              sourceBounds?.size ?? sourcePanels.first.preferredWindowSize,
        ),
      );
    }

    _assign(
      source,
      activePanel: sourcePanels.firstOrNull,
      panels: sourcePanels,
    );
    _assign(target, activePanel: panel, panels: targetPanels);
    await target.controller.show();
    if (windowSync.isStarted) unawaited(prewarm());
    return true;
  }

  Future<bool> removePanelFromWindow({
    required String sourceWindowId,
    required WorkspacePanelId panel,
  }) async {
    final source = _pool[sourceWindowId];
    if (source == null || !source.panels.contains(panel)) return false;
    final remaining = List<WorkspacePanelId>.of(source.panels)..remove(panel);
    final bounds = await _windowBounds(source.controller);
    if (remaining.isEmpty) {
      await source.controller.hide();
    } else {
      await _configure(
        source.controller,
        DetachedPanelLaunch(
          panel: remaining.first,
          panels: remaining,
          initialSize: bounds?.size ?? remaining.first.preferredWindowSize,
        ),
      );
      await source.controller.show();
    }
    _assign(source, activePanel: remaining.firstOrNull, panels: remaining);
    if (windowSync.isStarted) unawaited(prewarm());
    return true;
  }

  Future<WindowController> acquire({
    required WorkspacePanelId activePanel,
    required List<WorkspacePanelId> panels,
    required Size initialSize,
    Offset? initialPosition,
  }) async {
    var entry = _idleWindow;
    if (entry == null) {
      final running = _prewarming;
      if (running != null) await running;
      entry = _idleWindow;
    }
    entry ??= await _createIdleWindow();
    entry.reserved = true;

    final configuration = DetachedPanelLaunch(
      panel: activePanel,
      panels: List<WorkspacePanelId>.of(panels),
      initialSize: initialSize,
      initialPosition: initialPosition,
    );
    try {
      await _configure(entry.controller, configuration);
    } on Object {
      entry.reserved = false;
      rethrow;
    }

    entry
      ..activePanel = activePanel
      ..panels = List<WorkspacePanelId>.of(panels)
      ..reserved = false;
    for (final panel in panels) {
      _assignedWindows[panel] = entry;
    }
    windowSync.registerWindow(activePanel, entry.controller);
    return entry.controller;
  }

  Future<_PooledDetachedWindow> _createIdleWindow() async {
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: encodePanelArguments(
          WorkspacePanelId.header,
          _warmWindowSize,
        ),
        hiddenAtLaunch: true,
      ),
    );
    final entry = _PooledDetachedWindow(window);
    _pool[window.windowId] = entry;
    return entry;
  }

  Future<void> _configure(
    WindowController window,
    DetachedPanelLaunch configuration,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < _configureAttempts; attempt++) {
      try {
        await window.invokeMethod<void>(
          configureDetachedPanelMethod,
          configuration.toJson(),
        );
        if (configuration.panels.contains(WorkspacePanelId.analysis) ||
            configuration.panel == WorkspacePanelId.analysis) {
          await windowSync.syncAnalysisSessionTo(window);
        }
        return;
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt + 1 < _configureAttempts) {
          await Future<void>.delayed(_configureRetryDelay);
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<Rect?> _windowBounds(WindowController window) async {
    try {
      final data = await window.invokeMethod<Map<Object?, Object?>>(
        getDetachedWindowBoundsMethod,
      );
      if (data == null ||
          data['left'] is! num ||
          data['top'] is! num ||
          data['width'] is! num ||
          data['height'] is! num) {
        return null;
      }
      return Rect.fromLTWH(
        (data['left'] as num).toDouble(),
        (data['top'] as num).toDouble(),
        (data['width'] as num).toDouble(),
        (data['height'] as num).toDouble(),
      );
    } on Object {
      return null;
    }
  }

  void _assign(
    _PooledDetachedWindow entry, {
    required WorkspacePanelId? activePanel,
    required List<WorkspacePanelId> panels,
  }) {
    final previousActive = entry.activePanel;
    if (previousActive != null) windowSync.unregisterWindow(previousActive);
    for (final previousPanel in entry.panels) {
      if (identical(_assignedWindows[previousPanel], entry)) {
        _assignedWindows.remove(previousPanel);
      }
    }
    entry
      ..activePanel = activePanel
      ..panels = List<WorkspacePanelId>.of(panels)
      ..reserved = false;
    for (final assignedPanel in panels) {
      _assignedWindows[assignedPanel] = entry;
    }
    if (activePanel != null) {
      windowSync.registerWindow(activePanel, entry.controller);
    }
  }

  _PooledDetachedWindow? get _idleWindow {
    for (final entry in _pool.values) {
      if (entry.panels.isEmpty && !entry.reserved) return entry;
    }
    return null;
  }

  void _releaseWindow(String windowId) {
    final entry = _pool[windowId];
    if (entry == null || entry.panels.isEmpty) return;
    _pendingReleasedPanels.addAll(entry.panels);
    _clearAssignment(entry);
    if (!_disposed) _changes.add(null);
  }

  void _clearAssignment(_PooledDetachedWindow entry) {
    _assign(entry, activePanel: null, panels: const <WorkspacePanelId>[]);
  }

  Future<List<WorkspacePanelId>> reconcile() async {
    final released = List<WorkspacePanelId>.of(_pendingReleasedPanels);
    _pendingReleasedPanels.clear();

    final liveWindows = await WindowController.getAll();
    final liveIds = {for (final window in liveWindows) window.windowId};
    final closedIds = _pool.keys
        .where((windowId) => !liveIds.contains(windowId))
        .toList(growable: false);
    for (final windowId in closedIds) {
      final entry = _pool.remove(windowId);
      if (entry == null) continue;
      released.addAll(entry.panels);
      _clearAssignment(entry);
    }

    if (windowSync.isStarted) unawaited(prewarm());
    return released.toSet().toList(growable: false);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _windowChangesSubscription?.cancel();
    await _releaseSubscription?.cancel();
    await _changes.close();
  }
}

class _PooledDetachedWindow {
  _PooledDetachedWindow(this.controller);

  final WindowController controller;
  WorkspacePanelId? activePanel;
  List<WorkspacePanelId> panels = <WorkspacePanelId>[];
  bool reserved = false;
}
