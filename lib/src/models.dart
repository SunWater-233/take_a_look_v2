import 'dart:ui';

enum ConnectionStatus { disconnected, connecting, connected }

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

class WatchItem {
  WatchItem({required this.symbol, required this.color});

  final SymbolItem symbol;
  Color color;
  final List<Offset> samples = <Offset>[];
  int totalSampleCount = 0;
  bool plotted = true;
  double value = 0;

  String get valueLabel {
    if (symbol.type == 'bool') {
      return value >= 0.5 ? 'true' : 'false';
    }
    if (symbol.type.contains('float') || symbol.type.contains('double')) {
      return value.toStringAsFixed(4);
    }
    return value.round().toString();
  }
}

class LogEntry {
  LogEntry(this.message) : timestamp = DateTime.now();
  LogEntry.at(this.message, this.timestamp);

  final DateTime timestamp;
  final String message;

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry.at(
      json['message'] as String,
      DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.millisecondsSinceEpoch,
    'message': message,
  };

  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}';
  }
}
