part of '../take_a_look_app.dart';

class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  static const probeOptions = <String>[
    '自动发现',
    'CMSIS-DAP',
    'ST-Link',
    'J-Link',
  ];
  static const targetOptions = <String>[
    'auto',
    'STM32F407',
    'STM32G431',
    'STM32H743',
    'nRF52840',
  ];
  static const clockOptions = <String>[
    '100 kHz',
    '400 kHz',
    '1 MHz',
    '4 MHz',
    '8 MHz',
    '24 MHz',
  ];

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.settings_input_component,
      title: '连接设置',
      chrome: widget.chrome,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _DropdownField(
                      label: '探针',
                      value: widget.controller.probeType,
                      options: probeOptions,
                      onChanged: widget.controller.updateProbeType,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DropdownField(
                      label: '目标',
                      value: widget.controller.targetName,
                      options: targetOptions,
                      onChanged: widget.controller.updateTargetName,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: _DropdownField(
                      label: 'SWD 时钟',
                      value: widget.controller.swdClock,
                      options: clockOptions,
                      onChanged: widget.controller.updateSwdClock,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      onChanged: widget.controller.updateSerialNumber,
                      style: TalText.body,
                      decoration: const InputDecoration(
                        labelText: '序列号',
                        hintText: '自动',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TalColors.field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TalColors.border),
                ),
                child: Row(
                  children: [
                    StatusDot(
                      color: _phaseColor(widget.controller.connectionPhase),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.controller.connectionPhase.label,
                            style: TalText.bodyStrong,
                          ),
                          Text(
                            '${widget.controller.probeType} · ${widget.controller.targetName} · ${widget.controller.swdClock}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TalText.muted,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '复位暂停',
                      onPressed: () =>
                          widget.controller.resetTarget(halt: true),
                      icon: const Icon(Icons.pause_circle_outline),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SymbolBrowserPanel extends StatefulWidget {
  const SymbolBrowserPanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  @override
  State<SymbolBrowserPanel> createState() => _SymbolBrowserPanelState();
}

class _SymbolBrowserPanelState extends State<SymbolBrowserPanel> {
  final TextEditingController searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.account_tree_outlined,
      title: '符号变量',
      padding: EdgeInsets.zero,
      chrome: widget.chrome,
      actions: [
        IconButton(
          tooltip: '清除选择',
          onPressed: widget.controller.clearSymbolSelection,
          icon: const Icon(Icons.deselect),
        ),
      ],
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final query = searchController.text;
          final visible = widget.controller.symbols
              .where((symbol) => symbol.matches(query))
              .toList(growable: false);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchController,
                        onChanged: (_) => setState(() {}),
                        style: TalText.body,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: '搜索变量 / 地址 / 类型',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: '全选当前结果',
                      onPressed: visible.isEmpty
                          ? null
                          : () => widget.controller.selectAllVisible(visible),
                      icon: const Icon(Icons.select_all),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${visible.length} / ${widget.controller.symbols.length} 个变量',
                        style: TalText.muted,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: widget.controller.selectedSymbolIds.isEmpty
                          ? null
                          : widget.controller.addSelectedToWatch,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: Text(
                        '加入 ${widget.controller.selectedSymbolIds.length}',
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: TalColors.border),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('没有匹配的符号', style: TalText.muted))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final symbol = visible[index];
                          final selected = widget.controller.selectedSymbolIds
                              .contains(symbol.id);
                          return SymbolVariableTile(
                            symbol: symbol,
                            selected: selected,
                            onToggle: () =>
                                widget.controller.toggleSymbol(symbol),
                            onAdd: () =>
                                widget.controller.addQuickWatch(symbol),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SymbolVariableTile extends StatelessWidget {
  const SymbolVariableTile({
    required this.symbol,
    required this.selected,
    required this.onToggle,
    required this.onAdd,
    super.key,
  });

  final SymbolVariable symbol;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Container(
        height: 58,
        padding: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: selected ? TalColors.cyan.withAlpha(24) : Colors.transparent,
          border: const Border(bottom: BorderSide(color: TalColors.borderSoft)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => onToggle(),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          symbol.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TalText.bodyStrong,
                        ),
                      ),
                      Text(symbol.type, style: TalText.code),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(symbol.addressLabel, style: TalText.mutedCode),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          symbol.shortPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TalText.muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '加入实时调参',
              onPressed: onAdd,
              icon: const Icon(Icons.add_chart, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class WatchTablePanel extends StatelessWidget {
  const WatchTablePanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.table_chart_outlined,
      title: '实时调参',
      padding: EdgeInsets.zero,
      chrome: chrome,
      actions: [
        IconButton(
          tooltip: '清空全部',
          onPressed: controller.clearWatches,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (controller.watches.isEmpty) {
            return const Center(child: Text('尚未加入变量', style: TalText.muted));
          }
          return Column(
            children: [
              const _WatchHeader(),
              Expanded(
                child: ListView.builder(
                  itemCount: controller.watches.length,
                  itemBuilder: (context, index) {
                    final watch = controller.watches[index];
                    return WatchRow(watch: watch, controller: controller);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WatchHeader extends StatelessWidget {
  const _WatchHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: TalColors.header,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 30),
          SizedBox(width: 28),
          Expanded(child: Text('变量', style: TalText.column)),
          SizedBox(width: 86, child: Text('当前值', style: TalText.column)),
          SizedBox(width: 78, child: Text('写入值', style: TalText.column)),
          SizedBox(width: 76, child: Text('操作', style: TalText.column)),
        ],
      ),
    );
  }
}

class WatchRow extends StatelessWidget {
  const WatchRow({required this.watch, required this.controller, super.key});

  final WatchVariable watch;
  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TalColors.borderSoft)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Checkbox(
              value: watch.plotting,
              visualDensity: VisualDensity.compact,
              onChanged: (value) =>
                  controller.setWatchPlotting(watch, value ?? false),
            ),
          ),
          SizedBox(
            width: 28,
            child: Center(
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: watch.color,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    watch.symbol.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TalText.bodyStrong,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${watch.symbol.addressLabel} · ${watch.symbol.type}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TalText.mutedCode,
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 86,
            child: Text(
              watch.currentLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TalText.value,
            ),
          ),
          SizedBox(
            width: 78,
            child: TextField(
              controller: watch.writeController,
              textAlign: TextAlign.right,
              style: TalText.body,
              onSubmitted: (_) => controller.writeWatchValue(watch),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 76,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '写入',
                  onPressed: () => controller.writeWatchValue(watch),
                  icon: const Icon(Icons.save_outlined, size: 18),
                ),
                IconButton(
                  tooltip: '移除',
                  onPressed: () => controller.removeWatch(watch),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SamplingPanel extends StatelessWidget {
  const SamplingPanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  static const rateOptions = <double>[50, 100, 250, 500, 1000, 2000, 5000];
  static const refreshOptions = <String>['60 Hz', '120 Hz', '自适应'];

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.av_timer,
      title: '采样与显示',
      chrome: chrome,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _MetricBlock(
                      label: '采样时间',
                      value: controller.elapsedLabel,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricBlock(
                      label: '帧耗时',
                      value: '${controller.uiFrameMs.toStringAsFixed(1)} ms',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricBlock(
                      label: '预算',
                      value:
                          '${controller.frameBudgetMs.toStringAsFixed(1)} ms',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _SmallDropdown<double>(
                      value: controller.sampleRateHz,
                      values: rateOptions,
                      labelBuilder: (rate) => rate >= 1000
                          ? '${(rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1)} kHz'
                          : '${rate.toStringAsFixed(0)} Hz',
                      onChanged: controller.setSampleRate,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SmallDropdown<String>(
                      value: controller.refreshMode,
                      values: refreshOptions,
                      labelBuilder: (value) => value,
                      onChanged: controller.setRefreshMode,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ToggleActionButton(
                      selected: controller.samplingPaused,
                      selectedIcon: Icons.play_arrow,
                      icon: Icons.pause,
                      selectedLabel: '继续采样',
                      label: '暂停采样',
                      onPressed: controller.toggleSamplingPaused,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ToggleActionButton(
                      selected: controller.plottingPaused,
                      selectedIcon: Icons.visibility,
                      icon: Icons.visibility_off_outlined,
                      selectedLabel: '恢复绘图',
                      label: '冻结绘图',
                      onPressed: controller.togglePlottingPaused,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '清空采样',
                    onPressed: controller.clearSamples,
                    icon: const Icon(Icons.cleaning_services_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    tooltip: controller.followLatest ? '切换手动视图' : '跟随最新',
                    onPressed: controller.toggleFollowLatest,
                    icon: Icon(
                      controller.followLatest
                          ? Icons.keyboard_double_arrow_right
                          : Icons.pan_tool_alt_outlined,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      min: 0.5,
                      max: 120,
                      divisions: 239,
                      value: controller.visibleWindowSeconds.clamp(0.5, 120),
                      onChanged: controller.setVisibleWindow,
                    ),
                  ),
                  SizedBox(
                    width: 62,
                    child: Text(
                      '${controller.visibleWindowSeconds.toStringAsFixed(controller.visibleWindowSeconds < 10 ? 1 : 0)} s',
                      textAlign: TextAlign.right,
                      style: TalText.bodyStrong,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class LivePlotPanel extends StatelessWidget {
  const LivePlotPanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.show_chart,
      title: '实时曲线',
      padding: EdgeInsets.zero,
      chrome: chrome,
      actions: [
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return Row(
              children: [
                IconButton(
                  tooltip: controller.followLatest ? '手动浏览' : '跟随最新',
                  onPressed: controller.toggleFollowLatest,
                  icon: Icon(
                    controller.followLatest
                        ? Icons.my_location
                        : Icons.open_with,
                  ),
                ),
                IconButton(
                  tooltip: controller.showGrid ? '隐藏网格' : '显示网格',
                  onPressed: controller.toggleGrid,
                  icon: Icon(
                    controller.showGrid ? Icons.grid_on : Icons.grid_off,
                  ),
                ),
              ],
            );
          },
        ),
      ],
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                isComplex: true,
                willChange: true,
                painter: TelemetryChartPainter(controller),
              ),
            ),
          ),
          Positioned(
            left: 14,
            top: 12,
            right: 14,
            child: ChartLegend(controller: controller),
          ),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              if (controller.watches.isNotEmpty) {
                return const SizedBox.shrink();
              }
              return const Center(
                child: Text('等待变量加入绘图', style: TalText.muted),
              );
            },
          ),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              if (!controller.plottingPaused) {
                return const SizedBox.shrink();
              }
              return Positioned(
                right: 16,
                bottom: 16,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: TalColors.surface.withAlpha(230),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: TalColors.amber),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('绘图冻结', style: TalText.warning),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class EventLogPanel extends StatelessWidget {
  const EventLogPanel({required this.controller, this.chrome, super.key});

  final TakeALookController controller;
  final PanelChromeConfig? chrome;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.terminal,
      title: '事件日志',
      padding: EdgeInsets.zero,
      chrome: chrome,
      actions: [
        IconButton(
          tooltip: '清空日志',
          onPressed: controller.clearLogs,
          icon: const Icon(Icons.clear_all),
        ),
      ],
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final logs = controller.logs;
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final entry = logs[index];
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: Text(
                  '[${entry.timeLabel}] ${entry.message}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TalText.log.copyWith(color: _logColor(entry.level)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
