import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'workspace_geometry.dart';

const _geometry = WorkspaceGeometry();

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
    final minorPaint = Paint()..color = const Color(0xFF242123);
    final majorPaint = Paint()..color = const Color(0xFF3A3638);
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
