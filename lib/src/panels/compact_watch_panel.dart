part of 'panels.dart';

Future<void> showFullWatchTable(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: SizedBox(
      width: 1180,
      height: math.min(680, MediaQuery.sizeOf(context).height - 100),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Text('完整变量表', style: talStrong),
                const Spacer(),
                TalIconButton(
                  tooltip: '关闭完整变量表',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Expanded(child: _WatchPanel(controller: controller)),
        ],
      ),
    ),
  ),
);

class _CompactWatchPanel extends StatefulWidget {
  const _CompactWatchPanel({
    required this.controller,
    this.onShowSource,
    this.onShowSymbols,
  });
  final TakeALookController controller;
  final VoidCallback? onShowSource;
  final VoidCallback? onShowSymbols;
  @override
  State<_CompactWatchPanel> createState() => _CompactWatchPanelState();
}

class _CompactWatchPanelState extends State<_CompactWatchPanel> {
  final _clock = ValueNotifier<int>(0);
  late final Timer _timer;
  int _plotSelectionRevision = -1;
  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _clock.value++);
  }

  @override
  void dispose() {
    _timer.cancel();
    _clock.dispose();
    super.dispose();
  }

  void _select(String key) {
    setState(() => controller.compactWatchSelection = key);
    controller.setPlotHighlightedWatch(key);
  }

  List<({WatchTreeNode node, int depth})> _visibleRows(
    List<WatchTreeNode> roots,
  ) {
    final result = <({WatchTreeNode node, int depth})>[];
    void visit(WatchTreeNode node, int depth) {
      result.add((node: node, depth: depth));
      if (controller.compactExpandedWatches.contains(node.watch.symbol.key)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return result;
  }

  void _syncSelection(List<WatchTreeNode> roots) {
    final keys = controller.watches.map((w) => w.symbol.key).toSet();
    if (!keys.contains(controller.compactWatchSelection)) {
      controller.compactWatchSelection =
          controller.watches.firstOrNull?.symbol.key;
    }
    if (_plotSelectionRevision == controller.plotWatchSelectionRevision) return;
    _plotSelectionRevision = controller.plotWatchSelectionRevision;
    final key = controller.plotHighlightedWatchKey;
    if (key == null || !keys.contains(key)) return;
    controller.compactWatchSelection = key;
    bool reveal(WatchTreeNode node) {
      if (node.watch.symbol.key == key) return true;
      for (final child in node.children) {
        if (reveal(child)) {
          controller.compactExpandedWatches.add(node.watch.symbol.key);
          return true;
        }
      }
      return false;
    }

    for (final root in roots) {
      if (reveal(root)) break;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.watchChanges,
      controller.samplingChanges,
      controller.connectionChanges,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 40) return const SizedBox.shrink();
        final roots = buildWatchTree(controller.watches);
        _syncSelection(roots);
        final rows = _visibleRows(roots);
        final selected = controller.watches
            .where((w) => w.symbol.key == controller.compactWatchSelection)
            .firstOrNull;
        return Material(
          color: WorkbenchColors.surface,
          child: Column(
            children: [
              _toolbar(context),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('从资源库加入变量', style: workbenchMuted),
                              const SizedBox(height: 10),
                              if (widget.onShowSymbols != null)
                                TalButton(
                                  onPressed: widget.onShowSymbols,
                                  child: const Text('打开资源库'),
                                ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('compact-watch-list'),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final item = rows[index],
                              node = item.node,
                              watch = node.watch;
                          if (node.children.isNotEmpty) {
                            return InkWell(
                              onTap: () => setState(() {
                                if (!controller.compactExpandedWatches.add(
                                  watch.symbol.key,
                                )) {
                                  controller.compactExpandedWatches.remove(
                                    watch.symbol.key,
                                  );
                                }
                              }),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  8 + item.depth * 8,
                                  12,
                                  8,
                                  12,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      controller.compactExpandedWatches
                                              .contains(watch.symbol.key)
                                          ? Icons.expand_more
                                          : Icons.chevron_right,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        node.label,
                                        style: talMono,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '${node.children.length}',
                                      style: workbenchMuted,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                          return WatchRowAnchor(
                            key: ValueKey('compact-watch-${watch.symbol.key}'),
                            controller: controller,
                            watchKey: watch.symbol.key,
                            child: _CompactWatchRow(
                              key: ValueKey(watch.symbol.key),
                              controller: controller,
                              watch: watch,
                              label: node.label,
                              depth: item.depth,
                              selected:
                                  watch.symbol.key ==
                                  controller.compactWatchSelection,
                              onSelect: () => _select(watch.symbol.key),
                            ),
                          );
                        },
                      ),
              ),
              if (selected != null && constraints.maxHeight >= 330)
                AnimatedBuilder(
                  animation: Listenable.merge([
                    controller.telemetryChanges,
                    _clock,
                  ]),
                  builder: (context, _) => _details(context, selected),
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _toolbar(BuildContext context) {
    final ui = TalUiTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: const BoxDecoration(
        color: WorkbenchColors.input,
        border: Border(bottom: BorderSide(color: WorkbenchColors.border)),
      ),
      child: Row(
        children: [
          const Flexible(
            child: Text(
              '监视默认',
              style: workbenchMuted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: ui.touchOptimized ? 106 : 90,
            child: TalDropdown<double>(
              key: const ValueKey('watch-default-monitor-rate'),
              value: controller.monitorRateHz,
              values: const [0.5, 1, 2, 5, 10],
              label: formatReadRate,
              onChanged: controller.setMonitorRate,
            ),
          ),
          const Spacer(),
          TalIconButton(
            key: const ValueKey('watch-open-full-table'),
            tooltip: '完整变量表',
            onPressed: () => showFullWatchTable(context, controller),
            icon: const Icon(Icons.table_chart_outlined, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, WatchItem watch) {
    final updated = watch.updatedAtMs;
    final age = updated == null
        ? null
        : math.max(0, DateTime.now().millisecondsSinceEpoch - updated);
    final ageLabel = age == null
        ? '尚未读取'
        : age < 100
        ? '刚刚更新'
        : age < 60000
        ? '${(age / 1000).toStringAsFixed(1)} 秒前更新'
        : '${age ~/ 60000} 分钟前更新';
    final pushed = controller.usesDevicePush(watch);
    final policy = watch.readMode == WatchReadMode.manual
        ? '点击刷新时读取'
        : pushed
        ? '设备推送'
        : watch.samplingEnabled
        ? '采集 ${formatReadRate(controller.sampleRateHz)}'
        : '每 ${(1000 / controller.monitorRateFor(watch)).round()} ms 读取一次';
    final recording = watch.samplingEnabled
        ? (controller.samplingPaused ? '记录暂停' : '记录开启')
        : watch.samples.isEmpty
        ? '不新增历史'
        : '已有记录保留';
    final stale = controller.connectionStatus != ConnectionStatus.connected;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 7),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: WorkbenchColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: watch.symbol.name,
                  child: Text(
                    watch.symbol.name,
                    style: talMono,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ageLabel,
                style: workbenchMuted.copyWith(
                  fontSize: 11,
                  color: stale ? TalColors.amber : WorkbenchColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 3,
            children: [
              Text(policy, style: workbenchMuted.copyWith(fontSize: 11)),
              Text(recording, style: workbenchMuted.copyWith(fontSize: 11)),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TalButton.icon(
              variant: TalButtonVariant.text,
              onPressed: stale
                  ? null
                  : () => controller.readWatch(watch.symbol.key),
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('立即读取'),
            ),
          ),
          ExpansionTile(
            key: ValueKey('compact-watch-details-${watch.symbol.key}'),
            dense: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 4),
            minTileHeight: 28,
            title: const Text('变量详情', style: workbenchMuted),
            children: [
              Row(
                children: [
                  Text(watch.symbol.addressLabel, style: talMono),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      '${watch.symbol.type} / ${watch.symbol.size} B',
                      style: workbenchMuted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (pushed)
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text('读取频率由设备推送决定。', style: workbenchMuted),
                ),
              Wrap(
                spacing: 12,
                children: [
                  TalButton(
                    variant: TalButtonVariant.text,
                    onPressed: watch.symbol.source.isEmpty
                        ? null
                        : () {
                            controller.addSourceFileFromSymbols(
                              watch.symbol.source,
                            );
                            widget.onShowSource?.call();
                          },
                    child: const Text('定位源码'),
                  ),
                  TalButton(
                    variant: TalButtonVariant.text,
                    onPressed: () => controller.removeWatch(watch.symbol.key),
                    child: const Text('移除变量'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactWatchRow extends StatefulWidget {
  const _CompactWatchRow({
    super.key,
    required this.controller,
    required this.watch,
    required this.label,
    required this.depth,
    required this.selected,
    required this.onSelect,
  });
  final TakeALookController controller;
  final WatchItem watch;
  final String label;
  final int depth;
  final bool selected;
  final VoidCallback onSelect;
  @override
  State<_CompactWatchRow> createState() => _CompactWatchRowState();
}

class _CompactWatchRowState extends State<_CompactWatchRow> {
  late final TextEditingController _editor;
  final _focus = FocusNode();
  String get _key => widget.watch.symbol.key;
  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(
      text:
          widget.controller.watchInputDrafts[_key] ??
          (widget.watch.updatedAtMs == null ? '' : widget.watch.valueLabel),
    );
    widget.controller.telemetryChanges.addListener(_syncReadValue);
  }

  void _syncReadValue() {
    if (!mounted || _focus.hasFocus) return;
    final text =
        widget.controller.watchInputDrafts[_key] ??
        (widget.watch.updatedAtMs == null ? '' : widget.watch.valueLabel);
    if (_editor.text != text) {
      _editor.text = text;
    }
  }

  @override
  void didUpdateWidget(covariant _CompactWatchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncReadValue();
  }

  @override
  void dispose() {
    widget.controller.telemetryChanges.removeListener(_syncReadValue);
    _editor.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context),
        watch = widget.watch,
        controller = widget.controller;
    return AnimatedBuilder(
      animation: controller.telemetryChanges,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final canWrite =
              controller.connectionStatus == ConnectionStatus.connected &&
              controller.supportsMemoryWrite &&
              watch.symbol.writable;
          final compact =
              constraints.maxWidth < (ui.touchOptimized ? 330 : 245);
          final value = watch.updatedAtMs == null ? '—' : watch.valueLabel;
          Widget valueLabel() => Tooltip(
            message: value,
            child: Text(
              value,
              style: talMono,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
          final editor = SizedBox(
            height: ui.controlHeight,
            child: TextField(
              key: ValueKey('compact-watch-input-$_key'),
              controller: _editor,
              focusNode: _focus,
              style: talMono,
              textAlign: TextAlign.right,
              enabled: watch.symbol.writable,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '新值',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 6,
                ),
              ),
              onChanged: (value) {
                controller.watchInputDrafts[_key] = value;
                setState(() {});
              },
              onSubmitted: canWrite
                  ? (value) => controller.writeWatch(_key, value)
                  : null,
            ),
          );
          final write = SizedBox(
            width: ui.touchOptimized ? 55 : 44,
            child: TalButton(
              key: ValueKey('compact-watch-write-$_key'),
              variant: TalButtonVariant.filled,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 5),
                ),
              ),
              onPressed: canWrite && _editor.text.isNotEmpty
                  ? () => controller.writeWatch(_key, _editor.text)
                  : null,
              child: const Text('写入'),
            ),
          );
          final action = SizedBox(
            width: ui.iconButtonSize,
            child: TalIconButton(
              key: ValueKey('compact-watch-plot-$_key'),
              tooltip: watch.readMode == WatchReadMode.manual
                  ? '立即读取'
                  : watch.plotted
                  ? '隐藏曲线'
                  : '显示曲线',
              onPressed: watch.readMode == WatchReadMode.manual
                  ? (controller.connectionStatus == ConnectionStatus.connected
                        ? () => controller.readWatch(_key)
                        : null)
                  : watch.samplingEnabled
                  ? () => controller.toggleWatchPlot(_key, !watch.plotted)
                  : null,
              icon: Icon(
                watch.readMode == WatchReadMode.manual
                    ? Icons.refresh
                    : watch.plotted
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 16,
              ),
            ),
          );
          final actions = Row(
            children: [
              if (!compact) Expanded(child: valueLabel()),
              if (!compact) const SizedBox(width: 6),
              if (compact)
                Expanded(child: editor)
              else
                SizedBox(width: ui.touchOptimized ? 94 : 82, child: editor),
              const SizedBox(width: 4),
              write,
              action,
            ],
          );
          return InkWell(
            onTap: widget.onSelect,
            onSecondaryTap: widget.onSelect,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                8 + math.min(widget.depth, 3) * 8,
                5,
                7,
                5,
              ),
              decoration: BoxDecoration(
                color: widget.selected
                    ? WorkbenchColors.selection
                    : WorkbenchColors.surface,
                border: Border(
                  left: BorderSide(
                    color: widget.selected
                        ? TalColors.accent
                        : Colors.transparent,
                    width: 2,
                  ),
                  bottom: const BorderSide(color: WorkbenchColors.border),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 3,
                        height: 12,
                        color: watch.samplingEnabled
                            ? watch.color
                            : Colors.transparent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Tooltip(
                          message: watch.symbol.name,
                          child: Text(
                            widget.label,
                            style: talMono,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: ui.touchOptimized ? 140 : 108,
                        child: TalDropdown<WatchReadMode>(
                          key: ValueKey('watch-read-mode-$_key'),
                          value: watch.readMode,
                          values: WatchReadMode.values,
                          label: (mode) => mode.label,
                          onChanged: (mode) {
                            widget.onSelect();
                            controller.setWatchReadMode(_key, mode);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (compact)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: valueLabel(),
                    ),
                  actions,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
