import 'package:flutter/material.dart';

const talFontFamily = 'JetBrains Mono';
const talFontFamilyFallback = <String>['MiSans'];
const talBrandFontFamily = 'Ibrand';
const talBrandFontFamilyFallback = <String>[
  talFontFamily,
  ...talFontFamilyFallback,
];

abstract final class TalColors {
  static const accent = Color(0xFFF44A22);
  static const accentPressed = Color(0xFFD83F1D);
  static const success = Color(0xFF16A36A);
  static const blue = Color(0xFF2F6FED);
  static const amber = Color(0xFFF59E0B);
  static const background = Color(0xFF050505);
  static const surface = Color(0xFF0B0B0B);
  static const surfaceAlt = Color(0xFF171717);
  static const input = Color(0xFF030303);
  static const hover = Color(0xFF231E20);
  static const selection = Color(0xFF3E3A3C);
  static const border = Color(0xFF494446);
  static const panelBorder = Color(0xFF696164);
  static const borderSoft = Color(0xFF2D292B);
  static const text = Color(0xFFE4E2E3);
  static const muted = Color(0xFFB7B0B3);
  static const gridMajor = Color(0x33494446);
  static const gridMinor = Color(0x19494446);
}

const talControlBorder = BorderSide(color: TalColors.border);

/// Panel tabs paint over this baseline so the active tab joins its content.
const talPanelTabStripDecoration = BoxDecoration(
  color: TalColors.surface,
  border: Border(bottom: talControlBorder),
);

const talBody = TextStyle(
  color: TalColors.text,
  fontSize: 13,
  fontFamily: talFontFamily,
  fontFamilyFallback: talFontFamilyFallback,
  letterSpacing: 0,
);

const talMuted = TextStyle(
  color: TalColors.muted,
  fontSize: 12,
  fontFamily: talFontFamily,
  fontFamilyFallback: talFontFamilyFallback,
  letterSpacing: 0,
);

const talStrong = TextStyle(
  color: TalColors.text,
  fontSize: 13,
  fontWeight: FontWeight.w700,
  fontFamily: talFontFamily,
  fontFamilyFallback: talFontFamilyFallback,
  letterSpacing: 0,
);

const talMono = TextStyle(
  color: TalColors.text,
  fontSize: 12,
  fontFamily: talFontFamily,
  fontFamilyFallback: talFontFamilyFallback,
  letterSpacing: 0,
);
