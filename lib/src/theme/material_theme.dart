import 'package:flutter/material.dart';

import 'interaction.dart';
import 'menus.dart';
import 'tokens.dart';

/// Local visual state shared by buttons that behave like a selected toggle.
///
/// The base shape, typography, density, and disabled state still come from
/// [ThemeData.outlinedButtonTheme]; this style only supplies the selected surface and
/// accent border.
final ButtonStyle talSelectedOutlinedButtonStyle = ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(TalColors.selection),
  side: const WidgetStatePropertyAll(BorderSide(color: TalColors.accent)),
);

ThemeData buildTalTheme({TalInputMode inputMode = TalInputMode.mouseKeyboard}) {
  final ui = TalUiTheme(inputMode: inputMode);
  final radius = ui.controlRadius;
  final controlSize = WidgetStatePropertyAll(Size(0, ui.controlHeight));
  final controlMaximumSize = WidgetStatePropertyAll(
    Size(double.infinity, ui.controlHeight),
  );
  final menuShape = RoundedRectangleBorder(
    borderRadius: ui.menuRadius,
    side: talControlBorder,
  );
  final menuStyle = talContextMenuStyle.copyWith(
    minimumSize: WidgetStatePropertyAll(Size(ui.menuMinWidth, 0)),
    shape: WidgetStatePropertyAll(menuShape),
  );
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
    extensions: [ui],
    splashColor: TalColors.accent.withAlpha(28),
    hoverColor: TalColors.hover,
    dividerColor: TalColors.border,
    menuTheme: MenuThemeData(style: menuStyle),
    menuButtonTheme: MenuButtonThemeData(
      style: talContextMenuButtonStyle.copyWith(
        minimumSize: WidgetStatePropertyAll(
          Size(ui.menuMinWidth, ui.menuItemHeight),
        ),
        maximumSize: WidgetStatePropertyAll(
          Size(double.infinity, ui.menuItemHeight),
        ),
        visualDensity: VisualDensity.standard,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: TalColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: ui.dialogRadius,
        side: ui.touchOptimized ? BorderSide.none : talControlBorder,
      ),
      constraints: BoxConstraints(maxWidth: ui.dialogMaxWidth),
      titleTextStyle: TextStyle(
        color: TalColors.text,
        fontFamily: talFontFamily,
        fontFamilyFallback: talFontFamilyFallback,
        fontSize: ui.touchOptimized ? 24 : 18,
      ),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: TalColors.text,
        fontSize: ui.touchOptimized ? 16 : 13,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: TalColors.surfaceAlt,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black,
      elevation: 8,
      shape: menuShape,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      textStyle: const TextStyle(
        color: TalColors.text,
        fontFamily: talFontFamily,
        fontFamilyFallback: talFontFamilyFallback,
        fontSize: 13.5,
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.disabled)
              ? TalColors.muted
              : TalColors.text,
          fontFamily: talFontFamily,
          fontFamilyFallback: talFontFamilyFallback,
          fontSize: 13.5,
        ),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: TalColors.text,
      displayColor: TalColors.text,
      fontFamily: talFontFamily,
      fontFamilyFallback: talFontFamilyFallback,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: TalColors.surfaceAlt,
        borderRadius: radius,
        border: const Border.fromBorderSide(talControlBorder),
      ),
      textStyle: const TextStyle(color: TalColors.text, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: !ui.touchOptimized,
      filled: true,
      fillColor: TalColors.input,
      hintStyle: const TextStyle(color: TalColors.muted, fontSize: 13),
      labelStyle: const TextStyle(color: TalColors.muted, fontSize: 13),
      contentPadding: ui.fieldPadding,
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: talControlBorder,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: talControlBorder,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: TalColors.accent),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: controlSize,
        maximumSize: controlMaximumSize,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
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
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: const WidgetStatePropertyAll(talStrong),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: controlSize,
        maximumSize: controlMaximumSize,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
        ),
        foregroundColor: const WidgetStatePropertyAll(TalColors.text),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? TalColors.hover
              : Colors.transparent;
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: const WidgetStatePropertyAll(talStrong),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: controlSize,
        maximumSize: controlMaximumSize,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
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
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: const WidgetStatePropertyAll(talStrong),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.square(ui.iconButtonSize)),
        maximumSize: WidgetStatePropertyAll(Size.square(ui.iconButtonSize)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
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
      materialTapTargetSize: ui.touchOptimized
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      visualDensity: ui.touchOptimized
          ? VisualDensity.standard
          : VisualDensity.compact,
      fillColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? TalColors.accent
            : TalColors.input;
      }),
      side: const BorderSide(color: TalColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuStyle),
  );
}
