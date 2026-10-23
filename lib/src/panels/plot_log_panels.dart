import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../chart/chart.dart';
import '../controller/controller.dart';
import '../models/models.dart';
import '../theme/theme.dart';

class PlotPanel extends StatelessWidget {
  const PlotPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            controller.watchChanges,
            controller.samplingChanges,
            controller.plotControlChanges,
          ]),
          builder: (context, _) => Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: TalColors.surface,
              border: Border(bottom: BorderSide(color: TalColors.border)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(606, constraints.maxWidth),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.watches.isEmpty
                              ? '从符号列表加入变量并勾选绘制后显示曲线'
                              : '${controller.watches.where((item) => item.plotted).length} 条曲线 · ${controller.sampleRateLabel}',
                          style: talMuted,
                        ),
                      ),
                      TalButton(
                        onPressed: controller.togglePlotting,
                        child: Text(
                          controller.plottingPaused ? '继续绘图' : '暂停绘图',
                        ),
                      ),
                      const SizedBox(width: 8),
                      TalButton(
                        onPressed: controller.toggleFollowLatest,
                        child: Text(controller.followLatest ? '停止跟随' : '跟随最新'),
                      ),
                      const SizedBox(width: 8),
                      TalButton(
                        onPressed: controller.exportCsv,
                        child: const Text('导出原始CSV'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: TelemetryChart(controller: controller)),
      ],
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
