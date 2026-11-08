import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../models/freertos.dart';
import '../models/models.dart' show ConnectionStatus;
import '../theme/theme.dart';
import '../workspace/panel_types.dart';

/// The production FreeRTOS inspector. Sample data lives only in ui_test/.
class FreeRtosPanel extends StatefulWidget {
  const FreeRtosPanel({
    required this.controller,
    this.visible = true,
    this.onShowSource,
    super.key,
  });
  final TakeALookController controller;
  final bool visible;
  final VoidCallback? onShowSource;
  @override
  State<FreeRtosPanel> createState() => _FreeRtosPanelState();
}

class _FreeRtosPanelState extends State<FreeRtosPanel> {
  late final _viewId = 'freertos-${identityHashCode(this)}';
  late final _search = TextEditingController(
    text: settings['search'] as String? ?? '',
  );
  FreeRtosSnapshot? _frozen;
  bool? _demand;
  bool _exporting = false;
  TakeALookController get controller => widget.controller;
  Map<String, dynamic> get settings => controller.freeRtosSettings;
  String get page => settings['page'] as String? ?? 'tasks';
  FreeRtosSnapshot get snapshot => _frozen ?? controller.freeRtos;
  bool get offline => controller.connectionStatus != ConnectionStatus.connected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDemand();
  }

  @override
  void didUpdateWidget(covariant FreeRtosPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.setFreeRtosViewVisible(_viewId, false);
      _demand = null;
      _frozen = null;
    }
    _updateDemand();
  }

  void _updateDemand() {
    final demand = widget.visible && WorkspacePanelVisibility.of(context);
    if (_demand == demand) return;
    _demand = demand;
    controller.setFreeRtosViewVisible(_viewId, demand);
  }

  @override
  void dispose() {
    controller.setFreeRtosViewVisible(_viewId, false);
    _search.dispose();
    super.dispose();
  }

  void _set(Map<String, dynamic> values) =>
      controller.setFreeRtosSettings(values);
  void _selectTask(int handle) {
    final task = snapshot.task(handle);
    _set({
      'page': 'tasks',
      'selectedTask': handle,
      'selectedTaskNumber': task?.integer('taskNumber'),
      'search': '',
    });
    _search.clear();
  }

  void _selectObject(int handle) => _set({
    'page': 'objects',
    'selectedObject': handle,
    'objectFilter': 'all',
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.signals.freeRtos,
      controller.signals.connection,
      controller.signals.debug,
    ]),
    builder: (context, _) {
      final search = settings['search'] as String? ?? '';
      if (_search.text != search) {
        _search.value = TextEditingValue(
          text: search,
          selection: TextSelection.collapsed(offset: search.length),
        );
      }
      final data = snapshot;
      return ColoredBox(
        color: WorkbenchColors.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(data),
            _tabs(data),
            if (data.stale || (offline && data.hasData))
              _message(
                '${offline ? '连接已断开。' : ''}${data.text('message', '当前展示最后一份有效快照。')}',
                warning: true,
              ),
            Expanded(
              child: page == 'diagnostics'
                  ? _diagnostics(data)
                  : !data.hasData
                  ? _empty(data)
                  : switch (page) {
                      'objects' => _objects(data),
                      'memory' => _memory(data),
                      'timers' => _timers(data),
                      'diagnostics' => _diagnostics(data),
                      _ => _tasks(data),
                    },
            ),
            _footer(data),
          ],
        ),
      );
    },
  );

  Widget _toolbar(FreeRtosSnapshot data) => Container(
    color: WorkbenchColors.surface,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'FreeRTOS${data.data['version'] == null ? '' : ' ${data.text('version')}'}',
              style: talStrong,
            ),
            if (data.hasData) const Text('单核检查', style: workbenchMuted),
            TalButton(
              onPressed: data.hasData
                  ? () =>
                        setState(() => _frozen = _frozen == null ? data : null)
                  : null,
              child: Text(_frozen == null ? '冻结显示' : '继续刷新'),
            ),
            TalButton(
              onPressed: _exporting || !data.hasData
                  ? null
                  : () => _export(data),
              child: const Text('导出快照'),
            ),
            TalIconButton(
              tooltip: '重新读取快照',
              onPressed: offline ? null : controller.refreshFreeRtos,
              icon: const Icon(Icons.refresh, size: 16),
            ),
            TalIconButton(
              tooltip: 'FreeRTOS 显示设置',
              onPressed: _showSettings,
              icon: const Icon(Icons.settings_outlined, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 18,
          runSpacing: 4,
          children: [
            Text(
              offline
                  ? '连接已断开'
                  : controller.debugState.executionState.name == 'halted' ||
                        (controller.debugState.executionState.name ==
                                'unavailable' &&
                            data.flag('halted'))
                  ? '目标已暂停'
                  : '目标运行中',
              style: workbenchMuted,
            ),
            Text(
              _frozen != null
                  ? '显示已冻结；目标状态未改变'
                  : data.text('quality') == 'haltedValidated'
                  ? '暂停时快照 / 已校验'
                  : '运行中快照 / 近似',
              style: workbenchMuted,
            ),
            Text(
              data.hasData ? '${data.tasks.length} 个任务' : '等待内核快照',
              style: workbenchMuted,
            ),
            if (data.hasData)
              Text(
                '非 Idle 占用 ${_percent(data.number('nonIdlePercent'))}',
                style: talMono,
              ),
          ],
        ),
      ],
    ),
  );

  Widget _tabs(FreeRtosSnapshot data) => DecoratedBox(
    decoration: const BoxDecoration(
      color: WorkbenchColors.surface,
      border: Border(bottom: BorderSide(color: WorkbenchColors.border)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in [
            ('tasks', '任务', data.tasks.length),
            ('objects', '内核对象', data.objects.length),
            ('memory', '内存', null),
            ('timers', '定时器', data.timers.length),
            ('diagnostics', '诊断', null),
          ])
            Semantics(
              selected: page == entry.$1,
              button: true,
              child: InkWell(
                onTap: () => _set({'page': entry.$1}),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: page == entry.$1
                            ? TalColors.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    '${entry.$2}${entry.$3 != null && data.hasData ? ' ${entry.$3}' : ''}',
                    style: page == entry.$1 ? talStrong : workbenchMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _empty(FreeRtosSnapshot data) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const Icon(
            Icons.account_tree_outlined,
            size: 32,
            color: TalColors.muted,
          ),
          const SizedBox(height: 14),
          Text(switch (data.status) {
            'symbolsRequired' => '需要固件调试信息',
            'disconnected' => '连接调试目标',
            'targetRunning' => '当前连接需要暂停目标',
            'unsupported' => '当前内核布局尚不支持',
            'inconsistent' => '等待完整的内核快照',
            'readError' => '内核读取失败',
            _ => '等待 FreeRTOS 快照',
          }, style: talStrong),
          const SizedBox(height: 9),
          Text(
            data.text('message', '连接目标并加载匹配固件的 ELF / AXF 后，自动读取任务和内核对象。'),
            style: workbenchMuted,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          if (data.status == 'symbolsRequired' ||
              !controller.hasFirmwareSymbols)
            TalButton(
              onPressed: controller.chooseFirmwareFile,
              child: const Text('加载 ELF / AXF'),
            ),
          if (data.status == 'targetRunning' &&
              controller.supportsTargetControl)
            TalButton(
              onPressed: controller.haltTarget,
              child: const Text('暂停目标并检查'),
            ),
        ],
      ),
    ),
  );

  Widget _tasks(FreeRtosSnapshot data) {
    final query = (settings['search'] as String? ?? '').trim().toLowerCase();
    final rows = data.tasks
        .where(
          (t) => '${t.name} ${freeRtosAddress(t.handle)}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final sort = settings['sort'];
    if (sort == 'cpu') {
      rows.sort(
        (a, b) => (b.number('cpuPercent') ?? -1).compareTo(
          a.number('cpuPercent') ?? -1,
        ),
      );
    }
    if (sort == 'stack') {
      rows.sort(
        (a, b) => (b.peakStackBytes ?? -1).compareTo(a.peakStackBytes ?? -1),
      );
    }
    var selected = data.task(settings['selectedTask'] as int?);
    if (selected != null &&
        settings['selectedTaskNumber'] != null &&
        selected.integer('taskNumber') != settings['selectedTaskNumber']) {
      selected = null;
    }
    selected ??= rows.firstOrNull;
    final picked = selected;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 310),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 16),
                      hintText: '查找任务或句柄',
                      isDense: true,
                    ),
                    onChanged: (value) => _set({'search': value}),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Flexible(
                child: Text('栈显示历史峰值 / CPU 按快照窗口统计', style: workbenchMuted),
              ),
            ],
          ),
        ),
        Expanded(
          child: _split(
            table: LayoutBuilder(
              builder: (context, limits) {
                final compact = limits.maxWidth < 520;
                return _table(
                  'tasks',
                  [
                    _Col('name', '任务', compact ? 110 : 155),
                    if (!compact) _Col('state', '状态', 70),
                    if (!compact) _Col('priority', '优先级', 70, right: true),
                    _Col(
                      'cpu',
                      'CPU 占用${sort == 'cpu' ? ' ↓' : ''}',
                      compact ? 80 : 115,
                      right: true,
                      onSort: () => _set({'sort': sort == 'cpu' ? '' : 'cpu'}),
                    ),
                    _Col(
                      'stack',
                      '峰值栈占用${sort == 'stack' ? ' ↓' : ''}',
                      compact ? 145 : 165,
                      right: true,
                      onSort: () =>
                          _set({'sort': sort == 'stack' ? '' : 'stack'}),
                    ),
                  ],
                  rows,
                  picked?.handle,
                  (row) => _selectTask(row.handle),
                  (row) => [
                    Tooltip(
                      message: freeRtosAddress(row.handle),
                      child: Text(
                        row.name,
                        style: talMono,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!compact) _taskState(row),
                    if (!compact)
                      Text(
                        '${row.text('priority')}${row.number('basePriority') != null && row.number('priority') != row.number('basePriority') ? ' ↑' : ''}',
                        style: talMono,
                      ),
                    _meter(
                      _percent(row.number('cpuPercent')),
                      row.number('cpuPercent')?.toDouble(),
                      TalColors.info,
                    ),
                    Tooltip(
                      message: _stackUsageTooltip(row),
                      child: _meter(
                        _stackPeakPercent(row),
                        row.peakStackPercent,
                        _stackLow(row) ? TalColors.warning : TalColors.success,
                      ),
                    ),
                  ],
                );
              },
            ),
            inspector: picked == null
                ? const Text('没有匹配任务。', style: workbenchMuted)
                : _taskInspector(data, picked),
          ),
        ),
      ],
    );
  }

  Widget _taskInspector(FreeRtosSnapshot data, FreeRtosRecord task) {
    final object = data.object(task.integer('waitingObject'));
    final owner = object == null ? null : data.task(object.integer('owner'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          task.name,
          style: talStrong.copyWith(fontFamily: talFontFamily, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          freeRtosAddress(task.handle),
          style: talMono.copyWith(color: TalColors.muted),
        ),
        _heading('任务状态'),
        _properties([
          ('当前状态', _taskState(task)),
          (
            '优先级 / 基础',
            Text(
              '${task.text('priority')} / ${task.text('basePriority')}',
              style: talMono,
            ),
          ),
          ('CPU 占用', Text(_percent(task.number('cpuPercent')), style: talMono)),
          ('运行计数', Text(task.text('runtimeCounter'), style: talMono)),
        ]),
        _heading('栈占用'),
        _properties([
          (
            '峰值占用',
            Text(
              _stackPeakBytes(task),
              style: talMono.copyWith(
                color: _stackLow(task) ? TalColors.warning : null,
              ),
            ),
          ),
          ('峰值占比', Text(_stackPeakPercent(task), style: talMono)),
          ('分配大小', Text(_bytes(task.number('stackBytes')), style: talMono)),
          (
            '历史最小剩余',
            Text(
              '${task.flag('stackWatermarkAtLeast') ? '≥ ' : ''}${_bytes(task.number('minFreeStackBytes'))}',
              style: talMono.copyWith(
                color: _stackLow(task) ? TalColors.warning : null,
              ),
            ),
          ),
          (
            '栈起始地址',
            Text(freeRtosAddress(task.number('stackBase')), style: talMono),
          ),
          (
            '保存的 SP',
            Text(freeRtosAddress(task.number('savedSp')), style: talMono),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('峰值表示任务创建以来用到过的最大栈空间。', style: workbenchMuted),
        const SizedBox(height: 4),
        Text(
          task.text('stackWatermarkSource') == 'kernelApi'
              ? '来源：FreeRTOS API 水位'
              : '填充扫描估算；缺少边界或填充证据时显示“—”。',
          style: workbenchMuted,
        ),
        if (task.flag('stackWatermarkAtLeast'))
          const Text('扫描未覆盖完整空闲区，峰值占用显示上限（≤）。', style: workbenchMuted),
        if (_stackLow(task))
          _message(
            '历史最小栈余量低于 ${settings['stackWarningPercent']}% 提醒阈值。',
            warning: true,
          ),
        _heading('等待关系'),
        if (object == null)
          const Text('未识别到已登记的对象等待。', style: workbenchMuted)
        else ...[
          _properties([
            ('等待对象', _link(object.name, () => _selectObject(object.handle))),
            if (owner != null)
              ('对象持有者', _link(owner.name, () => _selectTask(owner.handle))),
          ]),
          const SizedBox(height: 6),
          const Text('来源：对象登记与内核等待列表', style: workbenchMuted),
        ],
        _heading('任务通知'),
        if (task.records('notifications').isEmpty)
          const Text('内核未提供任务通知字段。', style: workbenchMuted)
        else
          _properties([
            for (final item in task.records('notifications'))
              (
                '索引 ${item.text('index')}',
                Text(
                  '${freeRtosAddress(item.number('value'))} / ${switch (item.integer('state')) {
                    0 => '无待处理',
                    1 => '等待中',
                    2 => '已收到',
                    _ => '未知',
                  }}',
                  style: talMono,
                ),
              ),
          ]),
        const SizedBox(height: 15),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            PopupMenuButton<String>(
              tooltip: '将内核字段作为只读变量加入监视',
              enabled:
                  !offline &&
                  !data.stale &&
                  _frozen == null &&
                  task.records('fields').isNotEmpty,
              onSelected: (value) =>
                  controller.addFreeRtosWatch(task.handle, value),
              itemBuilder: (_) => [
                for (final field in task.records('fields'))
                  PopupMenuItem(
                    value: field.text('name').split('.').last,
                    child: Text(field.text('name').split('.').last),
                  ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('加入变量监视', style: TextStyle(color: TalColors.info)),
              ),
            ),
            Tooltip(
              message: '目标暂停后查看保存的原始栈字',
              child: TalButton(
                onPressed:
                    !offline &&
                        data.flag('halted') &&
                        !data.stale &&
                        _frozen == null
                    ? () => _showStack(task)
                    : null,
                child: const Text('查看保存栈'),
              ),
            ),
            if (task.data['entryFile'] is String &&
                task.integer('entryLine') != null)
              TalButton(
                onPressed: () {
                  controller.revealSourceLocation(
                    task.text('entryFile'),
                    task.integer('entryLine')!,
                  );
                  widget.onShowSource?.call();
                },
                child: const Text('定位入口'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _objects(FreeRtosSnapshot data) {
    final filter = settings['objectFilter'] as String? ?? 'all';
    final rows = data.objects
        .where((row) => filter == 'all' || row.text('kind') == filter)
        .toList();
    final selected =
        data.object(settings['selectedObject'] as int?) ?? rows.firstOrNull;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('对象类型', style: workbenchMuted),
              DropdownButton<String>(
                value:
                    {
                      'all',
                      ...data.objects.map((o) => o.text('kind')),
                    }.contains(filter)
                    ? filter
                    : 'all',
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部类型')),
                  for (final kind
                      in data.objects.map((o) => o.text('kind')).toSet())
                    DropdownMenuItem(
                      value: kind,
                      child: Text(
                        data.objects
                            .firstWhere((o) => o.text('kind') == kind)
                            .kindLabel,
                      ),
                    ),
                ],
                onChanged: (value) => _set({'objectFilter': value}),
              ),
              Text('已登记 / 可识别 ${data.objects.length} 个', style: workbenchMuted),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? _capabilityEmpty(data, 'objects')
              : _split(
                  table: _table(
                    'objects',
                    [
                      _Col('name', '对象', 155),
                      _Col('type', '类型', 110),
                      _Col('value', '当前值', 120, right: true),
                      _Col('waiters', '等待者', 130),
                    ],
                    rows,
                    selected?.handle,
                    (row) => _selectObject(row.handle),
                    (row) => [
                      Text(
                        row.name,
                        style: talMono,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(row.kindLabel, style: workbenchBody),
                      Text(_objectValue(row), style: talMono),
                      Text(
                        (row.data['waiters'] as List? ?? [])
                            .map(
                              (h) =>
                                  data.task(h as int)?.name ??
                                  freeRtosAddress(h),
                            )
                            .join('、'),
                        style: workbenchBody,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                  inspector: selected == null
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              selected.name,
                              style: talStrong.copyWith(fontSize: 15),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${freeRtosAddress(selected.handle)} / ${selected.kindLabel}',
                              style: talMono,
                            ),
                            _heading('对象状态'),
                            _properties([
                              (
                                '当前值',
                                Text(_objectValue(selected), style: talMono),
                              ),
                              if (selected.number('itemBytes') != null)
                                (
                                  '消息大小',
                                  Text(
                                    _bytes(selected.number('itemBytes')),
                                    style: talMono,
                                  ),
                                ),
                              if (selected.number('triggerBytes') != null)
                                (
                                  '触发阈值',
                                  Text(
                                    _bytes(selected.number('triggerBytes')),
                                    style: talMono,
                                  ),
                                ),
                            ]),
                            _heading('当前关系'),
                            if (data.task(selected.integer('owner'))
                                case final owner?)
                              _properties([
                                (
                                  '持有者',
                                  _link(
                                    owner.name,
                                    () => _selectTask(owner.handle),
                                  ),
                                ),
                              ]),
                            for (final handle
                                in selected.data['waiters'] as List? ??
                                    const [])
                              if (data.task(handle as int) case final waiter?)
                                _properties([
                                  (
                                    '等待任务',
                                    _link(
                                      waiter.name,
                                      () => _selectTask(waiter.handle),
                                    ),
                                  ),
                                ]),
                            if ((selected.data['waiters'] as List? ?? [])
                                .isEmpty)
                              const Text('当前没有等待任务。', style: workbenchMuted),
                            const SizedBox(height: 15),
                            const Text(
                              '快照表示当前关系，不推断资源过去的持有时长。',
                              style: workbenchMuted,
                            ),
                          ],
                        ),
                ),
        ),
      ],
    );
  }

  Widget _memory(FreeRtosSnapshot data) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('FreeRTOS 堆', style: talStrong),
        const SizedBox(height: 15),
        Wrap(
          spacing: 32,
          runSpacing: 14,
          children: [
            _stat('当前剩余', _bytes(data.heap.number('freeBytes'))),
            _stat('历史最小剩余', _bytes(data.heap.number('minimumEverFreeBytes'))),
            _stat('最大空闲块', _bytes(data.heap.number('largestFreeBlockBytes'))),
          ],
        ),
        const SizedBox(height: 18),
        if (data.heap.records('blocks').isNotEmpty) ...[
          const Text('空闲块分布 / 按块大小显示', style: workbenchMuted),
          const SizedBox(height: 9),
          SizedBox(
            height: 30,
            child: Row(
              children: [
                for (final block in data.heap.records('blocks'))
                  Expanded(
                    flex: math.max(1, block.integer('size') ?? 1),
                    child: Tooltip(
                      message:
                          '${freeRtosAddress(block.number('address'))} / ${_bytes(block.number('size'))}',
                      child: Container(
                        margin: const EdgeInsets.only(right: 2),
                        color: TalColors.success.withValues(alpha: .6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '空闲块 ${data.heap.text('freeBlockCount')} / 最小块 ${_bytes(data.heap.number('smallestFreeBlockBytes'))}',
            style: workbenchMuted,
          ),
        ] else
          _capabilityEmpty(data, 'heap', compact: true),
        _heading('任务栈预算'),
        for (final task in data.tasks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LayoutBuilder(
              builder: (_, constraints) => Wrap(
                spacing: 16,
                runSpacing: 5,
                children: [
                  SizedBox(
                    width: math.min(155, constraints.maxWidth),
                    child: _link(task.name, () => _selectTask(task.handle)),
                  ),
                  Text(
                    '峰值占用 ${_stackPeakCapacity(task)}（${_stackPeakPercent(task)}）',
                    style: talMono.copyWith(
                      color: _stackLow(task) ? TalColors.warning : null,
                    ),
                  ),
                  Text(
                    '最小剩余 ${task.flag('stackWatermarkAtLeast') ? '≥ ' : ''}${_bytes(task.number('minFreeStackBytes'))}',
                    style: talMono.copyWith(
                      color: _stackLow(task) ? TalColors.warning : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        const Divider(),
        const Text(
          '峰值占用 = 分配大小 − 历史最小剩余。任务栈可能由该堆分配，两项不能相加。',
          style: workbenchMuted,
        ),
      ],
    ),
  );

  Widget _timers(FreeRtosSnapshot data) {
    final rows = data.timers;
    final selected =
        rows
            .where((row) => row.handle == settings['selectedTimer'])
            .firstOrNull ??
        rows.firstOrNull;
    if (selected == null) return _capabilityEmpty(data, 'timers');
    return _split(
      table: _table(
        'timers',
        [
          _Col('name', '定时器', 155),
          _Col('active', '状态', 90),
          _Col('period', '周期', 125, right: true),
          _Col('mode', '模式', 100),
        ],
        rows,
        selected.handle,
        (row) => _set({'selectedTimer': row.handle}),
        (row) => [
          Text(row.name, style: talMono, overflow: TextOverflow.ellipsis),
          Text(row.flag('active') ? '运行中' : '未启动', style: workbenchBody),
          Text(
            row.number('periodMs') == null
                ? '${row.text('periodTicks')} tick'
                : '${row.number('periodMs')!.toStringAsFixed(1)} ms',
            style: talMono,
          ),
          Text(
            row.data['autoReload'] == null
                ? '—'
                : row.flag('autoReload')
                ? '自动重载'
                : '单次',
            style: workbenchBody,
          ),
        ],
      ),
      inspector: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(selected.name, style: talStrong.copyWith(fontSize: 15)),
          const SizedBox(height: 4),
          Text(freeRtosAddress(selected.handle), style: talMono),
          _heading('定时器状态'),
          _properties([
            ('当前 Tick', Text(data.text('tick'), style: talMono)),
            (
              'Tick 频率',
              Text(
                data.number('tickHz') == null
                    ? '未提供'
                    : '${data.text('tickHz')} Hz',
                style: talMono,
              ),
            ),
            ('下次到期', Text(selected.text('expiryTick'), style: talMono)),
            (
              '回调地址',
              Text(
                freeRtosAddress(selected.number('callback')),
                style: talMono,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('到期时间来自内核快照；实际执行时间与回调耗时未采集。', style: workbenchMuted),
          if (data.tasks.where((t) => t.name.contains('Tmr')).firstOrNull
              case final task?) ...[
            _heading('定时器服务'),
            _link(task.name, () => _selectTask(task.handle)),
          ],
        ],
      ),
    );
  }

  Widget _diagnostics(FreeRtosSnapshot data) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text('接入与数据能力', style: talStrong),
      const SizedBox(height: 8),
      for (final item in data.diagnostics)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(item.text('label'), style: talStrong)),
                  Text(switch (item.text('status')) {
                    'available' => '可用',
                    'pending' => '等待统计',
                    'targetRunning' => '待暂停',
                    _ => '未提供',
                  }, style: workbenchMuted),
                ],
              ),
              const SizedBox(height: 6),
              Text(item.text('message'), style: workbenchMuted),
              const SizedBox(height: 8),
              const Divider(height: 1),
            ],
          ),
        ),
      const ExpansionTile(
        title: Text('需要的固件配置', style: workbenchBody),
        tilePadding: EdgeInsets.zero,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: SelectableText(
              'configUSE_TRACE_FACILITY = 1\nconfigGENERATE_RUN_TIME_STATS = 1\nconfigRECORD_STACK_HIGH_ADDRESS = 1\nINCLUDE_uxTaskGetStackHighWaterMark = 1\n\n运行统计需要独立计时器。\n队列可通过 vQueueAddToRegistry() 登记名称。\n可选辅助模块提供版本、Tick 频率和 API 栈水位。',
              style: talMono,
            ),
          ),
        ],
      ),
      TalButton(onPressed: _showSettings, child: const Text('调整刷新与提醒设置')),
    ],
  );

  Widget _split({required Widget table, required Widget inspector}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final detail = Container(
            color: WorkbenchColors.surface,
            padding: const EdgeInsets.all(15),
            child: SingleChildScrollView(child: inspector),
          );
          if (constraints.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: table),
                const VerticalDivider(width: 1),
                SizedBox(width: 292, child: detail),
              ],
            );
          }
          return Column(
            children: [
              Expanded(flex: 5, child: table),
              const Divider(height: 1),
              Expanded(flex: 4, child: detail),
            ],
          );
        },
      );

  Widget _table(
    String name,
    List<_Col> columns,
    List<FreeRtosRecord> rows,
    int? selected,
    ValueChanged<FreeRtosRecord> onSelect,
    List<Widget> Function(FreeRtosRecord) cells,
  ) => _KernelTable(
    key: ValueKey('freertos-$name'),
    name: name,
    columns: columns,
    rows: rows,
    selected: selected,
    onSelect: onSelect,
    cells: cells,
    widths: Map<String, dynamic>.from(settings['columns'] as Map? ?? {}),
    onWidths: (values) => _set({
      'columns': {
        ...Map<String, dynamic>.from(settings['columns'] as Map? ?? {}),
        ...values,
      },
    }),
  );

  Widget _footer(FreeRtosSnapshot data) {
    final stamp = data.integer('capturedAtMs');
    final time = stamp == null
        ? '—'
        : DateTime.fromMillisecondsSinceEpoch(
            stamp,
          ).toLocal().toIso8601String().split('T').last;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: const BoxDecoration(
        color: WorkbenchColors.surface,
        border: Border(top: BorderSide(color: WorkbenchColors.border)),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 4,
        children: [
          Text(
            '${offline
                ? '离线快照'
                : _frozen != null
                ? '显示已冻结'
                : '快照 #${data.text('sequence')}'} / $time',
            style: workbenchMuted,
          ),
          Text('${settings['rateHz']} Hz / 主机内存读取', style: workbenchMuted),
          if (data.hasData)
            Text(
              '${data.tasks.where(_stackLow).length} 项栈余量提醒',
              style: workbenchMuted,
            ),
        ],
      ),
    );
  }

  Widget _capabilityEmpty(
    FreeRtosSnapshot data,
    String key, {
    bool compact = false,
  }) {
    final diag = data.diagnostics
        .where((r) => r.text('key') == key)
        .firstOrNull;
    final content = Padding(
      padding: EdgeInsets.all(compact ? 8 : 24),
      child: Text(
        diag?.text('message') ?? '当前固件未提供此项信息。',
        style: workbenchMuted,
        textAlign: TextAlign.center,
      ),
    );
    return compact ? content : SingleChildScrollView(child: content);
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.only(top: 19, bottom: 10),
    child: Text(label, style: talStrong),
  );
  Widget _properties(List<(String, Widget)> entries) => Column(
    children: [
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(entry.$1, style: workbenchMuted)),
              const SizedBox(width: 8),
              Flexible(child: entry.$2),
            ],
          ),
        ),
    ],
  );
  Widget _link(String name, VoidCallback action) => TextButton(
    onPressed: action,
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size(0, TalUiTheme.of(context).targetExtent(24)),
      alignment: Alignment.centerLeft,
    ),
    child: Text(
      name,
      style: talMono.copyWith(color: TalColors.info),
      overflow: TextOverflow.ellipsis,
    ),
  );
  Widget _taskState(FreeRtosRecord task) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: switch (task.text('state')) {
            'running' => TalColors.success,
            'ready' => TalColors.info,
            _ => TalColors.muted,
          },
        ),
      ),
      const SizedBox(width: 6),
      Text(task.stateLabel, style: workbenchBody),
    ],
  );
  Widget _meter(String value, double? percent, Color color) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(
        value,
        style: talMono.copyWith(
          color: color == TalColors.warning ? color : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 3,
        width: double.infinity,
        child: ColoredBox(
          color: TalColors.borderSoft,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: percent == null
                  ? 0
                  : (percent / 100).clamp(0.0, 1.0),
              child: ColoredBox(color: color, child: const SizedBox.expand()),
            ),
          ),
        ),
      ),
    ],
  );
  Widget _message(String message, {bool warning = false}) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: TalColors.surfaceAlt,
      border: Border(
        left: BorderSide(
          color: warning ? TalColors.warning : TalColors.info,
          width: 2,
        ),
      ),
    ),
    child: Text(message, style: workbenchMuted),
  );
  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: workbenchMuted),
      const SizedBox(height: 4),
      Text(value, style: talMono.copyWith(fontSize: 18)),
    ],
  );
  double? _stackRatio(FreeRtosRecord task) {
    final size = task.number('stackBytes'),
        free = task.number('minFreeStackBytes');
    return size == null || size <= 0 || free == null ? null : free / size * 100;
  }

  bool _stackLow(FreeRtosRecord task) =>
      !task.flag('stackWatermarkAtLeast') &&
      _stackRatio(task) != null &&
      _stackRatio(task)! < (settings['stackWarningPercent'] as num? ?? 10);
  String _stackPeakBytes(FreeRtosRecord task) => task.peakStackBytes == null
      ? '—'
      : '${task.flag('stackWatermarkAtLeast') ? '≤ ' : ''}${_bytes(task.peakStackBytes)}';
  String _stackPeakPercent(FreeRtosRecord task) => task.peakStackPercent == null
      ? '—'
      : '${task.flag('stackWatermarkAtLeast') ? '≤ ' : ''}${_percent(task.peakStackPercent)}';
  String _stackPeakCapacity(FreeRtosRecord task) {
    final total = task.number('stackBytes');
    if (task.peakStackBytes == null) {
      return total != null && total.isFinite && total > 0
          ? '— / ${_bytes(total)}'
          : '—';
    }
    return '${task.flag('stackWatermarkAtLeast') ? '≤ ' : ''}${_bytesValue(task.peakStackBytes)} / ${_bytes(total)}';
  }

  String _stackUsageTooltip(FreeRtosRecord task) {
    final free = task.number('minFreeStackBytes');
    if (task.peakStackBytes == null) {
      return '缺少有效的栈总容量或历史水位，无法计算峰值占用。'
          '\n分配大小：${_bytes(task.number('stackBytes'))}'
          '\n历史最小剩余：${task.flag('stackWatermarkAtLeast') ? '≥ ' : ''}${_bytes(free)}';
    }
    return '峰值栈占用：${_stackPeakCapacity(task)}（${_stackPeakPercent(task)}）'
        '\n栈总容量减去历史最小剩余，表示任务创建以来的最大占用。'
        '${task.text('stackWatermarkSource') == 'patternEstimate' ? '\n根据栈填充水位估算。' : ''}'
        '${task.flag('stackWatermarkAtLeast') ? '\n扫描未覆盖完整空闲区，显示占用上限（≤）。' : ''}';
  }

  String _objectValue(FreeRtosRecord object) =>
      object.text('kind') == 'eventGroup'
      ? freeRtosAddress(object.number('bits'))
      : object.data['owner'] != null
      ? '已占用'
      : object.number('capacity') != null
      ? '${object.text('count')} / ${object.text('capacity')}'
      : object.text('count');
  String _percent(num? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)}%';
  String _bytesValue(num? value) =>
      value == null ? '—' : value.toInt().toString();
  String _bytes(num? value) => value == null ? '—' : '${value.toInt()} B';

  Future<void> _export(FreeRtosSnapshot data) async {
    setState(() => _exporting = true);
    try {
      final location = await getSaveLocation(
        suggestedName: 'freertos-snapshot-${data.text('sequence')}.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'FreeRTOS 快照', extensions: ['json']),
        ],
      );
      if (location == null) return;
      final bytes = Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'format': 'take-a-look-freertos',
            'formatVersion': 1,
            'firmwarePath': controller.firmwarePath,
            'connectionKind': controller.connectionKind,
            'offline': offline,
            ...data.data,
          }),
        ),
      );
      await XFile.fromData(
        bytes,
        mimeType: 'application/json',
      ).saveTo(location.path);
      controller.report('FreeRTOS 快照已导出：${location.path}');
    } catch (error) {
      controller.report('FreeRTOS 快照导出失败：$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _showStack(FreeRtosRecord task) async {
    try {
      final result = await controller.requestFreeRtos('stack', {
        'handle': task.handle,
      });
      if (!mounted) return;
      final address = result['address'] as int;
      final words = (result['words'] as List).cast<int>();
      await showTalDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${task.name} / 保存栈'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result['message'] as String? ?? '',
                    style: workbenchMuted,
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    [
                      for (var i = 0; i < words.length; i++)
                        '${freeRtosAddress(address + i * 4)}  ${freeRtosAddress(words[i])}',
                    ].join('\n'),
                    style: talMono,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TalButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _showSettings() async {
    var rate = (settings['rateHz'] as num? ?? 2).toInt();
    final tick = TextEditingController(
      text: settings['tickHz']?.toString() ?? '',
    );
    final threshold = TextEditingController(
      text: settings['stackWarningPercent']?.toString() ?? '10',
    );
    String? error;
    try {
      await showTalDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('FreeRTOS 显示设置'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('状态刷新频率', style: workbenchMuted),
                    DropdownButton<int>(
                      value: rate,
                      items: [
                        for (final value in [1, 2, 3, 4, 5])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value Hz'),
                          ),
                      ],
                      onChanged: (value) => update(() => rate = value!),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: tick,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Tick 频率（Hz，可留空）',
                        helperText: '留空时优先使用固件导出的频率。',
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: threshold,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '最小栈余量提醒阈值（%）',
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          error!,
                          style: const TextStyle(color: TalColors.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TalButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TalButton(
                onPressed: () {
                  try {
                    final hz = tick.text.trim().isEmpty
                        ? null
                        : int.tryParse(tick.text.trim());
                    if (tick.text.trim().isNotEmpty && hz == null) {
                      throw const FormatException('Tick 频率须为整数。');
                    }
                    _set({
                      'rateHz': rate,
                      'tickHz': hz,
                      'stackWarningPercent': double.tryParse(threshold.text),
                    });
                    Navigator.pop(context);
                  } catch (value) {
                    update(() => error = '$value');
                  }
                },
                child: const Text('保存设置'),
              ),
            ],
          ),
        ),
      );
    } finally {
      tick.dispose();
      threshold.dispose();
    }
  }
}

