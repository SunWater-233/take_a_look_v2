import 'package:flutter/material.dart';

import '../theme/theme.dart';

class ZoomSelectionPainter extends CustomPainter {
  const ZoomSelectionPainter(this.selection);

  final Rect selection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(selection, Paint()..color = TalColors.accent.withAlpha(35));
    canvas.drawRect(
      selection,
      Paint()
        ..color = TalColors.accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant ZoomSelectionPainter oldDelegate) {
    return oldDelegate.selection != selection;
  }
}
