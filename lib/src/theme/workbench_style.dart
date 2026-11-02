import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class WorkbenchColors {
  static const background = TalColors.background;
  static const surface = TalColors.surface;
  static const raised = TalColors.surfaceAlt;
  static const input = TalColors.input;
  static const border = TalColors.border;
  static const text = TalColors.text;
  static const heading = TalColors.heading;
  static const muted = TalColors.muted;
  static const selection = TalColors.selection;
  static const accent = TalColors.accent;
  static const success = TalColors.success;
}

const workbenchBody = TextStyle(
  fontFamily: 'MiSans',
  fontSize: 13,
  color: WorkbenchColors.text,
);
const workbenchMuted = TextStyle(
  fontFamily: 'MiSans',
  fontSize: 12,
  color: WorkbenchColors.muted,
);

String formatReadRate(double value) => value >= 1000
    ? '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)} kHz'
    : '${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)} Hz';
