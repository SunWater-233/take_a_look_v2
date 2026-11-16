import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../models/models.dart';
import '../workspace/panel_types.dart';
import '../theme/theme.dart';

import 'panel_frame.dart';
import 'control_panels.dart';
import 'connection_panel.dart';
import 'symbol_panel.dart';
import 'watch_panel.dart';
import 'plot_log_panels.dart';
import 'analysis_chart_panel.dart';
import 'source_debug_panel.dart';
import 'freertos_panel.dart';

export '../theme/theme.dart' show TalDropdown;
export 'panel_frame.dart';

Widget buildWorkspacePanel(
  WorkspacePanelId panel,
  TakeALookController controller, {
  PanelChrome? chrome,
  bool sourcePreview = false,
  bool workbench = false,
  bool visible = true,
  Widget? body,
  VoidCallback? onShowSource,
  VoidCallback? onShowSymbols,
}) {
  return PanelKeyboardScope(
    panel: panel,
    child: TalPanelFrame(
      panel: panel,
      chrome: chrome,
      controller: controller,
      compact: workbench,
      child:
          body ??
          buildWorkspacePanelBody(
            panel,
            controller,
            sourcePreview: sourcePreview,
            workbench: workbench,
            visible: visible,
            onShowSource: onShowSource,
            onShowSymbols: onShowSymbols,
          ),
    ),
  );
}

Widget buildWorkspacePanelBody(
  WorkspacePanelId panel,
  TakeALookController controller, {
  bool sourcePreview = false,
  bool workbench = false,
  bool visible = true,
  bool adaptiveWorkbench = false,
  VoidCallback? onShowSource,
  VoidCallback? onShowSymbols,
}) {
  return switch (panel) {
    WorkspacePanelId.header => HeaderPanel(controller: controller),
    WorkspacePanelId.runControl => RunControlPanel(controller: controller),
    WorkspacePanelId.sampling => SamplingPanel(controller: controller),
    WorkspacePanelId.symbols => SymbolPanel(
      controller: controller,
      defaultMonitor: workbench,
      onShowSource: onShowSource,
    ),
    WorkspacePanelId.watch =>
      workbench
          ? CompactWatchPanel(
              controller: controller,
              onShowSymbols: onShowSymbols,
              visible: visible,
            )
          : WatchPanel(controller: controller, visible: visible),
    WorkspacePanelId.connection => ConnectionPanel(controller: controller),
    WorkspacePanelId.plot => PlotPanel(controller: controller),
    WorkspacePanelId.analysis => LayoutBuilder(
      builder: (context, constraints) => AnalysisChartPanel(
        controller: controller,
        horizontal:
            workbench && (!adaptiveWorkbench || constraints.maxWidth >= 680),
      ),
    ),
    WorkspacePanelId.sourceDebug => SourceDebugPanel(
      controller: controller,
      readOnlyPreview: sourcePreview,
      externalOutput: workbench,
      visible: visible,
    ),
    WorkspacePanelId.log => LogPanel(controller: controller),
    WorkspacePanelId.buildOutput => BuildOutputPanel(
      controller: controller,
      onShowSource: onShowSource,
    ),
    WorkspacePanelId.registers => RegistersPanel(controller: controller),
    WorkspacePanelId.freeRtos => FreeRtosPanel(
      controller: controller,
      visible: visible,
      onShowSource: onShowSource,
    ),
  };
}

Future<void> showWorkbenchConnectionSettings(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('连接设置'),
    content: SizedBox(
      width: 490,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(530, MediaQuery.sizeOf(context).height * .65),
        ),
        child: ConnectionPanel(controller: controller),
      ),
    ),
    actions: [
      AnimatedBuilder(
        animation: controller.connectionChanges,
        builder: (_, _) => TalButton(
          variant: TalButtonVariant.filled,
          onPressed: controller.connectionStatus == ConnectionStatus.connecting
              ? null
              : controller.toggleConnection,
          child: Text(controller.connectionLabel),
        ),
      ),
      TalButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);

Future<void> showWorkbenchSamplingSettings(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('采集设置'),
    content: SizedBox(
      width: 430,
      height: 300,
      child: Column(
        children: [
          Expanded(child: SamplingPanel(controller: controller)),
          const Divider(height: 1),
          AnimatedBuilder(
            animation: controller.samplingChanges,
            builder: (context, _) => Row(
              children: [
                Checkbox(
                  value: controller.rttEnabled,
                  onChanged: (value) => controller.toggleRtt(value ?? false),
                ),
                const Text('RTT 采集'),
                const Spacer(),
                SizedBox(
                  width: 160,
                  child: TalDropdown<String>(
                    value: controller.rttProtocol,
                    values: const ['normal', 'plus'],
                    label: (value) =>
                        value == 'plus' ? 'RTT-Plus' : 'RTT-Normal',
                    onChanged: controller.setRttProtocol,
                  ),
                ),
              ],
            ),
          ),
        ],
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

Future<void> showWorkbenchProjectSettings(
  BuildContext context,
  TakeALookController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => SourceProjectDialog(controller: controller),
);
