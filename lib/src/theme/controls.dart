import 'package:flutter/material.dart';

import 'tokens.dart';

/// Visual variants for the application's regular action button.
///
/// Keeping the variant on one wrapper makes the call site explicit while the
/// actual Material button and its shared theme remain centralized.
enum TalButtonVariant { outlined, filled, text }

/// Shared application button.
///
/// Use [outlined] for panel/tool-bar actions, [filled] for a primary dialog
/// action, and [text] for a dismissive/low-emphasis action. The wrapper keeps
/// the native Material button in the widget tree so keyboard, semantics, and
/// theme behavior continue to work as expected.
class TalButton extends StatelessWidget {
  const TalButton({
    required this.child,
    required this.onPressed,
    this.icon,
    this.label,
    this.variant = TalButtonVariant.outlined,
    this.style,
    super.key,
  });

  const TalButton.icon({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.variant = TalButtonVariant.outlined,
    this.style,
    super.key,
  }) : child = null;

  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final VoidCallback? onPressed;
  final TalButtonVariant variant;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    final directChild = child;
    if (directChild == null) {
      return switch (variant) {
        TalButtonVariant.outlined => OutlinedButton.icon(
          onPressed: onPressed,
          style: style,
          icon: icon!,
          label: label!,
        ),
        TalButtonVariant.filled => FilledButton.icon(
          onPressed: onPressed,
          style: style,
          icon: icon!,
          label: label!,
        ),
        TalButtonVariant.text => TextButton.icon(
          onPressed: onPressed,
          style: style,
          icon: icon!,
          label: label!,
        ),
      };
    }
    return switch (variant) {
      TalButtonVariant.outlined => OutlinedButton(
        onPressed: onPressed,
        style: style,
        child: directChild,
      ),
      TalButtonVariant.filled => FilledButton(
        onPressed: onPressed,
        style: style,
        child: directChild,
      ),
      TalButtonVariant.text => TextButton(
        onPressed: onPressed,
        style: style,
        child: directChild,
      ),
    };
  }
}

/// Shared icon-only action button used by panel chrome and compact toolbars.
class TalIconButton extends StatelessWidget {
  const TalIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.style,
    super.key,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: style,
      icon: icon,
    );
  }
}

/// Shared text-triggered popup menu button.
///
/// Flutter's [PopupMenuButton] is still used for menu semantics and keyboard
/// behavior, but its trigger is rendered through [TalButton] so popup actions
/// do not introduce a one-off button surface in an otherwise unified toolbar.
class TalPopupMenuButton<T> extends StatelessWidget {
  const TalPopupMenuButton({
    required this.itemBuilder,
    required this.child,
    this.onSelected,
    this.tooltip,
    this.enabled = true,
    super.key,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final String? tooltip;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      tooltip: tooltip,
      enabled: enabled,
      child: TalButton(
        onPressed: null,
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(
            enabled ? TalColors.text : TalColors.disabled,
          ),
          side: WidgetStatePropertyAll(
            BorderSide(
              color: enabled ? TalColors.controlBorder : TalColors.borderSoft,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}
