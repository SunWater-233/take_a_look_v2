import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'workspace_geometry.dart';
import 'panel_types.dart';

const _geometry = WorkspaceGeometry();

class WorkspaceSidebarHandle extends StatefulWidget {
  const WorkspaceSidebarHandle({
    required this.side,
    required this.expanded,
    required this.label,
    required this.onPressed,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    super.key,
  });
  final WorkspaceSidebarSide side;
  final bool expanded;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragEnd;

  @override
  State<WorkspaceSidebarHandle> createState() => _WorkspaceSidebarHandleState();
}

class _WorkspaceSidebarHandleState extends State<WorkspaceSidebarHandle> {
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;

  void _finishDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    expanded: widget.expanded,
    label: widget.label,
    child: Tooltip(
      message: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: widget.expanded
            ? (_) {
                setState(() => _dragging = true);
                widget.onDragStart();
              }
            : null,
        onHorizontalDragUpdate: widget.expanded
            ? (details) => widget.onDrag(details.delta)
            : null,
        onHorizontalDragEnd: widget.expanded ? (_) => _finishDrag() : null,
        onHorizontalDragCancel: widget.expanded ? _finishDrag : null,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            mouseCursor: widget.expanded
                ? SystemMouseCursors.resizeLeftRight
                : SystemMouseCursors.click,
            onTap: widget.onPressed,
            onHover: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            child: Align(
              alignment: widget.side == WorkspaceSidebarSide.left
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 120),
                width: _hovered || _focused || _dragging ? 5 : 3,
                height: 42,
                decoration: BoxDecoration(
                  color: _hovered || _focused || _dragging
                      ? TalColors.accent
                      : TalColors.muted,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class WorkspaceDockPreview extends StatelessWidget {
  const WorkspaceDockPreview({
    required this.edge,
    required this.armed,
    super.key,
  });
  final WorkspaceDockEdge edge;
  final bool armed;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 130),
    decoration: BoxDecoration(
      color: TalColors.selection.withValues(alpha: armed ? .88 : .12),
      border: Border.all(color: TalColors.accent, width: 2),
    ),
    child: Center(
      child: AnimatedOpacity(
        opacity: armed ? 1 : 0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 130),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: TalColors.surface,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('松手放入${edge.label}', style: talBody),
          ),
        ),
      ),
    ),
  );
}

class WorkspaceResizeHandle extends StatelessWidget {
  const WorkspaceResizeHandle({
    required this.alignment,
    required this.cursor,
    required this.width,
    required this.height,
    required this.onDrag,
    required this.onDragStart,
    required this.onDragEnd,
    this.enabled = true,
    this.visible = false,
    this.handleKey,
    super.key,
  });

  final Alignment alignment;
  final MouseCursor cursor;
  final double width;
  final double height;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final bool enabled;
  final bool visible;
  final Key? handleKey;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: MouseRegion(
        cursor: enabled ? cursor : MouseCursor.defer,
        child: GestureDetector(
          key: handleKey,
          behavior: HitTestBehavior.opaque,
          onPanStart: enabled ? (_) => onDragStart() : null,
          onPanUpdate: enabled ? (details) => onDrag(details.delta) : null,
          onPanEnd: enabled ? (_) => onDragEnd() : null,
          child: SizedBox(
            width: math.max(1, width),
            height: math.max(1, height),
            child: visible
                ? const Align(
                    alignment: Alignment.bottomRight,
                    child: Icon(
                      Icons.drag_handle,
                      size: 15,
                      color: TalColors.muted,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class WorkspaceGridPainter extends CustomPainter {
  const WorkspaceGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final minorPaint = Paint()..color = TalColors.borderSoft;
    final majorPaint = Paint()..color = TalColors.border;
    for (
      var index = 1, x = _geometry.gridCellSize;
      x < size.width;
      index += 1, x += _geometry.gridCellSize
    ) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        index % 4 == 0 ? majorPaint : minorPaint,
      );
    }
    for (
      var index = 1, y = _geometry.gridCellSize;
      y < size.height;
      index += 1, y += _geometry.gridCellSize
    ) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        index % 4 == 0 ? majorPaint : minorPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
