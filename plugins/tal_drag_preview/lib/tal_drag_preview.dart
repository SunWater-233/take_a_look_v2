import 'package:flutter/services.dart';

abstract final class TalDragPreview {
  static const _channel = MethodChannel('take_a_look/drag_preview_window');

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
