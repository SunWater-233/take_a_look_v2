import 'package:flutter/foundation.dart';

enum SymbolLoadStatus { loading, complete, failed }

@immutable
class SymbolLoadProgress {
  const SymbolLoadProgress({
    required this.loadId,
    required this.path,
    required this.startedAt,
    this.phase = 'check',
    this.current = 0,
    this.total = 0,
    this.status = SymbolLoadStatus.loading,
    this.finishedAt,
    this.revision = 0,
  });

  final String loadId;
  final String path;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String phase;
  final int current;
  final int total;
  final SymbolLoadStatus status;
  final int revision;

  bool get isLoading => status == SymbolLoadStatus.loading;
  int get step => switch (phase) {
    'debug' => 2,
    'scan' || 'variables' => 3,
    'source' => 4,
    'ui' || 'done' => 5,
    _ => 1,
  };
  String get label => switch (phase) {
    'debug' => '解析变量与类型',
    'scan' || 'variables' => '生成变量列表',
    'source' => '建立源码行索引',
    'ui' => '更新符号树',
    'done' => '符号与源码信息已就绪',
    _ => '检查文件',
  };
  double? get fraction => phase == 'done'
      ? 1
      : total > 0
      ? (current / total).clamp(0, 1)
      : null;

  SymbolLoadProgress copyWith({
    String? phase,
    int? current,
    int? total,
    SymbolLoadStatus? status,
    DateTime? finishedAt,
  }) => SymbolLoadProgress(
    loadId: loadId,
    path: path,
    startedAt: startedAt,
    phase: phase ?? this.phase,
    current: current ?? this.current,
    total: total ?? this.total,
    status: status ?? this.status,
    finishedAt: finishedAt ?? this.finishedAt,
    revision: revision + 1,
  );

  Map<String, Object?> toJson() => {
    'loadId': loadId,
    'path': path,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'finishedAt': finishedAt?.millisecondsSinceEpoch,
    'phase': phase,
    'current': current,
    'total': total,
    'status': status.name,
    'revision': revision,
  };

  factory SymbolLoadProgress.fromJson(Map<String, dynamic> json) =>
      SymbolLoadProgress(
        loadId: json['loadId'] as String,
        path: json['path'] as String,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          json['startedAt'] as int,
        ),
        finishedAt: json['finishedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['finishedAt'] as int)
            : null,
        phase: json['phase'] as String? ?? 'check',
        current: (json['current'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        status: SymbolLoadStatus.values.byName(json['status'] as String),
        revision: json['revision'] as int? ?? 0,
      );
}