class _Col {
  _Col(this.key, this.label, this.width, {this.right = false, this.onSort});
  final String key, label;
  final double width;
  final bool right;
  final VoidCallback? onSort;
}

class _KernelTable extends StatefulWidget {
  const _KernelTable({
    super.key,
    required this.name,
    required this.columns,
    required this.rows,
    required this.selected,
    required this.onSelect,
    required this.cells,
    required this.widths,
    required this.onWidths,
  });
  final String name;
  final List<_Col> columns;
  final List<FreeRtosRecord> rows;
  final int? selected;
  final ValueChanged<FreeRtosRecord> onSelect;
  final List<Widget> Function(FreeRtosRecord) cells;
  final Map<String, dynamic> widths;
  final ValueChanged<Map<String, double>> onWidths;
  @override
  State<_KernelTable> createState() => _KernelTableState();
}

class _KernelTableState extends State<_KernelTable> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final Map<String, double> _dragWidths = {};
  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  double _width(_Col col) =>
      _dragWidths[col.key] ??
      (widget.widths['${widget.name}.${col.key}'] as num?)?.toDouble() ??
      col.width;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final base = widget.columns.fold<double>(
        0,
        (sum, col) => sum + _width(col),
      );
      final firstKey = widget.columns.first.key;
      final explicitFirst =
          widget.widths.containsKey('${widget.name}.$firstKey') ||
          _dragWidths.containsKey(firstKey);
      final extra = explicitFirst
          ? 0.0
          : math.max(0.0, constraints.maxWidth - base);
      final widths = [
        for (var i = 0; i < widget.columns.length; i++)
          _width(widget.columns[i]) + (i == 0 ? extra : 0),
      ];
      Widget row(List<Widget> children, {bool header = false}) => Row(
        children: [
          for (var i = 0; i < children.length; i++)
            SizedBox(
              width: widths[i],
              child: Align(
                alignment: widget.columns[i].right
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  child: children[i],
                ),
              ),
            ),
        ],
      );
      return Scrollbar(
        controller: _horizontal,
        thumbVisibility: true,
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(base, constraints.maxWidth),
            height: constraints.maxHeight,
            child: Column(
              children: [
                Container(
                  height: 36,
                  color: WorkbenchColors.surface,
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.columns.length; i++)
                        SizedBox(
                          width: widths[i],
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: InkWell(
                                  onTap: widget.columns[i].onSort,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 11,
                                    ),
                                    child: Align(
                                      alignment: widget.columns[i].right
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: Text(
                                        widget.columns[i].label,
                                        style: workbenchMuted,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                top: 0,
                                bottom: 0,
                                width: 8,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.resizeLeftRight,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragStart: (_) => setState(
                                      () => _dragWidths[widget.columns[i].key] =
                                          widths[i],
                                    ),
                                    onHorizontalDragUpdate: (d) => setState(
                                      () => _dragWidths[widget.columns[i].key] =
                                          (_width(widget.columns[i]) +
                                                  d.delta.dx)
                                              .clamp(64, 600),
                                    ),
                                    onHorizontalDragEnd: (_) {
                                      widget.onWidths({
                                        for (final entry in _dragWidths.entries)
                                          '${widget.name}.${entry.key}':
                                              entry.value,
                                      });
                                      setState(_dragWidths.clear);
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: widget.rows.isEmpty
                      ? const Center(
                          child: Text('没有匹配项。', style: workbenchMuted),
                        )
                      : Scrollbar(
                          controller: _vertical,
                          child: ListView.builder(
                            controller: _vertical,
                            itemExtent: TalUiTheme.of(context).touchOptimized
                                ? 52
                                : 42,
                            itemCount: widget.rows.length,
                            itemBuilder: (context, index) {
                              final data = widget.rows[index],
                                  selected =
                                      widget.selected ==
                                      widget.rows[index].handle;
                              return Semantics(
                                selected: selected,
                                button: true,
                                label: data.name,
                                child: InkWell(
                                  onTap: () => widget.onSelect(data),
                                  child: Container(
                                    color: selected
                                        ? TalColors.selection
                                        : null,
                                    foregroundDecoration: BoxDecoration(
                                      border: Border(
                                        left: BorderSide(
                                          color: selected
                                              ? TalColors.accent
                                              : Colors.transparent,
                                          width: 3,
                                        ),
                                        bottom: const BorderSide(
                                          color: TalColors.borderSoft,
                                        ),
                                      ),
                                    ),
                                    child: row(widget.cells(data)),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
