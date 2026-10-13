import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

class SourceProjectConfig {
  SourceProjectConfig() {
    if (kIsWeb) {
      platform = 'web';
      shell = 'sh';
      return;
    }
    platform = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'macos'
        : 'linux';
    shell = switch (platform) {
      'windows' => 'powershell',
      'macos' => 'zsh',
      _ => 'bash',
    };
  }

  String platform = 'windows';
  String sourceRoot = '';
  String buildCommand = '';
  String firmwarePath = '';
  String shell = 'powershell';
  String afterDownload = 'halt';
  String extraPath = '';
  String outputEncoding = 'utf-8';
  List<Map<String, dynamic>> shells = [];

  String get platformLabel => switch (platform) {
    'windows' => 'Windows',
    'macos' => 'macOS',
    'web' => 'Web',
    _ => 'Linux',
  };
  bool get canBuild =>
      platform != 'web' && sourceRoot.isNotEmpty && buildCommand.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'sourceRoot': sourceRoot,
    'buildCommand': buildCommand,
    'firmwarePath': firmwarePath,
    'shell': shell,
    'afterDownload': afterDownload,
    'extraPath': extraPath,
    'outputEncoding': outputEncoding,
    'shells': shells,
  };

  void applyJson(Map<String, dynamic> data) {
    platform = data['platform'] as String? ?? platform;
    sourceRoot = data['sourceRoot'] as String? ?? sourceRoot;
    buildCommand = data['buildCommand'] as String? ?? buildCommand;
    firmwarePath = data['firmwarePath'] as String? ?? firmwarePath;
    shell = data['shell'] as String? ?? shell;
    afterDownload = data['afterDownload'] as String? ?? afterDownload;
    extraPath = data['extraPath'] as String? ?? extraPath;
    outputEncoding = data['outputEncoding'] as String? ?? outputEncoding;
    if (data['shells'] case final List items) {
      shells = items
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
  }
}

class SourceTaskState {
  final Map<String, dynamic> details = {'status': 'idle', 'phase': 'idle'};
  final List<Map<String, dynamic>> lines = [];
  int clearedThrough = 0;
  int outputRevision = 0;

  String get id => details['id'] as String? ?? '';
  String get status => details['status'] as String? ?? 'idle';
  String get phase => details['phase'] as String? ?? 'idle';
  String get message => details['message'] as String? ?? '';
  bool get running => status == 'running';
  bool get canCancel => running && details['canCancel'] == true;
  bool get blocksProbe => running && phase != 'build';

  void applyJson(Map<String, dynamic> data) {
    final changedTask = data['id'] != null && data['id'] != id;
    if (changedTask) {
      details.clear();
      lines.clear();
      clearedThrough = 0;
    }
    if (data['replaceOutput'] == true) lines.clear();
    if (data['clearedThrough'] case final int sequence) {
      clearedThrough = sequence;
    }
    details.addAll(
      Map.of(data)
        ..remove('lines')
        ..remove('replaceOutput')
        ..remove('clearedThrough'),
    );
    var last = lines.isEmpty
        ? clearedThrough
        : (lines.last['seq'] as int? ?? 0);
    for (final raw in (data['lines'] as List? ?? const []).whereType<Map>()) {
      final line = Map<String, dynamic>.from(raw);
      final sequence = line['seq'] as int? ?? 0;
      if (sequence <= last) continue;
      lines.add(line);
      last = sequence;
    }
    var characters = lines.fold<int>(
      0,
      (count, line) => count + (line['text'] as String? ?? '').length,
    );
    var remove = 0;
    while (lines.length - remove > 1000 || characters > 256 * 1024) {
      characters -= (lines[remove++]['text'] as String? ?? '').length;
    }
    if (remove > 0) lines.removeRange(0, remove);
    outputRevision++;
  }

  void clearOutput() {
    if (lines.isNotEmpty) {
      clearedThrough = lines.last['seq'] as int? ?? clearedThrough;
    }
    lines.clear();
    outputRevision++;
  }

  Map<String, dynamic> toJson() => {
    ...details,
    'lines': lines,
    'replaceOutput': true,
    'clearedThrough': clearedThrough,
  };
}
