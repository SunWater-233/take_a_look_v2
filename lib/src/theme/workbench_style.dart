import 'package:flutter/material.dart';

/// Workbench chrome is scoped separately from the existing project dialogs.
abstract final class WorkbenchColors {
  static const background = Color(0xFF0F1114);
  static const surface = Color(0xFF191C20);
  static const raised = Color(0xFF24282E);
  static const input = Color(0xFF111419);
  static const border = Color(0xFF373E47);
  static const text = Color(0xFFE8ECF1);
  static const muted = Color(0xFFA5AEBC);
  static const selection = Color(0xFF31251F);
  static const accent = Color(0xFFF44A22);
  static const success = Color(0xFF5DC59A);
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
