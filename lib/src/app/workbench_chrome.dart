import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../panels/panels.dart';
import '../theme/theme.dart';
import '../workspace/workspace.dart';

/// The fixed application controls stay available while panels are rearranged.
class WorkbenchToolbar extends StatelessWidget {
  const WorkbenchToolbar({required this.controller, super.key});
  final TakeALookController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.connectionChanges,
      controller.samplingChanges,
      controller.debugChanges,
    ]),
    builder: (context, _) {
      final connected =
          controller.connectionStatus == ConnectionStatus.connected;
      final halted =
          controller.debugState.executionState == DebugExecutionState.halted;
      final connectionName = switch (controller.connectionKind) {
        'emberGdb' => 'GDB',
        'ember' => 'EmberMobile',
        _ => controller.probeType.replaceAll('自动发现任意探针', '探针'),
      };
      final connectionStatus = connected
          ? '已连接'
          : controller.connectionStatus == ConnectionStatus.connecting
          ? '连接中'
          : '未连接';
      return Container(
        height: TalUiTheme.of(context).controlHeight + 20,
        decoration: const BoxDecoration(
          color: WorkbenchColors.surface,
          border: Border(bottom: BorderSide(color: WorkbenchColors.border)),
        ),
        child: LayoutBuilder(
          builder: (context, bounds) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: bounds.maxWidth - 24),
              child: IntrinsicWidth(
                child: Row(
                  children: [
                    TalButton.icon(
                      key: const ValueKey('workbench-connection'),
                      onPressed: () =>
                          showWorkbenchConnectionSettings(context, controller),
                      icon: Icon(
                        Icons.circle,
                        size: 7,
                        color: connected
                            ? WorkbenchColors.success
                            : WorkbenchColors.muted,
                      ),
                      label: Text('$connectionName  $connectionStatus  ▾'),
                    ),
                    const SizedBox(width: 14),
                    TalButton.icon(
                      key: const ValueKey('workbench-target'),
                      onPressed: connected
                          ? (halted
                                ? controller.resumeTarget
                                : controller.haltTarget)
                          : null,
                      icon: Icon(
                        halted ? Icons.play_arrow_outlined : Icons.pause,
                        size: 17,
                      ),
                      label: Text(halted ? '继续目标' : '暂停目标'),
                    ),
                    const SizedBox(width: 8),
                    TalButton.icon(
                      key: const ValueKey('workbench-disconnect'),
                      onPressed: connected ? controller.toggleConnection : null,
                      icon: const Icon(Icons.link_off, size: 17),
                      label: const Text('断开连接'),
                    ),
                    const SizedBox(width: 8),
                    TalPopupMenuButton<bool>(
                      tooltip: '复位目标',
                      onSelected: (halt) {
                        if (connected) controller.resetTarget(halt: halt);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: false,
                          enabled: connected,
                          child: const Text('复位运行'),
                        ),
                        PopupMenuItem(
                          value: true,
                          enabled: connected,
                          child: const Text('复位暂停'),
                        ),
                      ],
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.restart_alt, size: 18),
                          SizedBox(width: 5),
                          Text('复位'),
                          Icon(Icons.expand_more, size: 16),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    const SizedBox(
                      height: 24,
                      child: VerticalDivider(color: WorkbenchColors.border),
                    ),
                    const SizedBox(width: 12),
                    const Text('采集', style: workbenchBody),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 112,
                      child: TalDropdown<double>(
                        value: controller.sampleRateHz,
                        values: {
                          ...[
                            50.0,
                            100.0,
                            200.0,
                            500.0,
                            1000.0,
                            2000.0,
                            5000.0,
                            7000.0,
                          ],
                          controller.sampleRateHz,
                        }.toList()..sort(),
                        label: formatReadRate,
                        onChanged: controller.setSampleRate,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TalButton.icon(
                      key: const ValueKey('workbench-capture-toggle'),
                      variant: TalButtonVariant.filled,
                      onPressed: controller.toggleSampling,
                      icon: Icon(
                        controller.samplingPaused
                            ? Icons.play_arrow_outlined
                            : Icons.pause,
                        size: 17,
                      ),
                      label: Text(controller.samplingPaused ? '继续采集' : '暂停采集'),
                    ),
                    const SizedBox(width: 8),
                    TalButton(
                      key: const ValueKey('workbench-clear-samples'),
                      onPressed: controller.clearSamples,
                      child: const Text('清空采样'),
                    ),
                    const SizedBox(width: 10),
                    TalButton(
                      onPressed: () =>
                          showWorkbenchSamplingSettings(context, controller),
                      child: const Text('RTT设置'),
                    ),
                    const SizedBox(width: 18),
                    const Spacer(),
                    AnimatedBuilder(
                      animation: controller.clockChanges,
                      builder: (_, _) => Text(
                        _elapsed(controller.samplingElapsedSeconds),
                        style: talMono.copyWith(color: WorkbenchColors.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  static String _elapsed(double seconds) {
    final ms = (seconds * 1000).round();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}.${(ms % 1000).toString().padLeft(3, '0')}';
  }
}

class WorkbenchStatusBar extends StatelessWidget {
  const WorkbenchStatusBar({
    required this.controller,
    required this.workspaceKey,
    super.key,
  });
  final TakeALookController controller;
  final GlobalKey<DockingWorkspaceState> workspaceKey;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.connectionChanges,
      controller.samplingChanges,
      controller.watchChanges,
      controller.debugChanges,
    ]),
    builder: (context, _) {
      final connected =
          controller.connectionStatus == ConnectionStatus.connected;
      final captures = controller.watches
          .where((watch) => watch.samplingEnabled)
          .length;
      final monitoring = controller.watches.any(
        (watch) => watch.readMode == WatchReadMode.monitor,
      );
      return MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          key: const ValueKey('workbench-output-drag'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: (_) =>
              workspaceKey.currentState?.startOutputDrag(),
          onVerticalDragUpdate: (details) =>
              workspaceKey.currentState?.updateOutputDrag(details.delta.dy),
          onVerticalDragEnd: (_) => workspaceKey.currentState?.endOutputDrag(),
          onVerticalDragCancel: () =>
              workspaceKey.currentState?.endOutputDrag(),
          child: Container(
            height: TalUiTheme.of(context).targetExtent(30),
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: const BoxDecoration(
              color: WorkbenchColors.background,
              border: Border(top: BorderSide(color: WorkbenchColors.border)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: connected
                      ? WorkbenchColors.success
                      : WorkbenchColors.muted,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    connected
                        ? '${controller.samplingPaused ? '采集暂停' : '采集中'}    ${monitoring ? '监视刷新中    ' : ''}${controller.debugState.executionState == DebugExecutionState.halted ? '目标暂停' : '目标运行'}    $captures 路采集'
                        : '未连接目标',
                    style: workbenchMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('workbench-output-toggle'),
                  onPressed: () => unawaited(
                    workspaceKey.currentState?.toggleWorkbenchOutput() ??
                        Future.value(),
                  ),
                  icon: Icon(
                    workspaceKey.currentState?.outputDocked == true
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: 16,
                  ),
                  label: const Text('输出'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
