import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals, setEquals;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart'
    show OverflowBoxFit, RenderViewport, ViewportOffset;

import 'package:flutter/services.dart';

import '../chart/inspection_anchor.dart';
import '../controller/controller.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../models/models.dart';
import '../models/watch_tree.dart';
import '../theme/theme.dart';
import 'watch_color_dialog.dart';

part 'compact_watch_panel.dart';
part 'watch_browser.dart';
part 'watch_projection.dart';
part 'watch_value_cell.dart';
part 'watch_monitor_scope.dart';

PopupMenuEntry<String> _watchPopupItem({
  required String value,
  required IconData icon,
  required String label,
  bool enabled = true,
  required bool touchOptimized,
}) => PopupMenuItem<String>(
  value: value,
  enabled: enabled,
  height: TalUiTheme.forTouch(touchOptimized).menuItemHeight,
  child: Row(
    children: [Icon(icon, size: 17), const SizedBox(width: 9), Text(label)],
  ),
);
