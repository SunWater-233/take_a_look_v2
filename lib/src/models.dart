import 'dart:ui';

enum ConnectionStatus { disconnected, connecting, connected }

class SymbolItem {
  const SymbolItem({
    required this.source,
    required this.name,
    required this.address,
    required this.type,
    required this.size,
  });

  final String source;
  final String name;
  final int address;
  final String type;
  final int size;

  String get key => '${address.toRadixString(16)}:$name';
  String get addressLabel =>
      '0x${address.toRadixString(16).padLeft(8, '0').toUpperCase()}';

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
  final Color color;
  final List<Offset> samples = <Offset>[];
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

  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}';
  }
}
