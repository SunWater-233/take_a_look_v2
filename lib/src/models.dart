import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

enum ProbeConnectionPhase { disconnected, connecting, connected }

extension ProbeConnectionPhaseText on ProbeConnectionPhase {
  String get label {
    switch (this) {
      case ProbeConnectionPhase.disconnected:
        return '未连接';
      case ProbeConnectionPhase.connecting:
        return '连接中';
      case ProbeConnectionPhase.connected:
        return '已连接';
    }
  }
}

class SymbolVariable {
  const SymbolVariable({
    required this.id,
    required this.path,
    required this.name,
    required this.type,
    required this.address,
    required this.size,
    required this.section,
  });

  final String id;
  final String path;
  final String name;
  final String type;
  final int address;
  final int size;
  final String section;

  String get addressLabel =>
      '0x${address.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  String get shortPath {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (parts.length <= 2) {
      return normalized;
    }
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return true;
    }
    return name.toLowerCase().contains(needle) ||
        type.toLowerCase().contains(needle) ||
        section.toLowerCase().contains(needle) ||
        path.toLowerCase().contains(needle) ||
        addressLabel.toLowerCase().contains(needle);
  }
}

class WatchVariable {
  WatchVariable({
    required this.symbol,
    required this.color,
    required this.baseline,
    required this.amplitude,
    required this.frequency,
    required this.phase,
    int capacity = 180000,
  }) : currentValue = baseline,
       writeController = TextEditingController(
         text: _formatNumberForInput(baseline),
       ),
       series = SeriesBuffer(capacity);

  final SymbolVariable symbol;
  final Color color;
  final double amplitude;
  final double frequency;
  final double phase;
  final SeriesBuffer series;
  final TextEditingController writeController;

  bool plotting = true;
  double baseline;
  double currentValue;

  String get currentLabel {
    if (symbol.type == 'bool') {
      return currentValue >= 0.5 ? 'true' : 'false';
    }
    if (symbol.type.contains('float') || symbol.type.contains('double')) {
      return currentValue.toStringAsFixed(4);
    }
    return currentValue.round().toString();
  }

  void clearSamples() {
    series.clear();
  }

  void dispose() {
    writeController.dispose();
  }

  static String _formatNumberForInput(double value) {
    if (value.abs() >= 1000 || value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(3);
  }
}

class SeriesBuffer {
  SeriesBuffer(this.capacity)
    : times = Float64List(capacity),
      values = Float64List(capacity);

  final int capacity;
  final Float64List times;
  final Float64List values;

  int _writeIndex = 0;
  int length = 0;

  bool get isEmpty => length == 0;

  void add(double time, double value) {
    times[_writeIndex] = time;
    values[_writeIndex] = value;
    _writeIndex = (_writeIndex + 1) % capacity;
    if (length < capacity) {
      length += 1;
    }
  }

  void clear() {
    _writeIndex = 0;
    length = 0;
  }

  void forEachWindow(
    double start,
    double end,
    int stride,
    void Function(double time, double value) visitor,
  ) {
    if (length == 0) {
      return;
    }
    final effectiveStride = math.max(1, stride);
    final oldestIndex = length == capacity ? _writeIndex : 0;
    var visibleIndex = 0;

    for (var offset = 0; offset < length; offset += 1) {
      final index = (oldestIndex + offset) % capacity;
      final time = times[index];
      if (time < start) {
        continue;
      }
      if (time > end) {
        break;
      }
      if (visibleIndex % effectiveStride == 0) {
        visitor(time, values[index]);
      }
      visibleIndex += 1;
    }
  }
}

class EventLogEntry {
  const EventLogEntry({
    required this.timestamp,
    required this.message,
    this.level = LogLevel.info,
  });

  final DateTime timestamp;
  final String message;
  final LogLevel level;

  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}';
  }
}

enum LogLevel { info, success, warning, error }
