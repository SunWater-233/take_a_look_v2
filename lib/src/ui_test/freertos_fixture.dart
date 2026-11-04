/// Deterministic data for the explicit UI test build. Never imported by main.
Map<String, dynamic> freeRtosFixture({
  bool halted = false,
  int sequence = 1842,
}) {
  final tasks = [
    ('MotorControl', 'ready', 5, 5, 34.7, 640, 2048),
    ('SensorAcquire', 'running', 6, 6, 18.6, 512, 1536),
    ('CanRx', 'blocked', 4, 4, 6.8, 448, 1024),
    ('Telemetry', 'blocked', 3, 3, 4.1, 96, 1536),
    ('Logger', 'blocked', 3, 2, 2.4, 768, 2048),
    ('Tmr Svc', 'blocked', 2, 2, 0.8, 512, 1024),
    ('IDLE', 'ready', 0, 0, 32.6, 208, 512),
  ];
  int handle(int index) => 0x24001a20 + index * 0xe0;
  return {
    'status': 'ready',
    'stale': false,
    'sequence': sequence,
    'capturedAtMs': DateTime(
      2026,
      11,
      4,
      14,
      32,
      18,
      420,
    ).millisecondsSinceEpoch,
    'quality': halted ? 'haltedValidated' : 'runningApproximate',
    'halted': halted,
    'kernel': 'FreeRTOS',
    'version': '10.4.6',
    'tick': 184932,
    'tickHz': 1000,
    'nonIdlePercent': 67.4,
    'tasks': [
      for (var i = 0; i < tasks.length; i++)
        {
          'handle': handle(i),
          'taskNumber': i + 1,
          'name': tasks[i].$1,
          'state': tasks[i].$2,
          'priority': tasks[i].$3,
          'basePriority': tasks[i].$4,
          'cpuPercent': tasks[i].$5,
          'cpuWindowSeconds': 1.0,
          'runtimeCounter': 100000 + i * 217,
          'minFreeStackBytes': tasks[i].$6,
          'stackBytes': tasks[i].$7,
          'stackBase': 0x24002000 + i * 2048,
          'stackEnd': 0x24002000 + i * 2048 + tasks[i].$7 - 4,
          'savedSp': 0x24002000 + i * 2048 + tasks[i].$6,
          'stackWatermarkSource': 'kernelApi',
          'stackWatermarkAtLeast': false,
          'waitingObject': i == 3
              ? 0x24005100
              : i == 4
              ? 0x24005180
              : i == 2
              ? 0x24005000
              : null,
          'notifications': [
            {'index': 0, 'value': 0, 'state': 0},
          ],
          'fields': [
            {
              'name': '${tasks[i].$1}.ulRunTimeCounter',
              'address': handle(i) + 76,
              'size': 4,
              'kind': 'uint32_t',
            },
          ],
        },
    ],
    'objects': [
      {
        'handle': 0x24005000,
        'name': 'qCanRx',
        'kind': 'queue',
        'count': 0,
        'capacity': 16,
        'itemBytes': 24,
        'waiters': [handle(2)],
      },
      {
        'handle': 0x24005080,
        'name': 'qTelemetry',
        'kind': 'queue',
        'count': 3,
        'capacity': 32,
        'itemBytes': 48,
        'waiters': <int>[],
      },
      {
        'handle': 0x24005100,
        'name': 'mutexLog',
        'kind': 'mutex',
        'count': 0,
        'capacity': 1,
        'owner': handle(4),
        'waiters': [handle(3)],
      },
      {
        'handle': 0x24005180,
        'name': 'semSdDone',
        'kind': 'binarySemaphore',
        'count': 0,
        'capacity': 1,
        'waiters': [handle(4)],
      },
      {
        'handle': 0x24005200,
        'name': 'semSensor',
        'kind': 'countingSemaphore',
        'count': 1,
        'capacity': 8,
        'waiters': <int>[],
      },
      {
        'handle': 0x24005280,
        'name': 'evNetwork',
        'kind': 'eventGroup',
        'bits': 5,
        'waiters': <int>[],
      },
      {
        'handle': 0x24005300,
        'name': 'streamUart',
        'kind': 'streamBuffer',
        'count': 128,
        'capacity': 512,
        'triggerBytes': 32,
        'waiters': <int>[],
      },
      {
        'handle': 0x24005380,
        'name': 'msgConfig',
        'kind': 'messageBuffer',
        'count': 0,
        'capacity': 256,
        'waiters': <int>[],
      },
    ],
    'timers': [
      {
        'handle': 0x24006000,
        'name': 'Heartbeat',
        'active': true,
        'periodTicks': 1000,
        'periodMs': 1000.0,
        'autoReload': true,
        'expiryTick': 185000,
        'callback': 0x080124a1,
      },
      {
        'handle': 0x24006060,
        'name': 'CommTimeout',
        'active': true,
        'periodTicks': 250,
        'periodMs': 250.0,
        'autoReload': false,
        'expiryTick': 185125,
        'callback': 0x080126a1,
      },
      {
        'handle': 0x240060c0,
        'name': 'FlushLog',
        'active': false,
        'periodTicks': 2000,
        'periodMs': 2000.0,
        'autoReload': true,
        'callback': 0x08012aa1,
      },
    ],
    'heap': {
      'freeBytes': 40320,
      'minimumEverFreeBytes': 32768,
      'totalBytes': 65536,
      'base': 0x24010000,
      'largestFreeBlockBytes': 16384,
      'smallestFreeBlockBytes': 256,
      'freeBlockCount': 5,
      'blocks': [
        for (var i = 0; i < 5; i++)
          {
            'address': 0x24012000 + i * 8192,
            'size': [16384, 12288, 8192, 3200, 256][i],
          },
      ],
    },
    'diagnostics': [
      for (final item in [
        ('tasks', '任务与状态', '任务链表已校验。'),
        ('cpu', '运行时间统计', '相邻快照计数差；中断时间可能归属到当前任务。'),
        ('stack', '任务栈', '固件提供 API 栈水位与分配大小。'),
        ('objects', '内核对象', '读取已登记对象与内核等待列表。'),
        ('heap', '堆内存', '统计覆盖 FreeRTOS 分配器。'),
        ('timers', '软件定时器', '活动列表与有类型句柄。'),
      ])
        {
          'key': item.$1,
          'label': item.$2,
          'status': 'available',
          'message': item.$3,
        },
      {
        'key': 'context',
        'label': '保存上下文',
        'status': halted ? 'available' : 'targetRunning',
        'message': '暂停后可读取原始栈字；调用栈展开需要 CPU 端口适配。',
      },
    ],
  };
}
