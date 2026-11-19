import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'interaction.dart';
import 'tokens.dart';

class TalDropdownEditor<T> {
  const TalDropdownEditor({
    required this.parse,
    required this.errorMessage,
    this.text,
  });

  final T? Function(String text) parse;
  final String errorMessage;
  final String Function(T value)? text;
}

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
    this.editor,
    this.highlightOnHover = true,
    this.subtle = false,
    super.key,
  });

  final T value;
  final List<T> values;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;
  final TalDropdownEditor<T>? editor;
  final bool highlightOnHover;

  /// A quiet trigger for repeated row actions; the menu behavior stays shared.
  final bool subtle;

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
  bool _editing = false;
  int _keyboardIndex = 0;
  bool _keyboardNavigation = false;
  bool _overlayRefreshScheduled = false;

  List<T> get _menuValues =>
      widget.editor == null || widget.values.contains(widget.value)
      ? widget.values
      : [...widget.values, widget.value];

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
      math.max(0, _menuValues.length - 1),
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
    final editor = widget.editor;
    final valueLabel = widget.label(widget.value);
    final highlight = widget.highlightOnHover && hovered;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Text(
        valueLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: talBody,
      ),
    );
    final arrow = Container(
      width: _arrowWidth(ui),
      height: double.infinity,
      decoration: BoxDecoration(
        border: widget.subtle
            ? null
            : const Border(left: BorderSide(color: TalColors.borderSoft)),
      ),
      child: const Icon(Icons.arrow_drop_down, size: 18, color: TalColors.text),
    );
    final arrowTrigger = editor == null
        ? arrow
        : _menuTrigger(ui, Tooltip(message: '展开选项', child: arrow));
    final Widget anchor;
    if (_editing && editor != null) {
      anchor = _DropdownInput<T>(
        initialText: editor.text?.call(widget.value) ?? valueLabel,
        editor: editor,
        arrowTrigger: arrowTrigger,
        onSubmitted: (value) {
          _finishEditing();
          if (value != widget.value) widget.onChanged(value);
        },
        onCanceled: _finishEditing,
      );
    } else {
      final display = Container(
        key: ValueKey<String>('compact-dropdown-$valueLabel'),
        height: ui.controlHeight,
        decoration: BoxDecoration(
          color: highlight
              ? TalColors.hover
              : widget.subtle
              ? Colors.transparent
              : TalColors.input,
          borderRadius: ui.controlRadius,
          border: widget.subtle
              ? null
              : const Border.fromBorderSide(talControlBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: editor == null
                  ? label
                  : Tooltip(
                      message: '单击编辑',
                      child: InkWell(
                        borderRadius: ui.controlRadius,
                        mouseCursor: SystemMouseCursors.text,
                        onTap: _beginEditing,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: label,
                        ),
                      ),
                    ),
            ),
            arrowTrigger,
          ],
        ),
      );
      anchor = editor == null ? _menuTrigger(ui, display) : display;
    }
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          if (mounted) setState(() => hovered = true);
        },
        onExit: (_) {
          if (mounted) setState(() => hovered = false);
        },
        child: anchor,
      ),
    );
  }

  double _arrowWidth(TalUiTheme ui) => widget.subtle
      ? (ui.touchOptimized ? 32 : 24)
      : (ui.touchOptimized ? 44 : 30);

  Widget _menuTrigger(TalUiTheme ui, Widget child) => Semantics(
    button: true,
    expanded: expanded,
    child: InkWell(
      focusNode: _anchorFocus,
      borderRadius: ui.controlRadius,
      onTap: expanded ? () => unawaited(_close()) : _open,
      child: child,
    ),
  );

  void _beginEditing() {
    if (_editing || closing) return;
    if (expanded) {
      unawaited(_close(edit: true));
    } else {
      setState(() => _editing = true);
    }
  }

  void _finishEditing({bool restoreFocus = true}) {
    if (!_editing) return;
    setState(() => _editing = false);
    if (restoreFocus) _anchorFocus.requestFocus();
  }

  void _open() {
    if (!mounted || expanded || closing) return;
    final values = _menuValues;
    _keyboardNavigation = false;
    _keyboardIndex = values
        .indexOf(widget.value)
        .clamp(0, math.max(0, values.length - 1));
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_overlayEntry!);
    setState(() {
      _editing = false;
      expanded = true;
    });
    _animationController.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && expanded && !closing) _menuFocus.requestFocus();
    });
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final ui = TalUiTheme.of(overlayContext);
    final values = _menuValues;
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
    final opensUp = below < values.length * ui.menuItemHeight && above > below;
    final menuWidth = math.min(anchor.size.width, overlay.size.width - 16);
    final horizontalShift = (overlay.size.width - 8 - topLeft.dx - menuWidth)
        .clamp(-menuWidth, 0.0);
    final menu = Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_close()),
          ),
        ),
        if (widget.editor != null)
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            child: SizedBox.fromSize(
              size: anchor.size,
              child: Padding(
                padding: EdgeInsets.only(
                  right:
                      _arrowWidth(ui) +
                      (widget.subtle ? 0 : talControlBorder.width),
                ),
                child: MouseRegion(
                  cursor: SystemMouseCursors.text,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: _beginEditing,
                  ),
                ),
              ),
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
                            for (final (index, item) in values.indexed)
                              _buildMenuItem(item, index, ui),
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
    final parentMenu = MenuController.maybeOf(context);
    // Keep the anchor menu open while the user picks a dropdown option.
    return parentMenu?.isOpen == true
        ? TapRegion(groupId: parentMenu, child: menu)
        : menu;
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
    final values = _menuValues;
    if (values.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      unawaited(_close(selectedValue: values[_keyboardIndex]));
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
          values.length - 1,
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

  Widget _buildMenuItem(T item, int index, TalUiTheme ui) {
    var hovered = false;
    return StatefulBuilder(
      builder: (context, setItemState) {
        final highlight =
            (widget.highlightOnHover && hovered) ||
            (_keyboardNavigation && index == _keyboardIndex);
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

  Future<void> _close({T? selectedValue, bool edit = false}) async {
    if (!mounted || !expanded || closing) return;
    closing = true;
    if (edit) {
      _animationController.reset();
    } else {
      try {
        await _animationController.reverse().orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    closing = false;
    setState(() {
      expanded = false;
      _editing = edit;
    });
    if (!edit) _anchorFocus.requestFocus();
    if (selectedValue != null) widget.onChanged(selectedValue);
  }
}

class _DropdownInput<T> extends StatefulWidget {
  const _DropdownInput({
    required this.initialText,
    required this.editor,
    required this.arrowTrigger,
    required this.onSubmitted,
    required this.onCanceled,
  });

  final String initialText;
  final TalDropdownEditor<T> editor;
  final Widget arrowTrigger;
  final ValueChanged<T> onSubmitted;
  final void Function({bool restoreFocus}) onCanceled;

  @override
  State<_DropdownInput<T>> createState() => _DropdownInputState<T>();
}

class _DropdownInputState<T> extends State<_DropdownInput<T>> {
  final _focus = FocusNode();
  final _tooltip = GlobalKey<TooltipState>();
  late final _text = TextEditingController.fromValue(
    TextEditingValue(
      text: widget.initialText,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialText.length,
      ),
    ),
  );
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) widget.onCanceled(restoreFocus: false);
  }

  void _submit(String text) {
    final value = widget.editor.parse(text);
    if (value != null) {
      widget.onSubmitted(value);
      return;
    }
    setState(() => _invalid = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _invalid) _tooltip.currentState?.ensureTooltipVisible();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    return SizedBox(
      height: ui.controlHeight,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onCanceled,
        },
        child: Tooltip(
          key: _tooltip,
          triggerMode: TooltipTriggerMode.manual,
          message: _invalid ? widget.editor.errorMessage : '回车确认，Esc 取消',
          child: Semantics(
            liveRegion: _invalid,
            label: _invalid ? widget.editor.errorMessage : null,
            child: TextField(
              autofocus: true,
              controller: _text,
              focusNode: _focus,
              textInputAction: TextInputAction.done,
              style: talBody,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                // Let the outline fill the dropdown's fixed height.
                isDense: false,
                filled: true,
                fillColor: TalColors.input,
                contentPadding: const EdgeInsets.symmetric(horizontal: 9),
                suffixIcon: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 1, 1, 1),
                  child: widget.arrowTrigger,
                ),
                suffixIconConstraints: const BoxConstraints(),
                focusedBorder: OutlineInputBorder(
                  borderRadius: ui.controlRadius,
                  borderSide: BorderSide(
                    color: _invalid ? TalColors.error : TalColors.accent,
                  ),
                ),
              ),
              onChanged: (_) {
                if (_invalid) setState(() => _invalid = false);
              },
              onEditingComplete: () {},
              onSubmitted: _submit,
              onTapOutside: (_) => _focus.unfocus(),
            ),
          ),
        ),
      ),
    );
  }
}
