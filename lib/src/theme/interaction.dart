import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum TalInputMode { mouseKeyboard, touch }

/// Interaction geometry and presentation policy shared by every UI control.
/// Colors and Material component styles are applied by buildTalTheme.
@immutable
class TalUiTheme extends ThemeExtension<TalUiTheme> {
  const TalUiTheme({this.inputMode = TalInputMode.mouseKeyboard});

  final TalInputMode inputMode;

  static TalUiTheme of(BuildContext context) =>
      Theme.of(context).extension<TalUiTheme>() ?? const TalUiTheme();

  static TalUiTheme forTouch(bool touch) => TalUiTheme(
    inputMode: touch ? TalInputMode.touch : TalInputMode.mouseKeyboard,
  );

  bool get touchOptimized => inputMode == TalInputMode.touch;
  double targetExtent(double compactExtent) =>
      touchOptimized && compactExtent < controlHeight
      ? controlHeight
      : compactExtent;
  double get controlHeight => touchOptimized ? 48 : 32;
  double get iconButtonSize => touchOptimized ? 48 : 32;
  double get compactIconButtonSize => touchOptimized ? 48 : 22;
  double get menuItemHeight => controlHeight;
  double get menuMinWidth => touchOptimized ? 220 : 184;
  double get menuMaxWidth => touchOptimized ? 380 : 340;
  double get panelHeaderHeight => touchOptimized ? 48 : 34;
  double get panelTabHeight => touchOptimized ? 48 : 29;
  double get panelTabStripHeight => panelTabHeight + 1;
  double get titleBarHeight => touchOptimized ? 56 : 46;
  double get titleButtonHeight => touchOptimized ? 48 : 34;
  double get dialogMaxWidth => touchOptimized ? 560 : 480;
  double get progressDialogWidth => touchOptimized ? 560 : 440;
  double get progressIndicatorHeight => touchOptimized ? 8 : 6;
  double get notificationWidth => 420;
  double get notificationMaxHeight => 340;
  double get overlayMargin => 16;
  double get controlHorizontalPadding => touchOptimized ? 14 : 12;
  BorderRadius get controlRadius =>
      BorderRadius.circular(touchOptimized ? 10 : 7);
  BorderRadius get menuRadius => BorderRadius.circular(touchOptimized ? 12 : 8);
  BorderRadius get dialogRadius =>
      BorderRadius.circular(touchOptimized ? 28 : 8);
  EdgeInsets get dialogInsetPadding =>
      EdgeInsets.symmetric(horizontal: touchOptimized ? 24 : 40, vertical: 24);
  EdgeInsets get dialogPadding => EdgeInsets.all(touchOptimized ? 24 : 20);
  EdgeInsets get fieldPadding => EdgeInsets.symmetric(
    horizontal: touchOptimized ? 12 : 9,
    vertical: touchOptimized ? 15 : 9,
  );

  @override
  TalUiTheme copyWith({TalInputMode? inputMode}) =>
      TalUiTheme(inputMode: inputMode ?? this.inputMode);

  @override
  TalUiTheme lerp(covariant TalUiTheme? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// Tracks actual input, including on hybrid laptops. Window width is not an
/// input-device signal. Merely entering a mouse region after a rebuild does
/// not switch a touch user back to the compact layout.
class TalInteractionRegion extends StatefulWidget {
  const TalInteractionRegion({
    required this.builder,
    this.initialMode,
    super.key,
  });

  final Widget Function(BuildContext context, TalInputMode mode) builder;
  final TalInputMode? initialMode;

  @override
  State<TalInteractionRegion> createState() => _TalInteractionRegionState();
}

class _TalInteractionRegionState extends State<TalInteractionRegion> {
  late TalInputMode _mode;
  TalInputMode? _pendingMode;
  final Set<int> _activePointers = {};

  @override
  void initState() {
    super.initState();
    _mode =
        widget.initialMode ??
        switch (defaultTargetPlatform) {
          TargetPlatform.android || TargetPlatform.iOS => TalInputMode.touch,
          _ => TalInputMode.mouseKeyboard,
        };
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  void _setMode(TalInputMode mode) {
    if (_activePointers.isNotEmpty) {
      _pendingMode = mode;
      return;
    }
    if (_mode != mode) setState(() => _mode = mode);
  }

  void _finishPointer(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty && _pendingMode != null) {
      final next = _pendingMode!;
      _pendingMode = null;
      _setMode(next);
    }
  }

  void _handlePointer(PointerEvent event) {
    switch (event.kind) {
      case PointerDeviceKind.touch:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        _setMode(TalInputMode.touch);
      case PointerDeviceKind.mouse:
      case PointerDeviceKind.trackpad:
        _setMode(TalInputMode.mouseKeyboard);
      case PointerDeviceKind.unknown:
        break;
    }
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent && !event.synthesized) {
      _setMode(TalInputMode.mouseKeyboard);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Apply geometry after release so the first tap does not move its own
    // target between pointer-down and pointer-up.
    onPointerDown: (event) {
      _activePointers.add(event.pointer);
      _handlePointer(event);
    },
    onPointerUp: _finishPointer,
    onPointerCancel: _finishPointer,
    onPointerSignal: _handlePointer,
    onPointerPanZoomStart: _handlePointer,
    onPointerHover: (event) {
      if (event.delta != Offset.zero) _handlePointer(event);
    },
    child: widget.builder(context, _mode),
  );
}
