import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chart.dart';
import 'chart/cartesian_renderer.dart';
import 'chart/axis_settings.dart';
import 'analysis.dart';
import 'analysis_fft.dart';
import 'controller.dart';
import 'file_pickers.dart';
import 'models.dart';
import 'panel_types.dart';
import 'theme.dart';
import 'ui_controls.dart';
import 'panels/table_layout.dart';
import 'panels/watch_color_dialog.dart';

part 'panels/panel_frame.dart';
part 'panels/control_panels.dart';
part 'panels/symbol_panel.dart';
part 'panels/watch_panel.dart';
part 'panels/connection_panel.dart';
part 'panels/plot_log_panels.dart';
part 'panels/analysis_chart_panel.dart';
part 'panels/analysis_chart_painters.dart';
part 'panels/analysis_fft_panel.dart';
part 'panels/analysis_chart_table.dart';
part 'panels/source_debug_panel.dart';
part 'panels/shared_controls.dart';

Widget buildWorkspacePanel(
  WorkspacePanelId panel,
  TakeALookController controller, {
  PanelChrome? chrome,
}) {
  return TalPanelFrame(
    panel: panel,
    chrome: chrome,
    child: buildWorkspacePanelBody(panel, controller),
  );
}

Widget buildWorkspacePanelBody(
  WorkspacePanelId panel,
  TakeALookController controller,
) {
  return switch (panel) {
    WorkspacePanelId.header => _HeaderPanel(controller: controller),
    WorkspacePanelId.runControl => _RunControlPanel(controller: controller),
    WorkspacePanelId.sampling => _SamplingPanel(controller: controller),
    WorkspacePanelId.symbols => _SymbolPanel(controller: controller),
    WorkspacePanelId.watch => _WatchPanel(controller: controller),
    WorkspacePanelId.connection => _ConnectionPanel(controller: controller),
    WorkspacePanelId.plot => _PlotPanel(controller: controller),
    WorkspacePanelId.analysis => _AnalysisChartPanel(controller: controller),
    WorkspacePanelId.sourceDebug => _SourceDebugPanel(controller: controller),
    WorkspacePanelId.log => _LogPanel(controller: controller),
  };
}
