import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_state.dart';
import 'models.dart';

class TakeALookApp extends StatelessWidget {
  const TakeALookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Take A Look',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: TalColors.background,
        colorScheme: const ColorScheme.dark(
          primary: TalColors.cyan,
          secondary: TalColors.green,
          surface: TalColors.surface,
          error: TalColors.red,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 36),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(34, 34),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: TalColors.field,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: TalColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: TalColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: TalColors.cyan),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
        ),
      ),
      home: const TakeALookHome(),
    );
  }
}

class TakeALookHome extends StatefulWidget {
  const TakeALookHome({super.key});

  @override
  State<TakeALookHome> createState() => _TakeALookHomeState();
}

class _TakeALookHomeState extends State<TakeALookHome>
    with SingleTickerProviderStateMixin {
  late final TakeALookController controller;
  late final Ticker ticker;

  @override
  void initState() {
    super.initState();
    controller = TakeALookController();
    ticker = createTicker(controller.pump)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopCommandBar(controller: controller),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 1180) {
                    return _CompactWorkspace(controller: controller);
                  }
                  return _DesktopWorkspace(controller: controller);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopWorkspace extends StatelessWidget {
  const _DesktopWorkspace({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 340,
            child: Column(
              children: [
                SizedBox(
                  height: 236,
                  child: ConnectionPanel(controller: controller),
                ),
                const SizedBox(height: 10),
                Expanded(child: SymbolBrowserPanel(controller: controller)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: [
                Expanded(child: LivePlotPanel(controller: controller)),
                const SizedBox(height: 10),
                SizedBox(
                  height: 148,
                  child: EventLogPanel(controller: controller),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 450,
            child: Column(
              children: [
                Expanded(child: WatchTablePanel(controller: controller)),
                const SizedBox(height: 10),
                SizedBox(
                  height: 250,
                  child: SamplingPanel(controller: controller),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactWorkspace extends StatelessWidget {
  const _CompactWorkspace({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        SizedBox(height: 236, child: ConnectionPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 520, child: LivePlotPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 420, child: WatchTablePanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(
          height: 390,
          child: SymbolBrowserPanel(controller: controller),
        ),
        const SizedBox(height: 10),
        SizedBox(height: 250, child: SamplingPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 180, child: EventLogPanel(controller: controller)),
      ],
    );
  }
}

class TopCommandBar extends StatelessWidget {
  const TopCommandBar({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: TalColors.topBar,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Row(
            children: [
              const Icon(Icons.tune, color: TalColors.cyan, size: 24),
              const SizedBox(width: 10),
              const Text(
                'Take A Look',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      StatusPill(
                        icon: Icons.memory,
                        label: controller.connectionPhase.label,
                        color: _phaseColor(controller.connectionPhase),
                      ),
                      StatusPill(
                        icon: Icons.insert_drive_file_outlined,
                        label: controller.symbolFileName,
                        color: TalColors.amber,
                      ),
                      StatusPill(
                        icon: Icons.speed,
                        label: controller.sampleRateLabel,
                        color: TalColors.green,
                      ),
                      StatusPill(
                        icon: Icons.timeline,
                        label: '${controller.plottedSeriesCount} 曲线',
                        color: TalColors.cyan,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ToolbarButton(
                icon: Icons.folder_open,
                label: '加载 ELF/AXF',
                onPressed: controller.loadSymbols,
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: controller.toggleProbe,
                icon: Icon(
                  controller.connectionPhase == ProbeConnectionPhase.connected
                      ? Icons.link_off
                      : Icons.usb,
                  size: 18,
                ),
                label: Text(
                  controller.connectionPhase == ProbeConnectionPhase.connected
                      ? '断开探针'
                      : '连接探针',
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '复位运行',
                onPressed: () => controller.resetTarget(halt: false),
                icon: const Icon(Icons.restart_alt),
              ),
              IconButton(
                tooltip: '导出 CSV',
                onPressed: () => controller.addLog('CSV 导出任务已创建'),
                icon: const Icon(Icons.download),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ConnectionPanel extends StatefulWidget {
  const ConnectionPanel({required this.controller, super.key});

  final TakeALookController controller;

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
  const SymbolBrowserPanel({required this.controller, super.key});

  final TakeALookController controller;

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
  const WatchTablePanel({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.table_chart_outlined,
      title: '实时调参',
      padding: EdgeInsets.zero,
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
  const SamplingPanel({required this.controller, super.key});

  final TakeALookController controller;

  static const rateOptions = <double>[50, 100, 250, 500, 1000, 2000, 5000];
  static const refreshOptions = <String>['60 Hz', '120 Hz', '自适应'];

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.av_timer,
      title: '采样与显示',
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
  const LivePlotPanel({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.show_chart,
      title: '实时曲线',
      padding: EdgeInsets.zero,
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

class ChartLegend extends StatelessWidget {
  const ChartLegend({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final plotted = controller.watches
            .where((watch) => watch.plotting)
            .toList();
        if (plotted.isEmpty) {
          return const SizedBox.shrink();
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final watch in plotted.take(10))
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: TalColors.surface.withAlpha(210),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: TalColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: watch.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(watch.symbol.name, style: TalText.legend),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class TelemetryChartPainter extends CustomPainter {
  TelemetryChartPainter(this.controller) : super(repaint: controller);

  final TakeALookController controller;

  static const leftPad = 54.0;
  static const rightPad = 18.0;
  static const topPad = 52.0;
  static const bottomPad = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(1, size.width - leftPad - rightPad),
      math.max(1, size.height - topPad - bottomPad),
    );

    final backgroundPaint = Paint()..color = TalColors.plotBackground;
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    final borderPaint = Paint()
      ..color = TalColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(plot, borderPaint);

    final end = math.max(
      controller.elapsedSeconds,
      controller.visibleWindowSeconds,
    );
    final start = math.max(0.0, end - controller.visibleWindowSeconds);
    var yMin = double.infinity;
    var yMax = -double.infinity;

    final plotted = controller.watches
        .where((watch) => watch.plotting)
        .toList(growable: false);
    final maxPoints = math.max(300, (plot.width * 1.6).round()).toInt();
    final stride = math
        .max(
          1,
          ((controller.visibleWindowSeconds * controller.sampleRateHz) /
                  maxPoints)
              .floor(),
        )
        .toInt();

    for (final watch in plotted) {
      watch.series.forEachWindow(start, end, stride, (_, value) {
        yMin = math.min(yMin, value);
        yMax = math.max(yMax, value);
      });
    }
    if (!yMin.isFinite || !yMax.isFinite || (yMax - yMin).abs() < 0.0001) {
      yMin = -1;
      yMax = 1;
    } else {
      final pad = (yMax - yMin) * 0.12;
      yMin -= pad;
      yMax += pad;
    }

    if (controller.showGrid) {
      _drawGrid(canvas, plot, start, end, yMin, yMax);
    } else {
      _drawAxisLabels(canvas, plot, start, end, yMin, yMax);
    }

    final clipPath = Path()..addRect(plot.deflate(1));
    canvas.save();
    canvas.clipPath(clipPath);
    for (final watch in plotted) {
      _drawSeries(canvas, plot, watch, start, end, yMin, yMax, stride);
    }
    canvas.restore();
  }

  void _drawGrid(
    Canvas canvas,
    Rect plot,
    double start,
    double end,
    double yMin,
    double yMax,
  ) {
    final gridPaint = Paint()
      ..color = TalColors.grid
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = TalColors.border
      ..strokeWidth = 1;

    for (var i = 0; i <= 6; i += 1) {
      final x = plot.left + plot.width * i / 6;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
    }
    for (var i = 0; i <= 4; i += 1) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      axisPaint,
    );
    canvas.drawLine(
      Offset(plot.left, plot.top),
      Offset(plot.left, plot.bottom),
      axisPaint,
    );
    _drawAxisLabels(canvas, plot, start, end, yMin, yMax);
  }

  void _drawAxisLabels(
    Canvas canvas,
    Rect plot,
    double start,
    double end,
    double yMin,
    double yMax,
  ) {
    for (var i = 0; i <= 3; i += 1) {
      final value = yMax - (yMax - yMin) * i / 3;
      final y = plot.top + plot.height * i / 3;
      _drawText(
        canvas,
        value.abs() >= 1000
            ? value.toStringAsFixed(0)
            : value.toStringAsFixed(2),
        Offset(8, y - 8),
        TalColors.textMuted,
        align: TextAlign.right,
        width: leftPad - 12,
      );
    }
    for (var i = 0; i <= 3; i += 1) {
      final value = start + (end - start) * i / 3;
      final x = plot.left + plot.width * i / 3;
      _drawText(
        canvas,
        '${value.toStringAsFixed(value < 10 ? 2 : 1)}s',
        Offset(x - 24, plot.bottom + 9),
        TalColors.textMuted,
        width: 48,
        align: TextAlign.center,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    WatchVariable watch,
    double start,
    double end,
    double yMin,
    double yMax,
    int stride,
  ) {
    final path = Path();
    var started = false;
    final xScale = plot.width / math.max(0.001, end - start);
    final yScale = plot.height / math.max(0.001, yMax - yMin);

    watch.series.forEachWindow(start, end, stride, (time, value) {
      final x = plot.left + (time - start) * xScale;
      final y = plot.bottom - (value - yMin) * yScale;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    });
    if (!started) {
      return;
    }
    final shadow = Paint()
      ..color = watch.color.withAlpha(36)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final paint = Paint()
      ..color = watch.color
      ..strokeWidth = 1.7
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, shadow);
    canvas.drawPath(path, paint);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color, {
    double width = 80,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          letterSpacing: 0,
          fontFeatures: const [],
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TelemetryChartPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}

class EventLogPanel extends StatelessWidget {
  const EventLogPanel({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Panel(
      icon: Icons.terminal,
      title: '事件日志',
      padding: EdgeInsets.zero,
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

class Panel extends StatelessWidget {
  const Panel({
    required this.icon,
    required this.title,
    required this.child,
    this.actions = const [],
    this.padding = const EdgeInsets.all(12),
    super.key,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: TalColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TalColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.only(left: 12, right: 6),
              decoration: const BoxDecoration(
                color: TalColors.panelHeader,
                border: Border(bottom: BorderSide(color: TalColors.border)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: TalColors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TalText.panelTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Expanded(
              child: Padding(padding: padding, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.icon,
    required this.label,
    required this.color,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TalColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label, style: TalText.pill),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({required this.color, super.key});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(90),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        side: const BorderSide(color: TalColors.borderBright),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class ToggleActionButton extends StatelessWidget {
  const ToggleActionButton({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selectedLabel,
    required this.onPressed,
    super.key,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String selectedLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(selected ? selectedIcon : icon, size: 18),
      label: Text(selected ? selectedLabel : label),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? TalColors.amber : TalColors.text,
        minimumSize: const Size(0, 36),
        side: BorderSide(
          color: selected ? TalColors.amber : TalColors.borderBright,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TalColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TalText.muted),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TalText.metric,
          ),
        ],
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      dropdownColor: TalColors.surface,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options)
          DropdownMenuItem<String>(
            value: option,
            child: Text(option, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (next) {
        if (next != null) {
          onChanged(next);
        }
      },
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.value,
    required this.values,
    required this.labelBuilder,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: TalColors.field,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TalColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: TalColors.surface,
          items: [
            for (final item in values)
              DropdownMenuItem<T>(
                value: item,
                child: Text(labelBuilder(item), style: TalText.body),
              ),
          ],
          onChanged: (next) {
            if (next != null) {
              onChanged(next);
            }
          },
        ),
      ),
    );
  }
}

Color _phaseColor(ProbeConnectionPhase phase) {
  switch (phase) {
    case ProbeConnectionPhase.disconnected:
      return TalColors.textMuted;
    case ProbeConnectionPhase.connecting:
      return TalColors.amber;
    case ProbeConnectionPhase.connected:
      return TalColors.green;
  }
}

Color _logColor(LogLevel level) {
  switch (level) {
    case LogLevel.info:
      return TalColors.textMuted;
    case LogLevel.success:
      return TalColors.green;
    case LogLevel.warning:
      return TalColors.amber;
    case LogLevel.error:
      return TalColors.red;
  }
}

class TalColors {
  const TalColors._();

  static const background = Color(0xFF0E1114);
  static const topBar = Color(0xFF12171C);
  static const surface = Color(0xFF151B21);
  static const panelHeader = Color(0xFF192029);
  static const header = Color(0xFF111820);
  static const field = Color(0xFF10161C);
  static const plotBackground = Color(0xFF0B0F13);
  static const border = Color(0xFF26313B);
  static const borderSoft = Color(0xFF1F2831);
  static const borderBright = Color(0xFF3B4652);
  static const grid = Color(0xFF1B2630);
  static const text = Color(0xFFE8EAED);
  static const textMuted = Color(0xFF9AA6B2);
  static const cyan = Color(0xFF51C7F8);
  static const green = Color(0xFF7BD88F);
  static const amber = Color(0xFFFFC857);
  static const red = Color(0xFFFF6B8A);
}

class TalText {
  const TalText._();

  static const body = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    letterSpacing: 0,
  );
  static const bodyStrong = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const muted = TextStyle(
    color: TalColors.textMuted,
    fontSize: 12,
    letterSpacing: 0,
  );
  static const panelTitle = TextStyle(
    color: TalColors.text,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const pill = TextStyle(
    color: TalColors.text,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const code = TextStyle(
    color: TalColors.cyan,
    fontSize: 11,
    fontFeatures: [],
    letterSpacing: 0,
  );
  static const mutedCode = TextStyle(
    color: TalColors.textMuted,
    fontSize: 11,
    fontFeatures: [],
    letterSpacing: 0,
  );
  static const column = TextStyle(
    color: TalColors.textMuted,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const value = TextStyle(
    color: TalColors.green,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const metric = TextStyle(
    color: TalColors.text,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const legend = TextStyle(
    color: TalColors.text,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const warning = TextStyle(
    color: TalColors.amber,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const log = TextStyle(fontSize: 12, letterSpacing: 0);
}
