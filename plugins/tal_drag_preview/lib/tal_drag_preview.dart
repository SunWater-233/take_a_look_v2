import 'package:flutter/services.dart';

abstract final class TalDragPreview {
  static const _channel = MethodChannel('take_a_look/drag_preview_window');

  /// Set from the actual GDK display, not XDG_SESSION_TYPE (XWayland also runs
  /// inside a Wayland session). Other platforms keep their existing path.
  static bool nativeWayland = false;
  static String currentWindowId = 'main';
  static bool debugNativeDrag = false;

  static Future<void> initializeLinux() async {
    final capabilities = await _channel.invokeMapMethod<String, Object?>(
      'getCapabilities',
    );
    nativeWayland = capabilities?['nativeWayland'] == true;
  }

  static void setNativeDragHandler(
    Future<bool> Function(String phase, Map<Object?, Object?> arguments)?
    handler,
  ) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method != 'nativeTabDrag' || call.arguments is! Map) {
                return false;
              }
              final arguments = Map<Object?, Object?>.from(
                call.arguments as Map,
              );
              final phase = arguments['phase'];
              return phase is String ? handler(phase, arguments) : false;
            },
    );
  }

  /// Completes when the compositor finishes the drag. A rejected target and an
  /// Escape cancellation are distinct so cancellation never detaches a panel.
  static Future<String> beginNativeTabDrag(
    Map<String, Object?> arguments,
  ) async {
    return await _channel.invokeMethod<String>('beginTabDrag', arguments) ??
        'cancelled';
  }

  static Future<void> setClickThrough(bool enabled) {
    return _channel.invokeMethod<void>('setClickThrough', {'enabled': enabled});
  }

  /// Windows preview positioning must not activate the preview window.
  static Future<void> showInactiveAt(
    Offset position, {
    required double devicePixelRatio,
  }) {
    return _channel.invokeMethod<void>('showInactiveAt', {
      'x': position.dx,
      'y': position.dy,
      'devicePixelRatio': devicePixelRatio,
    });
  }
}
