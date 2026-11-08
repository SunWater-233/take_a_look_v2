import 'dart:ui';
import 'dart:typed_data';

import '../telemetry/sample_buffer.dart';

export 'symbol_load_progress.dart';
export 'source_definition.dart';

enum ConnectionStatus { disconnected, connecting, connected }

enum DebugExecutionState { unavailable, running, halted, unknown }

class DebugBreakpoint {
  const DebugBreakpoint({
    required this.path,
    required this.requestedLine,
    required this.actualLine,
    required this.verified,
    this.address,
    this.message,
  });

  final String path;
  final int requestedLine;
  final int actualLine;
  final bool verified;
  final int? address;
  final String? message;

  factory DebugBreakpoint.fromJson(Map<String, dynamic> json) {
    return DebugBreakpoint(
      path: json['path'] as String,
      requestedLine: json['requestedLine'] as int,
      actualLine: json['actualLine'] as int? ?? json['requestedLine'] as int,
      verified: json['verified'] == true,
      address: json['address'] as int?,
      message: json['message'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'requestedLine': requestedLine,
    'actualLine': actualLine,
    'verified': verified,
    if (address != null) 'address': address,
    if (message != null) 'message': message,
  };
}

class SymbolItem {
  const SymbolItem({
    required this.source,
    required this.name,
    required this.address,
    required this.type,
    required this.size,
    this.section = '',
    this.backendKey,
    this.writable = true,
    this.dataSource = 'memory',
    this.encoding = '',
    this.diagnostic = '',
  });

  final String source;
  final String name;
  final int address;
  final String type;
  final int size;
  final String section;
  final String? backendKey;
  final bool writable;
  final String dataSource;
  final String encoding;
  final String diagnostic;

  factory SymbolItem.fromJson(Map<String, dynamic> json) {
    return SymbolItem(
      source: json['source'] as String,
      name: json['name'] as String,
      address: json['address'] as int,
      type: json['type'] as String,
      size: json['size'] as int,
      section: json['section'] as String? ?? '',
      backendKey: json['key'] as String?,
      writable: json['writable'] != false,
      dataSource: json['dataSource'] as String? ?? 'memory',
      encoding: json['encoding'] as String? ?? '',
      diagnostic: json['diagnostic'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'source': source,
    'name': name,
    'address': address,
    'type': type,
    'size': size,
    'section': section,
    'key': key,
    'writable': writable,
    'dataSource': dataSource,
    if (encoding.isNotEmpty) 'encoding': encoding,
    if (diagnostic.isNotEmpty) 'diagnostic': diagnostic,
  };

  String get key => backendKey ?? '${address.toRadixString(16)}:$name';
  String get addressLabel => dataSource == 'rtt'
      ? 'RTT'
      : '0x${address.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  bool matches(String query) {
    final value = query.trim().toLowerCase();
    return value.isEmpty ||
        name.toLowerCase().contains(value) ||
        source.toLowerCase().contains(value) ||
        type.toLowerCase().contains(value) ||
        addressLabel.toLowerCase().contains(value);
  }
}

enum WatchReadMode {
  monitor,
  capture,
  manual;

  String get label => switch (this) {
    monitor => '仅监视',
    capture => '采集',
    manual => '手动读取',
  };

  static WatchReadMode parse(Object? value, {bool sampling = true}) =>
      values.where((mode) => mode.name == value).firstOrNull ??
      (sampling ? capture : monitor);
}

class WatchItem {
  WatchItem({required this.symbol, required this.color, SampleBuffer? samples})
    : samples = samples ?? SampleBuffer();

  final SymbolItem symbol;
  Color color;
  final SampleBuffer samples;
  int totalSampleCount = 0;
  double historyStartSeconds = 0;
  WatchReadMode readMode = WatchReadMode.capture;
  double? monitorRateHz;
  int? updatedAtMs;
  bool get samplingEnabled => readMode == WatchReadMode.capture;
  set samplingEnabled(bool value) =>
      readMode = value ? WatchReadMode.capture : WatchReadMode.monitor;
  bool plotted = false;
  bool pinned = false;
  double value = 0;
  String? valueIssue;

  Object get wireValue => valueIssue ?? value;

  bool applyValue(Object? raw) {
    if (raw is num || raw is bool) {
      value = raw is num ? raw.toDouble() : (raw == true ? 1 : 0);
      valueIssue = null;
      return true;
    }
    valueIssue = raw == null || raw == '' ? null : raw.toString();
    return false;
  }

  String? get valueDiagnostic {
    if (symbol.diagnostic.isNotEmpty) return symbol.diagnostic;
    if (symbol.encoding == 'unsupported') return '暂不支持该类型的数值解码';
    if (symbol.encoding == 'bytes') return '该变量为复合类型，请展开成员查看数值';
    if (valueIssue != null) return '无法解码为数值：$valueIssue';
    return null;
  }

  bool get isFloatingPoint =>
      symbol.encoding == 'float' ||
      (symbol.encoding.isEmpty &&
          (symbol.type.contains('float') || symbol.type.contains('double')));

  /// Decimal digits sufficient to round-trip the target's IEEE floating type.
  int get valuePrecision => symbol.size == 8 ? 17 : 9;

  String get editValueLabel {
    if (valueDiagnostic != null) return '';
    if (!isFloatingPoint) return valueLabel;
    final typedValue = symbol.size == 4
        ? Float32List.fromList([value]).single
        : value;
    return typedValue.toStringAsPrecision(valuePrecision);
  }

  String get valueLabel {
    if (symbol.diagnostic.isNotEmpty) return '解析失败';
    if (symbol.encoding == 'unsupported') return '类型不支持';
    if (symbol.encoding == 'bytes') return '非标量';
    if (valueIssue != null) return '无法解码';
    if (!value.isFinite) return value.toString();
    if (symbol.encoding == 'bool' ||
        const {'bool', '_Bool'}.contains(symbol.type)) {
      return value >= 0.5 ? 'true' : 'false';
    }
    if (isFloatingPoint) {
      return value.toStringAsFixed(4);
    }
    return value.round().toString();
  }
}

enum LogLevel {
  debug,
  info,
  warning,
  error,
  critical;

  static LogLevel parse(String? value) {
    return values.firstWhere(
      (level) => level.name == value?.toLowerCase(),
      orElse: () => info,
    );
  }
}

class LogEntry {
  LogEntry(this.message, {this.level = LogLevel.info})
    : timestamp = DateTime.now();
  LogEntry.at(this.message, this.timestamp, {this.level = LogLevel.info});

  final DateTime timestamp;
  final String message;
  final LogLevel level;

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry.at(
      json['message'] as String,
      DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      level: LogLevel.parse(json['level'] as String?),
    );
  }

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.millisecondsSinceEpoch,
    'message': message,
    'level': level.name,
  };

  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}';
  }
}
