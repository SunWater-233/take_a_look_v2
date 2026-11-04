import 'dart:collection';

/// Immutable wire records shared by every workbench and detached window.
class FreeRtosRecord {
  FreeRtosRecord(Map data)
    : data = UnmodifiableMapView(Map<String, dynamic>.from(data));
  final Map<String, dynamic> data;
  String text(String key, [String fallback = '—']) =>
      data[key]?.toString() ?? fallback;
  num? number(String key) => data[key] is num ? data[key] as num : null;
  int? integer(String key) => number(key)?.toInt();
  bool flag(String key) => data[key] == true;
  int get handle => integer('handle') ?? 0;
  String get name => text('name');
  List<FreeRtosRecord> records(String key) => [
    for (final value in data[key] as List? ?? const [])
      if (value is Map) FreeRtosRecord(value),
  ];
  String get stateLabel => switch (text('state')) {
    'running' => '运行',
    'ready' => '就绪',
    'blocked' => '阻塞',
    'suspended' => '挂起',
    'deleted' => '待回收',
    _ => '未知',
  };
  String get kindLabel => switch (text('kind')) {
    'queue' => '队列',
    'mutex' => '互斥锁',
    'recursiveMutex' => '递归互斥锁',
    'binarySemaphore' => '二值信号量',
    'countingSemaphore' => '计数信号量',
    'eventGroup' => '事件组',
    'streamBuffer' => '流缓冲区',
    'messageBuffer' => '消息缓冲区',
    _ => '未知类型',
  };
}

class FreeRtosSnapshot extends FreeRtosRecord {
  FreeRtosSnapshot([super.data = const {}]);
  List<FreeRtosRecord> get tasks => records('tasks');
  List<FreeRtosRecord> get objects => records('objects');
  List<FreeRtosRecord> get timers => records('timers');
  List<FreeRtosRecord> get diagnostics => records('diagnostics');
  FreeRtosRecord get heap => FreeRtosRecord(data['heap'] as Map? ?? const {});
  bool get hasData => integer('sequence') != null;
  bool get stale => flag('stale');
  String get status => text('status', 'idle');
  FreeRtosRecord? task(int? handle) =>
      tasks.where((row) => row.handle == handle).firstOrNull;
  FreeRtosRecord? object(int? handle) =>
      objects.where((row) => row.handle == handle).firstOrNull;
}

String freeRtosAddress(num? address) => address == null
    ? '—'
    : '0x${address.toInt().toRadixString(16).padLeft(8, '0').toUpperCase()}';
