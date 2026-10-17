import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'interaction.dart';
import 'tokens.dart';

/// Shared anchored dropdown used by all compact value selectors.
///
/// This intentionally does not use Flutter's platform-dependent
/// [DropdownButton]. Keeping the anchor, menu surface, hover state, and
/// selection treatment in one widget makes every panel use the same control.
class TalDropdown<T> extends StatefulWidget {
  const TalDropdown({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
    this.highlightOnHover = true,
    super.key,
  });

  final T value;
  final List<T> values;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;
  final bool highlightOnHover;

  @override
  State<TalDropdown<T>> createState() => _TalDropdownState<T>();
}

class _TalDropdownState<T> extends State<TalDropdown<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _anchorFocus = FocusNode();
  final FocusNode _menuFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  OverlayEntry? _overlayEntry;
  late final AnimationController _animationController;
  late final Animation<double> _animation;
  bool expanded = false;
  bool closing = false;
  bool hovered = false;
  int _keyboardIndex = 0;
  bool _keyboardNavigation = false;
  bool _overlayRefreshScheduled = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didUpdateWidget(covariant TalDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keyboardIndex = _keyboardIndex.clamp(
      0,
      math.max(0, widget.values.length - 1),
    );
    _refreshOverlayAfterLayout();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshOverlayAfterLayout();
  }

  void _refreshOverlayAfterLayout() {
    if (_overlayEntry == null || _overlayRefreshScheduled) return;
    _overlayRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRefreshScheduled = false;
      if (mounted) _overlayEntry?.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    expanded = false;
    closing = false;
    hovered = false;
    _animationController.dispose();
    _anchorFocus.dispose();
    _menuFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final highlight = widget.highlightOnHover && hovered;
        return CompositedTransformTarget(
          link: _layerLink,
          child: Semantics(
            button: true,
            expanded: expanded,
            child: MouseRegion(
              onEnter: (_) {
                if (mounted) setState(() => hovered = true);
              },
              onExit: (_) {
                if (mounted) setState(() => hovered = false);
              },
              child: InkWell(
                focusNode: _anchorFocus,
                borderRadius: ui.controlRadius,
                onTap: expanded ? () => unawaited(_close()) : _open,
                child: Container(
                  key: ValueKey<String>(
                    'compact-dropdown-${widget.label(widget.value)}',
                  ),
                  height: ui.controlHeight,
                  decoration: BoxDecoration(
                    color: highlight ? TalColors.hover : TalColors.input,
                    borderRadius: ui.controlRadius,
                    border: const Border.fromBorderSide(talControlBorder),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          child: Text(
                            widget.label(widget.value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: talBody,
                          ),
                        ),
                      ),
                      Container(
                        width: ui.touchOptimized ? 44 : 30,
                        height: double.infinity,
                        decoration: BoxDecoration(
                          color: highlight ? TalColors.hover : null,
                          border: const Border(
                            left: BorderSide(color: TalColors.borderSoft),
                          ),
                        ),
                        child: Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: TalColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _open() {
    if (!mounted || expanded || closing) return;
    _keyboardNavigation = false;
    _keyboardIndex = widget.values
        .indexOf(widget.value)
        .clamp(0, math.max(0, widget.values.length - 1));
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => expanded = true);
    _animationController.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && expanded && !closing) _menuFocus.requestFocus();
    });
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final ui = TalUiTheme.of(overlayContext);
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = overlay.globalToLocal(anchor.localToGlobal(Offset.zero));
    const gap = 2.0;
    final padding = MediaQuery.paddingOf(overlayContext);
    final above = math.max(0.0, topLeft.dy - padding.top - 8 - gap);
    final below = math.max(
      0.0,
      overlay.size.height -
          topLeft.dy -
          anchor.size.height -
          padding.bottom -
          MediaQuery.viewInsetsOf(overlayContext).bottom -
          8 -
          gap,
    );
    final opensUp =
        below < widget.values.length * ui.menuItemHeight && above > below;
    final menuWidth = math.min(anchor.size.width, overlay.size.width - 16);
    final horizontalShift = (overlay.size.width - 8 - topLeft.dx - menuWidth)
        .clamp(-menuWidth, 0.0);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_close()),
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: opensUp ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: opensUp ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(horizontalShift, opensUp ? -gap : gap),
          showWhenUnlinked: false,
          child: SizedBox(
            width: menuWidth,
            child: Focus(
              focusNode: _menuFocus,
              autofocus: true,
              descendantsAreFocusable: false,
              onKeyEvent: _handleMenuKey,
              child: SizeTransition(
                key: const ValueKey<String>('dropdown-menu-animation'),
                sizeFactor: _animation,
                alignment: opensUp
                    ? Alignment.bottomCenter
                    : Alignment.topCenter,
                child: FadeTransition(
                  opacity: _animation,
                  child: Material(
                    color: TalColors.input,
                    elevation: 12,
                    shadowColor: TalColors.shadow,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: ui.controlRadius,
                      side: const BorderSide(color: TalColors.border),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: opensUp ? above : below,
                      ),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final item in widget.values)
                              _buildMenuItem(item, ui),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  KeyEventResult _handleMenuKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (widget.values.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      unawaited(_close(selectedValue: widget.values[_keyboardIndex]));
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    _keyboardNavigation = true;
    _keyboardIndex =
        (_keyboardIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(
          0,
          widget.values.length - 1,
        );
    _overlayEntry?.markNeedsBuild();
    if (_scrollController.hasClients) {
      final height = TalUiTheme.of(context).menuItemHeight;
      final position = _scrollController.position;
      final top = _keyboardIndex * height;
      final bottom = top + height;
      if (top < position.pixels ||
          bottom > position.pixels + position.viewportDimension) {
        _scrollController.jumpTo(
          (top < position.pixels ? top : bottom - position.viewportDimension)
              .clamp(0.0, position.maxScrollExtent),
        );
      }
    }
    return KeyEventResult.handled;
  }

  Widget _buildMenuItem(T item, TalUiTheme ui) {
    var hovered = false;
    return StatefulBuilder(
      builder: (context, setItemState) {
        final highlight =
            (widget.highlightOnHover && hovered) ||
            (_keyboardNavigation &&
                widget.values.indexOf(item) == _keyboardIndex);
        return MouseRegion(
          onEnter: (_) => setItemState(() => hovered = true),
          onExit: (_) => setItemState(() => hovered = false),
          child: InkWell(
            key: ValueKey<String>('dropdown-item-${widget.label(item)}'),
            onTap: () => unawaited(_close(selectedValue: item)),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (widget.highlightOnHover) return Colors.transparent;
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)) {
                return TalColors.hover;
              }
              return Colors.transparent;
            }),
            child: Container(
              key: item == widget.value
                  ? ValueKey<String>('dropdown-selected-${widget.label(item)}')
                  : null,
              height: ui.menuItemHeight,
              width: double.infinity,
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(
                left: item == widget.value ? 9 : 12,
                right: 8,
              ),
              decoration: BoxDecoration(
                color: highlight
                    ? TalColors.hover
                    : item == widget.value
                    ? TalColors.selection
                    : TalColors.input,
                border: item == widget.value
                    ? const Border(
                        left: BorderSide(color: TalColors.accent, width: 3),
                      )
                    : null,
              ),
              child: Text(
                widget.label(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: talBody,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _close({T? selectedValue}) async {
    if (!mounted || !expanded || closing) return;
    closing = true;
    try {
      await _animationController.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted) return;
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    closing = false;
    setState(() => expanded = false);
    _anchorFocus.requestFocus();
    if (selectedValue != null) widget.onChanged(selectedValue);
  }
}
