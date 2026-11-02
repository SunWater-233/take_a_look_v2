part of 'watch_panel.dart';

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
          Expanded(child: WatchPanel(controller: controller)),
        ],
      ),
    ),
  ),
);

class _WatchMemberDetails extends StatelessWidget {
  const _WatchMemberDetails({
    super.key,
    required this.controller,
    required this.watch,
    required this.node,
  });
  final TakeALookController controller;
  final WatchItem watch;
  final WatchTreeNode node;
  String get _key => watch.symbol.key;

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    final aggregate = node.children.isNotEmpty;
    return Container(
      key: const ValueKey('watch-member-details'),
      width: double.infinity,
      decoration: const BoxDecoration(
        color: TalColors.background,
        border: Border(top: BorderSide(color: TalColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(watch.symbol.name, style: talMono, softWrap: true),
          const SizedBox(height: 3),
          Text(
            '${watch.symbol.type}  ${watch.symbol.addressLabel}${watch.symbol.writable ? '' : '  只读'}',
            style: workbenchMuted.copyWith(fontSize: 11),
          ),
          if (aggregate) ...[
            const SizedBox(height: 12),
            Text('${node.children.length} 个直接成员', style: workbenchMuted),
            const SizedBox(height: 4),
            const Text('展开后刷新可见成员。', style: workbenchMuted),
          ] else ...[
            const SizedBox(height: 6),
            AnimatedBuilder(
              animation: controller.telemetryChanges,
              builder: (_, _) => Text(
                watch.updatedAtMs == null ? '—' : watch.valueLabel,
                key: ValueKey('watch-detail-value-$_key'),
                style: talMono.copyWith(fontSize: 22),
              ),
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TalButton.icon(
                  onPressed: () =>
                      controller.setWatchPinned(_key, !watch.pinned),
                  icon: Icon(
                    watch.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 14,
                  ),
                  label: Text(watch.pinned ? '已固定' : '固定成员'),
                ),
                TalButton.icon(
                  key: ValueKey('watch-detail-capture-$_key'),
                  onPressed: () {
                    controller.setWatchReadMode(
                      _key,
                      watch.samplingEnabled
                          ? WatchReadMode.monitor
                          : WatchReadMode.capture,
                    );
                  },
                  icon: const Icon(Icons.sensors, size: 15),
                  label: Text(watch.samplingEnabled ? '移出采集' : '加入采集'),
                ),
                if (watch.samplingEnabled)
                  TalButton.icon(
                    key: ValueKey('watch-detail-plot-$_key'),
                    onPressed: () =>
                        controller.toggleWatchPlot(_key, !watch.plotted),
                    icon: Icon(
                      watch.plotted
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 15,
                    ),
                    label: Text(watch.plotted ? '隐藏曲线' : '显示曲线'),
                  ),
                SizedBox(
                  width: ui.touchOptimized ? 112 : 96,
                  child: TalDropdown<WatchReadMode>(
                    key: ValueKey('watch-read-mode-$_key'),
                    subtle: true,
                    value: watch.readMode,
                    values: WatchReadMode.values,
                    label: (mode) => mode.label,
                    onChanged: (mode) =>
                        controller.setWatchReadMode(_key, mode),
                  ),
                ),
                if (watch.readMode == WatchReadMode.manual)
                  TalButton(
                    onPressed:
                        controller.connectionStatus ==
                            ConnectionStatus.connected
                        ? () => controller.readWatch(_key)
                        : null,
                    child: const Text('立即读取'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
