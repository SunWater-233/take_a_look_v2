import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../chart/chart.dart';
import '../chart/plot_overview.dart';
import '../controller/controller.dart';
import '../models/models.dart';
import '../theme/theme.dart';

class PlotPanel extends StatefulWidget {
  const PlotPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  State<PlotPanel> createState() => _PlotPanelState();
}

class _PlotPanelState extends State<PlotPanel> {
  final _chart = GlobalKey<TelemetryChartState>();
  TakeALookController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final touch = TalUiTheme.of(context).touchOptimized;
    final overview = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
      child: SizedBox(
        height: touch ? 44 : 30,
        child: PlotOverview(
          controller: controller,
          onOpenRange: (position) =>
              _chart.currentState?.openRangeMenu(position),
        ),
      ),
    );
    return Column(
      children: [
        ColoredBox(
          color: TalColors.background,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 410;
              final actions = _PlotToolbar(
                controller: controller,
                stacked: stacked,
                touch: touch,
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [actions, overview],
                );
              }
              return Row(
                children: [
                  Expanded(child: overview),
                  actions,
                ],
              );
            },
          ),
        ),
        Expanded(
          child: TelemetryChart(key: _chart, controller: controller),
        ),
      ],
    );
  }
}

class _PlotToolbar extends StatelessWidget {
  const _PlotToolbar({
    required this.controller,
    required this.stacked,
    required this.touch,
  });

  final TakeALookController controller;
  final bool stacked;
  final bool touch;

  ButtonStyle _style({bool active = false}) => ButtonStyle(
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: stacked ? 6 : 8),
    ),
    minimumSize: WidgetStatePropertyAll(Size(0, touch ? 44 : 29)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    backgroundColor: active
        ? const WidgetStatePropertyAll(TalColors.selection)
        : null,
    foregroundColor: active
        ? const WidgetStatePropertyAll(TalColors.amber)
        : null,
  );

  @override
  Widget build(BuildContext context) {
    return WorkbenchToolbarOutline(
      attachment: stacked
          ? WorkbenchToolbarAttachment.stretch
          : WorkbenchToolbarAttachment.end,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: AnimatedBuilder(
            animation: controller.plotControlChanges,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TalButton(
                  style: _style(),
                  onPressed: controller.exportCsv,
                  child: const Text('导出 CSV'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    width: 1,
                    height: 16,
                    child: ColoredBox(color: TalColors.border),
                  ),
                ),
                TalButton(
                  variant: TalButtonVariant.text,
                  style: _style(active: controller.followLatest),
                  onPressed: controller.toggleFollowLatest,
                  child: Text(controller.followLatest ? '停止跟随' : '跟随最新'),
                ),
                const SizedBox(width: 3),
                TalButton(
                  variant: TalButtonVariant.text,
                  style: _style(active: controller.plottingPaused),
                  onPressed: controller.togglePlotting,
                  child: Text(controller.plottingPaused ? '继续绘图' : '暂停绘图'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  PointerDeviceKind _lastPointerKind = PointerDeviceKind.mouse;
  bool _followLatest = true;
  bool _scrollToLatestScheduled = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleScrollToLatest() {
    if (!_followLatest || _scrollToLatestScheduled) return;
    _scrollToLatestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToLatestScheduled = false;
      // Recheck after layout so a pending update cannot override manual scrolling.
      if (!mounted || !_followLatest || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.hasContentDimensions && position.extentAfter > 0) {
        _scroll.jumpTo(position.maxScrollExtent);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification is ScrollUpdateNotification) {
      // Content growth changes metrics, but only scrolling interrupts following.
      _followLatest = notification.metrics.extentAfter <= 1;
    }
    return false;
  }

  bool _onScrollMetrics(ScrollMetricsNotification notification) {
    if (notification.depth == 0) {
      if (notification.metrics.extentAfter <= 1) _followLatest = true;
      _scheduleScrollToLatest();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller.logChanges,
      builder: (context, _) {
        if (widget.controller.logs.isEmpty) _followLatest = true;
        _scheduleScrollToLatest();
        return Padding(
          padding: const EdgeInsets.all(10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: TalColors.input,
              border: Border.all(color: TalColors.border),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerDown: (event) => _lastPointerKind = event.kind,
                    child: SelectionArea(
                      key: const ValueKey('log-selection-area'),
                      contextMenuBuilder: (context, state) =>
                          TalSelectionContextMenu(
                            anchors: state.contextMenuAnchors,
                            buttonItems: [
                              ...state.contextMenuButtonItems,
                              ContextMenuButtonItem(
                                label: 'Clear all',
                                onPressed: () {
                                  state.hideToolbar();
                                  state.clearSelection();
                                  widget.controller.clearLogs();
                                },
                              ),
                            ],
                            touchOptimized:
                                _lastPointerKind != PointerDeviceKind.mouse,
                          ),
                      child: NotificationListener<ScrollMetricsNotification>(
                        onNotification: _onScrollMetrics,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _onScroll,
                          child: SingleChildScrollView(
                            key: const ValueKey('log-scroll'),
                            controller: _scroll,
                            padding: const EdgeInsets.all(4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final entry in widget.controller.logs)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      '[${entry.timeLabel}] '
                                      '[${entry.level.name.toUpperCase()}] ${entry.message}',
                                      style: talMono.copyWith(
                                        color: switch (entry.level) {
                                          LogLevel.debug => TalColors.muted,
                                          LogLevel.warning => TalColors.amber,
                                          LogLevel.error ||
                                          LogLevel.critical => TalColors.error,
                                          LogLevel.info => TalColors.text,
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  top: 3,
                  child: TalIconButton(
                    tooltip: '清空日志',
                    onPressed: widget.controller.clearLogs,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
