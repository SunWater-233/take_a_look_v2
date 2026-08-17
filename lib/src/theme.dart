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

ThemeData buildTalTheme() {
  const radius = BorderRadius.all(Radius.circular(7));
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: talFontFamily,
    fontFamilyFallback: talFontFamilyFallback,
    scaffoldBackgroundColor: TalColors.background,
    colorScheme: const ColorScheme.dark(
      primary: TalColors.accent,
      secondary: TalColors.success,
      surface: TalColors.surface,
      error: Color(0xFFE25858),
    ),
  );

  return base.copyWith(
    splashColor: TalColors.accent.withAlpha(28),
    hoverColor: TalColors.hover,
    dividerColor: TalColors.border,
    textTheme: base.textTheme.apply(
      bodyColor: TalColors.text,
      displayColor: TalColors.text,
      fontFamily: talFontFamily,
      fontFamilyFallback: talFontFamilyFallback,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: TalColors.surfaceAlt,
        borderRadius: radius,
        border: Border.fromBorderSide(BorderSide(color: TalColors.border)),
      ),
      textStyle: TextStyle(color: TalColors.text, fontSize: 13),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: TalColors.input,
      hintStyle: TextStyle(color: TalColors.muted, fontSize: 13),
      labelStyle: TextStyle(color: TalColors.muted, fontSize: 13),
      contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: TalColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: TalColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: TalColors.accent),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 32)),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 13),
        ),
        foregroundColor: const WidgetStatePropertyAll(TalColors.text),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return TalColors.accentPressed;
          }
          return TalColors.surfaceAlt;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.hovered)
                ? TalColors.accent
                : TalColors.border,
          );
        }),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 32)),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        foregroundColor: const WidgetStatePropertyAll(TalColors.text),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? TalColors.hover
              : TalColors.surfaceAlt;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.hovered)
                ? TalColors.accent
                : TalColors.border,
          );
        }),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
        maximumSize: const WidgetStatePropertyAll(Size(32, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        foregroundColor: const WidgetStatePropertyAll(TalColors.text),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? TalColors.hover
              : Colors.transparent;
        }),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(5)),
          ),
        ),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      fillColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? TalColors.accent
            : TalColors.input;
      }),
      side: const BorderSide(color: TalColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(TalColors.surfaceAlt),
        side: WidgetStatePropertyAll(BorderSide(color: TalColors.border)),
      ),
    ),
  );
}

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
