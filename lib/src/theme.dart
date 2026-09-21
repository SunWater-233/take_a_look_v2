import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;

import 'ui_controls.dart';

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

/// Shared geometry for regular controls (buttons, fields, and selectors).
const talControlHeight = 32.0;
const talControlRadius = BorderRadius.all(Radius.circular(7));
const talControlBorder = BorderSide(color: TalColors.border);

const talContextMenuAnimationStyle = AnimationStyle(
  duration: Duration(milliseconds: 300),
  reverseDuration: Duration(milliseconds: 90),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

double? _talMenuPreviousTimeDilation;
int _talMenuAnimationLeaseCount = 0;

class TalMenuAnimationLease {
  TalMenuAnimationLease._();

  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _talMenuAnimationLeaseCount -= 1;
    if (_talMenuAnimationLeaseCount > 0) return;
    _talMenuAnimationLeaseCount = 0;
    final previous = _talMenuPreviousTimeDilation;
    _talMenuPreviousTimeDilation = null;
    if (previous != null) timeDilation = previous;
  }
}

TalMenuAnimationLease beginTalMenuAnimation() {
  if (_talMenuAnimationLeaseCount == 0) {
    _talMenuPreviousTimeDilation = timeDilation;
    final accelerated = timeDilation * 0.6;
    timeDilation = accelerated < 0.05 ? 0.05 : accelerated;
  }
  _talMenuAnimationLeaseCount += 1;
  return TalMenuAnimationLease._();
}

const talContextMenuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
  side: BorderSide(color: TalColors.border),
);

final MenuStyle talContextMenuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(TalColors.surfaceAlt),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(Colors.black),
  elevation: const WidgetStatePropertyAll(8),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
  minimumSize: const WidgetStatePropertyAll(Size(184, 0)),
  side: const WidgetStatePropertyAll(BorderSide(color: TalColors.border)),
  shape: const WidgetStatePropertyAll(talContextMenuShape),
  alignment: AlignmentDirectional.topStart,
);

final MenuStyle talContextSubmenuStyle = talContextMenuStyle.copyWith(
  alignment: AlignmentDirectional.topEnd,
);

final ButtonStyle talContextMenuButtonStyle = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(184, 32)),
  maximumSize: const WidgetStatePropertyAll(
    Size(double.infinity, talControlHeight),
  ),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 11)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  foregroundColor: const WidgetStatePropertyAll(TalColors.text),
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.hovered)
        ? TalColors.selection
        : Colors.transparent,
  ),
  shape: const WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.zero),
  ),
  textStyle: const WidgetStatePropertyAll(
    TextStyle(
      fontFamily: talFontFamily,
      fontFamilyFallback: talFontFamilyFallback,
      fontSize: 13.5,
      fontWeight: FontWeight.w400,
    ),
  ),
);

/// Local visual state shared by buttons that behave like a selected toggle.
///
/// The base shape, typography, density, and disabled state still come from
/// [outlinedButtonTheme]; this style only supplies the selected surface and
/// accent border.
final ButtonStyle talSelectedOutlinedButtonStyle = ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(TalColors.selection),
  side: const WidgetStatePropertyAll(BorderSide(color: TalColors.accent)),
);

Future<T?> showTalContextMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  bool touchOptimized = false,
}) {
  return showMenu<T>(
    context: context,
    position: position,
    items: items,
    constraints: BoxConstraints(
      minWidth: touchOptimized ? 220 : 184,
      maxWidth: touchOptimized ? 380 : 340,
    ),
    clipBehavior: Clip.antiAlias,
    popUpAnimationStyle: talContextMenuAnimationStyle,
  );
}

class TalSelectionContextMenu extends StatelessWidget {
  const TalSelectionContextMenu({
    required this.anchors,
    required this.buttonItems,
    required this.touchOptimized,
    super.key,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  final bool touchOptimized;

  @override
  Widget build(BuildContext context) {
    if (buttonItems.isEmpty) return const SizedBox.shrink();
    const screenPadding = 8.0;
    final paddingAbove = MediaQuery.paddingOf(context).top + screenPadding;
    final localAdjustment = Offset(screenPadding, paddingAbove);
    final itemHeight = touchOptimized ? 48.0 : 32.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        screenPadding,
        paddingAbove,
        screenPadding,
        screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchors.primaryAnchor - localAdjustment,
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: talContextMenuAnimationStyle.duration!,
          curve: talContextMenuAnimationStyle.curve!,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(
              scale: 0.96 + value * 0.04,
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
          child: SizedBox(
            width: touchOptimized ? 220 : 184,
            child: Material(
              color: TalColors.surfaceAlt,
              shadowColor: Colors.black,
              elevation: 8,
              shape: talContextMenuShape,
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in buttonItems)
                      SizedBox(
                        width: double.infinity,
                        height: itemHeight,
                        child: TalButton(
                          variant: TalButtonVariant.text,
                          onPressed: item.onPressed,
                          style: talContextMenuButtonStyle.copyWith(
                            minimumSize: WidgetStatePropertyAll(
                              Size(0, itemHeight),
                            ),
                            maximumSize: WidgetStatePropertyAll(
                              Size(double.infinity, itemHeight),
                            ),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              AdaptiveTextSelectionToolbar.getButtonLabel(
                                context,
                                item,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ThemeData buildTalTheme() {
  const radius = talControlRadius;
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
    menuTheme: MenuThemeData(style: talContextMenuStyle),
    popupMenuTheme: PopupMenuThemeData(
      color: TalColors.surfaceAlt,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black,
      elevation: 8,
      shape: talContextMenuShape,
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
        borderSide: talControlBorder,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: talControlBorder,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: TalColors.accent),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, talControlHeight)),
        maximumSize: const WidgetStatePropertyAll(
          Size(double.infinity, talControlHeight),
        ),
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
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, talControlHeight)),
        maximumSize: const WidgetStatePropertyAll(
          Size(double.infinity, talControlHeight),
        ),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        foregroundColor: const WidgetStatePropertyAll(TalColors.text),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered)
              ? TalColors.hover
              : Colors.transparent;
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
        minimumSize: const WidgetStatePropertyAll(Size(0, talControlHeight)),
        maximumSize: const WidgetStatePropertyAll(
          Size(double.infinity, talControlHeight),
        ),
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
