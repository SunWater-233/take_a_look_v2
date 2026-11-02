import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;

import 'controls.dart';
import 'interaction.dart';
import 'tokens.dart';

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
  shadowColor: const WidgetStatePropertyAll(TalColors.shadow),
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

Future<T?> showTalContextMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  bool? touchOptimized,
}) {
  final ui = touchOptimized == null
      ? TalUiTheme.of(context)
      : TalUiTheme.forTouch(touchOptimized);
  return showMenu<T>(
    context: context,
    position: position,
    items: items,
    shape: RoundedRectangleBorder(
      borderRadius: ui.menuRadius,
      side: talControlBorder,
    ),
    constraints: BoxConstraints(
      minWidth: ui.menuMinWidth,
      maxWidth: ui.menuMaxWidth,
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
    final ui = TalUiTheme.forTouch(touchOptimized);
    final itemHeight = ui.menuItemHeight;
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
            width: ui.menuMinWidth,
            child: Material(
              color: TalColors.surfaceAlt,
              shadowColor: TalColors.shadow,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: ui.menuRadius,
                side: talControlBorder,
              ),
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
                            visualDensity: VisualDensity.standard,
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
