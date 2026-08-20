import 'package:flutter/services.dart';

abstract final class TalDragPreview {
  static const _channel = MethodChannel('take_a_look/drag_preview_window');

  static Future<void> setClickThrough(bool enabled) {
    return _channel.invokeMethod<void>('setClickThrough', {'enabled': enabled});
  }
}
