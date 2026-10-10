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
import '../analysis/analysis.dart';
import '../analysis/analysis_fft.dart';
import '../analysis/analysis_worker.dart';
import '../controller/controller.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../models/models.dart';
import '../models/watch_tree.dart';
import '../workspace/panel_types.dart';
import 'source_search.dart';
import '../theme/theme.dart';
import 'table_layout.dart';
import 'watch_color_dialog.dart';

export '../theme/theme.dart' show TalDropdown;

part 'panel_frame.dart';
part 'control_panels.dart';
part 'symbol_panel.dart';
part 'watch_panel.dart';
part 'connection_panel.dart';
part 'plot_log_panels.dart';
part 'analysis_chart_panel.dart';
part 'analysis_chart_painters.dart';
part 'analysis_fft_panel.dart';
part 'analysis_chart_table.dart';
part 'source_debug_panel.dart';
part 'shared_controls.dart';

Widget buildWorkspacePanel(
  WorkspacePanelId panel,
  TakeALookController controller, {
  PanelChrome? chrome,
}) {
  return PanelKeyboardScope(
    panel: panel,
    child: TalPanelFrame(
      panel: panel,
      chrome: chrome,
      child: buildWorkspacePanelBody(panel, controller),
    ),
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
