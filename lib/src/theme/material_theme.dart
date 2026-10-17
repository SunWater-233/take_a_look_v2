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

/// Feedback for actions with a successfully configured file or directory.
final ButtonStyle talSuccessOutlinedButtonStyle = ButtonStyle(
  foregroundColor: const WidgetStatePropertyAll(TalColors.success),
  backgroundColor: WidgetStatePropertyAll(
    TalColors.success.withValues(alpha: 0.12),
  ),
  overlayColor: WidgetStatePropertyAll(
    TalColors.success.withValues(alpha: 0.12),
  ),
  side: const WidgetStatePropertyAll(BorderSide(color: TalColors.success)),
);

ButtonStyle talCaptionButtonStyle(TalUiTheme ui, {required bool close}) {
  final size = Size(ui.touchOptimized ? 48 : 44, ui.titleButtonHeight);
  bool highlighted(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) ||
      states.contains(WidgetState.focused) ||
      states.contains(WidgetState.pressed);

  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(size),
    maximumSize: WidgetStatePropertyAll(size),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          close && highlighted(states) ? TalColors.onAccent : TalColors.text,
    ),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (!highlighted(states)) {
        return Colors.transparent;
      }
      if (!close) {
        return TalColors.hover;
      }
      return states.contains(WidgetState.pressed)
          ? TalColors.accentPressed
          : TalColors.accent;
    }),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: ui.controlRadius),
    ),
  );
}

ThemeData buildTalTheme({TalInputMode inputMode = TalInputMode.mouseKeyboard}) {
  final ui = TalUiTheme(inputMode: inputMode);
  final radius = ui.controlRadius;
  final buttonTextStyle = WidgetStatePropertyAll(
    talBody.copyWith(fontWeight: FontWeight.w400),
  );
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
      onPrimary: TalColors.onAccent,
      primaryContainer: TalColors.selection,
      onPrimaryContainer: TalColors.text,
      secondary: TalColors.muted,
      onSecondary: TalColors.background,
      secondaryContainer: TalColors.surfaceAlt,
      onSecondaryContainer: TalColors.text,
      tertiary: TalColors.info,
      onTertiary: TalColors.background,
      tertiaryContainer: TalColors.surfaceAlt,
      onTertiaryContainer: TalColors.text,
      surface: TalColors.surface,
      onSurface: TalColors.text,
      onSurfaceVariant: TalColors.muted,
      surfaceDim: TalColors.background,
      surfaceBright: TalColors.hover,
      surfaceContainerLowest: TalColors.input,
      surfaceContainerLow: TalColors.background,
      surfaceContainer: TalColors.surface,
      surfaceContainerHigh: TalColors.surfaceAlt,
      surfaceContainerHighest: TalColors.hover,
      surfaceTint: Colors.transparent,
      outline: TalColors.controlBorder,
      outlineVariant: TalColors.borderSoft,
      error: TalColors.error,
      onError: TalColors.background,
      errorContainer: TalColors.errorContainer,
      onErrorContainer: TalColors.text,
      inverseSurface: TalColors.text,
      onInverseSurface: TalColors.background,
      inversePrimary: TalColors.accentPressed,
      shadow: TalColors.shadow,
      scrim: TalColors.shadow,
    ),
  );

  return base.copyWith(
    extensions: [ui],
    splashColor: TalColors.accent.withAlpha(28),
    hoverColor: TalColors.hover,
    disabledColor: TalColors.disabled,
    dividerColor: TalColors.border,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: TalColors.accent,
      selectionColor: TalColors.accent.withValues(alpha: 0.25),
      selectionHandleColor: TalColors.accent,
    ),
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
        color: TalColors.heading,
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
      shadowColor: TalColors.shadow,
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
      displayColor: TalColors.heading,
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
      textStyle: const TextStyle(
        color: TalColors.text,
        fontSize: 13,
        fontFamily: talFontFamily,
        fontFamilyFallback: talFontFamilyFallback,
      ),
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
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? TalColors.disabled
              : TalColors.onAccent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return TalColors.surfaceAlt;
          }
          if (states.contains(WidgetState.pressed)) {
            return TalColors.accentPressed;
          }
          if (states.contains(WidgetState.hovered)) {
            return TalColors.accentHover;
          }
          return TalColors.accent;
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: buttonTextStyle,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: controlSize,
        maximumSize: controlMaximumSize,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? TalColors.disabled
              : TalColors.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return Colors.transparent;
          }
          return states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.pressed)
              ? TalColors.hover
              : Colors.transparent;
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: buttonTextStyle,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: controlSize,
        maximumSize: controlMaximumSize,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: ui.controlHorizontalPadding),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? TalColors.disabled
              : TalColors.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return TalColors.surfaceAlt;
          }
          return states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.pressed)
              ? TalColors.hover
              : TalColors.surfaceAlt;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return const BorderSide(color: TalColors.borderSoft);
          }
          return BorderSide(
            color: states.contains(WidgetState.focused)
                ? TalColors.accent
                : states.contains(WidgetState.hovered)
                ? TalColors.muted
                : TalColors.controlBorder,
          );
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
        textStyle: buttonTextStyle,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: WidgetStatePropertyAll(Size.square(ui.iconButtonSize)),
        maximumSize: WidgetStatePropertyAll(Size.square(ui.iconButtonSize)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? TalColors.disabled
              : TalColors.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return Colors.transparent;
          }
          return states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.pressed)
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
        if (states.contains(WidgetState.disabled)) {
          return TalColors.surfaceAlt;
        }
        return states.contains(WidgetState.selected)
            ? TalColors.accent
            : TalColors.input;
      }),
      checkColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? TalColors.disabled
            : TalColors.onAccent,
      ),
      side: talControlBorder,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuStyle),
  );
}
