import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

enum PlotPinchAxes {
  x,
  y,
  both;

  static PlotPinchAxes fromSeparation(Offset separation) {
    final angle = math.atan2(separation.dy.abs(), separation.dx.abs());
    if (angle <= math.pi / 8) return x;
    if (angle >= 3 * math.pi / 8) return y;
    return both;
  }
}

typedef TrackpadContacts = ({Offset center, Offset separation});

class PlotTrackpadContactGesture {
  PlotTrackpadContactGesture(this._previous);

  TrackpadContacts _previous;
  bool _panning = false;
  PlotPinchAxes? _pinchAxes;

  ({Offset pan, double scale, PlotPinchAxes? axes})? update(
    TrackpadContacts contacts,
  ) {
    final pan = contacts.center - _previous.center;
    final previousSpan = _previous.separation.distance;
    final span = contacts.separation.distance;
    if (previousSpan == 0 || span == 0) return null;
    if (!_panning && _pinchAxes == null) {
      final spanChange = (span - previousSpan).abs();
      final translation = pan.distance;
      // Allow a small amount of drift before deciding between pan and pinch.
      if (math.max(spanChange, translation) < 3) return null;
      if (spanChange > translation) {
        _pinchAxes = PlotPinchAxes.fromSeparation(contacts.separation);
      } else {
        _panning = true;
      }
    }
    _previous = contacts;
    return (pan: pan, scale: span / previousSpan, axes: _pinchAxes);
  }
}

abstract final class PlotTrackpad {
  static const _channel = OptionalMethodChannel('take_a_look/plot_trackpad');

  static final Stream<({String method, List<double>? values})> events =
      _createEvents();

  static Stream<({String method, List<double>? values})> _createEvents() {
    final events =
        StreamController<({String method, List<double>? values})>.broadcast(
          sync: true,
        );
    _channel.setMethodCallHandler((call) async {
      events.add((
        method: call.method,
        values: (call.arguments as List<Object?>?)?.cast<double>(),
      ));
    });
    return events.stream;
  }

  static Future<void> setCapture(bool enabled) =>
      _channel.invokeMethod<void>('setCapture', enabled);
}
