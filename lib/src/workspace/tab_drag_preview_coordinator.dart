import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'panel_types.dart';
import 'window_sync.dart';

/// Owns the single cross-platform window used only while dragging a tab.
///
/// This window is deliberately separate from the detached-window pool: its
/// always-on-top, click-through and frameless state must never leak into a
/// real, interactive panel window.
class TabDragPreviewCoordinator {
  TabDragPreviewCoordinator({this.prepareState});

  final Future<void> Function(WindowController, WorkspacePanelId)? prepareState;
  static const _warmWindowSize = Size(640, 480);
  static const _configureRetryDelay = Duration(milliseconds: 25);
  static const _configureAttempts = 200;

  WindowController? _window;
  Future<WindowController?>? _creating;
  Future<void> _commands = Future<void>.value();
  Future<void>? _movePump;
  _PendingPreviewMove? _pendingMove;
  int _session = 0;
  bool _active = false;
  bool _disposed = false;

  Future<void> prewarm() async {
    if (_disposed || _window != null) return;
    await _ensureWindow();
  }

  Future<void> prepare({required WorkspacePanelId panel, required Size size}) {
    final session = ++_session;
    _active = true;
    _pendingMove = null;
    return _queue(() async {
      if (!_isActive(session)) return;
      final window = await _ensureWindow();
      if (window == null || !_isActive(session)) return;
      await prepareState?.call(window, panel);
      if (!_isActive(session)) return;
      final arguments = DetachedPanelLaunch(
        panel: panel,
        initialSize: size,
        role: SecondaryWindowRole.dragPreview,
      ).toJson()..[tabDragPreviewSessionKey] = session;
      await _invokeWithRetry(window, prepareTabDragPreviewMethod, arguments);
    });
  }

  Future<void> showAt(Offset screenPosition) {
    if (!_active || _disposed) return Future<void>.value();
    final session = _session;
    _pendingMove = _PendingPreviewMove(session, screenPosition);
    final running = _movePump;
    if (running != null) return running;
    late final Future<void> future;
    future =
        _queue(() async {
          while (true) {
            final move = _pendingMove;
            if (move == null || move.session != session) break;
            _pendingMove = null;
            if (!_isActive(session)) break;
            final window = await _ensureWindow();
            if (window == null || !_isActive(session)) return;
            await window.invokeMethod<void>(showTabDragPreviewMethod, {
              tabDragPreviewSessionKey: session,
              'x': move.position.dx,
              'y': move.position.dy,
            });
          }
        }).whenComplete(() {
          if (identical(_movePump, future)) _movePump = null;
        });
    _movePump = future;
    return future;
  }

  Future<void> hide() {
    // Workspace pointer-up events also arrive for ordinary clicks. An idle
    // prewarmed window must not receive native window-management commands.
    if (!_active) return Future<void>.value();
    final session = _session;
    _active = false;
    _pendingMove = null;
    _movePump = null;
    // Do not make hide wait behind pointer-move round trips. Old commands carry
    // their session and are rejected by the preview window after this point.
    _commands = Future<void>.value();
    final window = _window;
    if (window == null) return Future<void>.value();
    final invalidation = window
        .invokeMethod<void>(hideTabDragPreviewMethod, {
          tabDragPreviewSessionKey: session,
        })
        .catchError((Object _) {});
    // The host engine can hide a secondary window even when that window's
    // Flutter isolate is delayed or unresponsive. Hide once immediately, then
    // once more after the session invalidation so no in-flight show can win.
    unawaited(
      invalidation.whenComplete(() async {
        if (_session != session || _active) return;
        await _hideNativeWindow(window);
      }),
    );
    return _hideNativeWindow(window);
  }

  Future<void> _hideNativeWindow(WindowController window) async {
    try {
      await window.hide();
    } on Object {
      // The preview is non-critical and may already have been destroyed.
    }
  }

  bool _isActive(int session) => !_disposed && _active && _session == session;

  Future<WindowController?> _ensureWindow() async {
    if (_disposed) return null;
    final existing = _window;
    if (existing != null) return existing;
    final creating = _creating;
    if (creating != null) return creating;
    final future = _createWindow();
    _creating = future;
    try {
      return await future;
    } on Object {
      // Drag feedback is non-critical. A failed preview must never prevent a
      // tab from being merged or detached on release.
      return null;
    } finally {
      if (identical(_creating, future)) _creating = null;
    }
  }

  Future<WindowController> _createWindow() async {
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: encodePanelArguments(
          WorkspacePanelId.header,
          _warmWindowSize,
          role: SecondaryWindowRole.dragPreview,
        ),
        hiddenAtLaunch: true,
      ),
    );
    _window = window;
    return window;
  }

  Future<void> _invokeWithRetry(
    WindowController window,
    String method,
    Object arguments,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < _configureAttempts; attempt++) {
      try {
        await window.invokeMethod<void>(method, arguments);
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

  Future<void> _queue(Future<void> Function() action) {
    final previous = _commands;
    final command = () async {
      try {
        await previous;
      } on Object {
        // A later pointer update is still useful after a failed one.
      }
      if (_disposed) return;
      try {
        await action();
      } on Object {
        // Preview failures never change the drop result.
      }
    }();
    _commands = command;
    return command;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await hide();
    } finally {
      _disposed = true;
    }
  }
}

class _PendingPreviewMove {
  const _PendingPreviewMove(this.session, this.position);

  final int session;
  final Offset position;
}
