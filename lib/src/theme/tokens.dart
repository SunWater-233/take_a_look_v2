import 'package:flutter/material.dart';

const talFontFamily = 'JetBrains Mono';
const talFontFamilyFallback = <String>['MiSans'];
const talBrandFontFamily = 'Ibrand';
const talBrandFontFamilyFallback = <String>[
  talFontFamily,
  ...talFontFamilyFallback,
];

abstract final class TalPalette {
  static const orange = Color(0xFFF44A22);
  static const midnight = Color(0xFF161616);
  static const silver = Color(0xFFFEF8E8);
  static const grey = Color(0xFFE4E2E3);
  static const stone = Color(0xFFA8AAAC);
}

abstract final class TalColors {
  static const accent = TalPalette.orange;
  static const accentHover = Color(0xFFFF603B);
  static const accentPressed = Color(0xFFE94520);
  static const onAccent = TalPalette.midnight;
  static const success = Color(0xFF6DB88A);
  static const info = Color(0xFF80ABC8);
  static const warning = Color(0xFFD7AD62);
  static const error = Color(0xFFE27878);
  static const errorContainer = Color(0xFF402626);
  static const blue = info;
  static const amber = warning;
  static const background = TalPalette.midnight;
  static const surface = Color(0xFF1E1E1E);
  static const surfaceAlt = Color(0xFF262626);
  static const input = Color(0xFF121212);
  static const hover = Color(0xFF2D2D2D);
  static const selection = Color(0xFF38231E);
  static const border = Color(0xFF3A3A3A);
  static const panelBorder = border;
  static const controlBorder = Color(0xFF555555);
  static const borderSoft = Color(0xFF2B2B2B);
  static const text = TalPalette.grey;
  static const heading = TalPalette.silver;
  static const muted = TalPalette.stone;
  static const disabled = Color(0xFF6F6F6F);
  static const gridMajor = borderSoft;
  static const gridMinor = Color(0xFF212121);
  static const shadow = Color(0xFF000000);
}

abstract final class TalChartColors {
  static const orange = TalPalette.orange;
  static const green = Color(0xFF16A36A);
  static const blue = Color(0xFF2F6FED);
  static const amber = Color(0xFFF59E0B);
  static const purple = Color(0xFFC026D3);
  static const cyan = Color(0xFF0891B2);
  static const pink = Color(0xFFDB2777);
  static const highlight = Color(0xFFFFFFFF);
  static const series = <Color>[orange, green, blue, amber, purple, cyan, pink];
  static const presets = <Color>[
    ...series,
    Color(0xFFE25858),
    Color(0xFF22C55E),
    Color(0xFF06B6D4),
    Color(0xFFEAB308),
    Color(0xFFF8FAFC),
  ];
}

abstract final class TalSyntaxColors {
  static const keyword = Color(0xFFC586C0);
  static const type = Color(0xFF4EC9B0);
  static const number = Color(0xFFB5CEA8);
  static const string = Color(0xFFCE9178);
  static const comment = Color(0xFF6A9955);
  static const preprocessor = Color(0xFFC8C8C8);
}

const talControlBorder = BorderSide(color: TalColors.controlBorder);

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
  color: TalColors.heading,
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
