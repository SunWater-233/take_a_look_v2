enum BreakpointAction { toggle, remove, setEnabled, clear, setPaused, undo }

enum BreakpointStatus { installed, pending, failed, disabled, paused }

class DebugBreakpoint {
  const DebugBreakpoint({
    required this.path,
    required this.requestedLine,
    required this.actualLine,
    required this.verified,
    this.address,
    this.message,
    this.status,
  });

  final String path;
  final int requestedLine;
  final int actualLine;
  final bool verified;
  final int? address;
  final String? message;
  final BreakpointStatus? status;

  factory DebugBreakpoint.fromJson(Map<String, dynamic> json) {
    return DebugBreakpoint(
      path: json['path'] as String,
      requestedLine: json['requestedLine'] as int,
      actualLine: json['actualLine'] as int? ?? json['requestedLine'] as int,
      verified: json['verified'] == true,
      address: json['address'] as int?,
      message: json['message'] as String?,
      status: BreakpointStatus.values
          .where((status) => status.name == json['status'])
          .firstOrNull,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'requestedLine': requestedLine,
    'actualLine': actualLine,
    'verified': verified,
    if (address != null) 'address': address,
    if (message != null) 'message': message,
    if (status != null) 'status': status!.name,
  };
}

class BreakpointSettings {
  BreakpointSettings({
    Map<String, Set<int>>? requested,
    Map<String, Set<int>>? disabled,
    this.paused = false,
  }) : requested = {
         for (final entry in (requested ?? const <String, Set<int>>{}).entries)
           if (entry.value.isNotEmpty) entry.key: {...entry.value},
       },
       disabled = {
         for (final entry in (disabled ?? const <String, Set<int>>{}).entries)
           if (entry.value.isNotEmpty) entry.key: {...entry.value},
       };

  final Map<String, Set<int>> requested;
  final Map<String, Set<int>> disabled;
  bool paused;

  BreakpointSettings copy() => BreakpointSettings(
    requested: requested,
    disabled: disabled,
    paused: paused,
  );

  factory BreakpointSettings.fromJson(Map json) => BreakpointSettings(
    requested: _readLines(json['requestedBreakpoints']),
    disabled: _readLines(json['disabledBreakpoints']),
    paused: json['breakpointsPaused'] == true,
  );

  Map<String, Object?> toJson({bool includePause = true}) => {
    'requestedBreakpoints': _writeLines(requested),
    'disabledBreakpoints': _writeLines(disabled),
    if (includePause) 'breakpointsPaused': paused,
  };

  static Map<String, List<int>> _writeLines(Map<String, Set<int>> files) => {
    for (final entry in files.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.toList()..sort(),
  };

  static Map<String, Set<int>> _readLines(Object? value) {
    if (value == null) return {};
    if (value is! Map) throw const FormatException('项目断点无效。');
    final lines = <String, Set<int>>{};
    for (final MapEntry(key: path, value: rawLines) in value.entries) {
      if (path is! String ||
          path.trim().isEmpty ||
          rawLines is! List ||
          rawLines.any((line) => line is! int || line <= 0)) {
        throw const FormatException('项目断点无效。');
      }
      lines[path] = rawLines.cast<int>().toSet();
    }
    return lines;
  }
}
