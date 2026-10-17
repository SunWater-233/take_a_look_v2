import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';

import '../chart/chart.dart';
import '../chart/cartesian_renderer.dart';
import '../chart/axis_settings.dart';
import '../chart/inspection_anchor.dart';
import '../analysis/analysis.dart';
import '../analysis/analysis_fft.dart';
import '../analysis/analysis_worker.dart';
import '../controller/controller.dart';
import '../app/file_pickers.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../models/models.dart';
import '../models/watch_tree.dart';
import '../workspace/panel_types.dart';
import 'source_search.dart';
import 'source_highlighter.dart';
import 'source_documents.dart';
import '../theme/theme.dart';
import 'table_layout.dart';
import 'watch_color_dialog.dart';
import 'target_chip_dialog.dart';

export '../theme/theme.dart' show TalDropdown;

part 'panel_frame.dart';
part 'control_panels.dart';
part 'symbol_panel.dart';
part 'watch_panel.dart';
part 'compact_watch_panel.dart';
part 'workbench_output.dart';
part 'connection_panel.dart';
part 'plot_log_panels.dart';
part 'analysis_chart_panel.dart';
part 'analysis_chart_painters.dart';
part 'analysis_fft_panel.dart';
part 'analysis_chart_table.dart';
part 'source_debug_panel.dart';
part 'source_build_tools.dart';
part 'source_tab_attention.dart';
part 'shared_controls.dart';

Widget buildWorkspacePanel(
  WorkspacePanelId panel,
  TakeALookController controller, {
  PanelChrome? chrome,
  bool sourcePreview = false,
  bool workbench = false,
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
    WorkspacePanelId.header => _HeaderPanel(controller: controller),
    WorkspacePanelId.runControl => _RunControlPanel(controller: controller),
    WorkspacePanelId.sampling => _SamplingPanel(controller: controller),
    WorkspacePanelId.symbols => _SymbolPanel(
      controller: controller,
      defaultMonitor: workbench,
    ),
    WorkspacePanelId.watch =>
      workbench
          ? LayoutBuilder(
              builder: (context, constraints) =>
                  adaptiveWorkbench && constraints.maxWidth >= 640
                  ? _WatchPanel(controller: controller)
                  : _CompactWatchPanel(
                      controller: controller,
                      onShowSymbols: onShowSymbols,
                    ),
            )
          : _WatchPanel(controller: controller),
    WorkspacePanelId.connection => _ConnectionPanel(controller: controller),
    WorkspacePanelId.plot => _PlotPanel(controller: controller),
    WorkspacePanelId.analysis => LayoutBuilder(
      builder: (context, constraints) => _AnalysisChartPanel(
        controller: controller,
        horizontal:
            workbench && (!adaptiveWorkbench || constraints.maxWidth >= 680),
      ),
    ),
    WorkspacePanelId.sourceDebug => _SourceDebugPanel(
      controller: controller,
      readOnlyPreview: sourcePreview,
      externalOutput: workbench,
      visible: visible,
    ),
    WorkspacePanelId.log => _LogPanel(controller: controller),
    WorkspacePanelId.buildOutput => _BuildOutputPanel(
      controller: controller,
      onShowSource: onShowSource,
    ),
    WorkspacePanelId.registers => _RegistersPanel(controller: controller),
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
      height: math.min(530, MediaQuery.sizeOf(context).height * .65),
      child: _ConnectionPanel(controller: controller),
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
          Expanded(child: _SamplingPanel(controller: controller)),
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
  builder: (_) => _SourceProjectDialog(controller: controller),
);
