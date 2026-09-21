part of '../panels.dart';

typedef _ColumnResizeCallback = void Function(int index, double delta);
typedef _ColumnContextMenuCallback =
    void Function(int index, _ContextMenuRequest request);

class _ContextMenuRequest {
  const _ContextMenuRequest({
    required this.globalPosition,
    required this.touchOptimized,
  });

  final Offset globalPosition;
  final bool touchOptimized;
}

class _ResizableTableHeaderCell extends StatelessWidget {
  const _ResizableTableHeaderCell({
    required this.label,
    required this.width,
    required this.columnIndex,
    required this.keyPrefix,
    required this.onResize,
    this.selected = false,
    this.onSelect,
    this.onContextMenu,
  });

  final String label;
  final double width;
  final int columnIndex;
  final String keyPrefix;
  final _ColumnResizeCallback onResize;
  final bool selected;
  final ValueChanged<int>? onSelect;
  final _ColumnContextMenuCallback? onContextMenu;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 36,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Material(
            color: selected ? TalColors.selection : TalColors.surfaceAlt,
            child: InkWell(
              onTap: onSelect == null ? null : () => onSelect!(columnIndex),
              onLongPress: onContextMenu == null
                  ? null
                  : () {
                      final box = context.findRenderObject()! as RenderBox;
                      onContextMenu!(
                        columnIndex,
                        _ContextMenuRequest(
                          globalPosition: box.localToGlobal(
                            box.size.center(Offset.zero),
                          ),
                          touchOptimized: true,
                        ),
                      );
                    },
              onSecondaryTapUp: onContextMenu == null
                  ? null
                  : (details) => onContextMenu!(
                      columnIndex,
                      _ContextMenuRequest(
                        globalPosition: details.globalPosition,
                        touchOptimized: false,
                      ),
                    ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: TalColors.border)),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: talStrong,
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 8,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                key: ValueKey('$keyPrefix-column-resize-$columnIndex'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) =>
                    onResize(columnIndex, details.delta.dx),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RightDragResizeRegion extends StatefulWidget {
  const _RightDragResizeRegion({
    required this.onResizeStart,
    required this.onResize,
    required this.child,
    this.canStartAt,
    super.key,
  });

  final VoidCallback onResizeStart;
  final ValueChanged<Offset> onResize;
  final Widget child;
  final bool Function(Offset position)? canStartAt;

  @override
  State<_RightDragResizeRegion> createState() => _RightDragResizeRegionState();
}

class _RightDragResizeRegionState extends State<_RightDragResizeRegion> {
  int? _pointer;
  Offset _start = Offset.zero;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons & kSecondaryMouseButton == 0 ||
        widget.canStartAt?.call(event.localPosition) == false) {
      return;
    }
    _pointer = event.pointer;
    _start = event.localPosition;
    widget.onResizeStart();
    setState(() {});
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    if (event.buttons & kSecondaryMouseButton == 0) {
      _finish(event.pointer);
      return;
    }
    widget.onResize(event.localPosition - _start);
  }

  void _finish(int pointer) {
    if (_pointer != pointer) return;
    setState(() => _pointer = null);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _pointer == null ? MouseCursor.defer : SystemMouseCursors.move,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: (event) => _finish(event.pointer),
        onPointerCancel: (event) => _finish(event.pointer),
        child: widget.child,
      ),
    );
  }
}

/// Shared viewport for the resizable tables used by symbols, realtime tuning
/// and analysis statistics.
///
/// It keeps horizontal overflow, header/body alignment and right-drag scaling
/// in one place while leaving row construction and selection to each panel.
class _ResizableTableViewport extends StatelessWidget {
  const _ResizableTableViewport({
    required this.layout,
    required this.contentWidth,
    required this.header,
    required this.body,
    required this.onLayoutChanged,
    required this.minimumRowHeight,
    required this.contentKey,
    required this.resizeRegionKey,
    this.horizontalController,
    this.bodyDecoration,
    this.canStartResizeAt,
    this.columnScale = 0.85,
    this.rowScale = 0.85,
  });

  final ResizableTableLayout layout;
  final double contentWidth;
  final Widget header;
  final Widget body;
  final VoidCallback onLayoutChanged;
  final double minimumRowHeight;
  final Key contentKey;
  final Key resizeRegionKey;
  final ScrollController? horizontalController;
  final Decoration? bodyDecoration;
  final bool Function(Offset position)? canStartResizeAt;
  final double columnScale;
  final double rowScale;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(contentWidth, constraints.maxWidth);
        return SingleChildScrollView(
          controller: horizontalController,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            key: contentKey,
            width: width,
            height: constraints.maxHeight,
            child: Column(
              children: [
                header,
                Expanded(
                  child: DecoratedBox(
                    decoration:
                        bodyDecoration ??
                        const BoxDecoration(color: TalColors.input),
                    child: _RightDragResizeRegion(
                      key: resizeRegionKey,
                      onResizeStart: layout.beginResize,
                      onResize: (delta) {
                        if (layout.resizeAll(
                          delta,
                          columnScale: columnScale,
                          rowScale: rowScale,
                          minimumRowHeight: minimumRowHeight,
                        )) {
                          onLayoutChanged();
                        }
                      },
                      canStartAt: canStartResizeAt,
                      child: body,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
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
  OverlayEntry? _overlayEntry;
  late final AnimationController _animationController;
  late final Animation<double> _animation;
  bool expanded = false;
  bool closing = false;
  bool hovered = false;

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
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    expanded = false;
    closing = false;
    hovered = false;
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                borderRadius: talControlRadius,
                onTap: expanded
                    ? () => unawaited(_close())
                    : () => _open(constraints.maxWidth),
                child: Container(
                  key: ValueKey<String>(
                    'compact-dropdown-${widget.label(widget.value)}',
                  ),
                  height: talControlHeight,
                  decoration: BoxDecoration(
                    color: highlight ? TalColors.hover : TalColors.input,
                    borderRadius: talControlRadius,
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
                        width: 30,
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

  void _open(double width) {
    if (!mounted || expanded || closing) return;
    _overlayEntry = OverlayEntry(builder: (_) => _buildOverlay(width));
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => expanded = true);
    _animationController.forward(from: 0);
  }

  Widget _buildOverlay(double width) {
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
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 2),
          showWhenUnlinked: false,
          child: SizedBox(
            width: width,
            child: SizeTransition(
              key: const ValueKey<String>('dropdown-menu-animation'),
              sizeFactor: _animation,
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: _animation,
                child: Material(
                  color: TalColors.input,
                  elevation: 12,
                  shadowColor: Colors.black,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: talControlRadius,
                    side: const BorderSide(color: TalColors.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in widget.values) _buildMenuItem(item),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem(T item) {
    var hovered = false;
    return StatefulBuilder(
      builder: (context, setItemState) {
        final highlight = widget.highlightOnHover && hovered;
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
              height: talControlHeight,
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
    await _animationController.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
    closing = false;
    if (!mounted) return;
    setState(() => expanded = false);
    if (selectedValue != null) widget.onChanged(selectedValue);
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label, style: talBody)),
        Expanded(child: child),
      ],
    );
  }
}
