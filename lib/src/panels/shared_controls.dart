part of 'panels.dart';

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
      height: TalUiTheme.of(context).targetExtent(36),
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
  static const _dragThreshold = 5.0;

  int? _pointer;
  Offset _start = Offset.zero;
  bool _resizing = false;
  int? _contextMenuPointer;
  ValueChanged<Offset>? _onContextMenu;

  // Rows register a menu target; this region arbitrates clicks and resizing.
  void _registerContextMenu(int pointer, ValueChanged<Offset> onContextMenu) {
    if (_pointer != null && _pointer != pointer) return;
    _contextMenuPointer = pointer;
    _onContextMenu = onContextMenu;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons & kSecondaryMouseButton == 0 ||
        widget.canStartAt?.call(event.localPosition) == false) {
      return;
    }
    _pointer = event.pointer;
    _start = event.localPosition;
    if (_contextMenuPointer != event.pointer) {
      _contextMenuPointer = null;
      _onContextMenu = null;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    if (event.buttons & kSecondaryMouseButton == 0) {
      _finish(event.pointer);
      return;
    }
    _updateResize(event.localPosition);
  }

  void _updateResize(Offset position) {
    final delta = position - _start;
    if (!_resizing) {
      if (delta.distanceSquared <= _dragThreshold * _dragThreshold) return;
      widget.onResizeStart();
      setState(() => _resizing = true);
    }
    widget.onResize(delta);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pointer != event.pointer) return;
    _updateResize(event.localPosition);
    final onContextMenu = !_resizing && _contextMenuPointer == event.pointer
        ? _onContextMenu
        : null;
    _finish(event.pointer);
    onContextMenu?.call(event.position);
  }

  void _finish(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _contextMenuPointer = null;
    _onContextMenu = null;
    if (_resizing) setState(() => _resizing = false);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _resizing ? SystemMouseCursors.move : MouseCursor.defer,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
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
