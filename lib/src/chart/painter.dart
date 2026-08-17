import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import '../theme.dart';
import 'downsampling.dart';
import 'viewport.dart';

class TelemetryPainter extends CustomPainter {
  TelemetryPainter(this.controller) : super(repaint: controller.plotChanges);

  final TakeALookController controller;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TalColors.input);
    final viewport = telemetryViewport(controller, size);
    final plot = viewport.plot;
    if (plot.width <= 1 || plot.height <= 1) return;

    if (controller.plotShowGrid) {
      _drawGrid(canvas, plot);
    } else {
      _drawPlotOutline(canvas, plot);
    }
    _drawTitle(canvas, size);

    final plotted = controller.watches.where((item) => item.plotted).toList();
    if (plotted.isEmpty) {
      _drawAxisLabels(
        canvas,
        plot,
        viewport.xMin,
        viewport.xMax,
        viewport.yMin,
        viewport.yMax,
      );
      return;
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final watch in plotted) {
      _drawSeries(
        canvas,
        plot,
        watch,
        viewport.xMin,
        viewport.xMax,
        viewport.yMin,
        viewport.yMax,
      );
    }
    canvas.restore();
    _drawAxisLabels(
      canvas,
      plot,
      viewport.xMin,
      viewport.xMax,
      viewport.yMin,
      viewport.yMax,
    );
    if (controller.plotShowLegend) _drawLegend(canvas, plot, plotted);
  }

  void _drawGrid(Canvas canvas, Rect plot) {
    final minor = Paint()..color = TalColors.gridMinor;
    final major = Paint()..color = TalColors.gridMajor;
    for (var i = 0; i <= 50; i += 1) {
      final x = plot.left + plot.width * i / 50;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        i % 5 == 0 ? major : minor,
      );
    }
    for (var i = 0; i <= 20; i += 1) {
      final y = plot.top + plot.height * i / 20;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        i % 2 == 0 ? major : minor,
      );
    }
    _drawPlotOutline(canvas, plot);
  }

  void _drawPlotOutline(Canvas canvas, Rect plot) {
    canvas.drawRect(
      plot,
      Paint()
        ..color = TalColors.text
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawTitle(Canvas canvas, Size size) {
    _text(
      canvas,
      '变量实时趋势',
      Offset(size.width / 2 - 70, 16),
      const TextStyle(
        color: TalColors.text,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
      width: 140,
      align: TextAlign.center,
    );
  }

  void _drawAxisLabels(
    Canvas canvas,
    Rect plot,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
  ) {
    for (var i = 0; i <= 5; i += 1) {
      final y = plot.bottom - plot.height * i / 5;
      final fraction = controller.plotInvertY ? 1 - i / 5 : i / 5;
      final value = yMin + (yMax - yMin) * fraction;
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(2, y - 7),
        talBody,
        width: 46,
        align: TextAlign.right,
      );
    }
    for (var i = 0; i <= 10; i += 1) {
      final x = plot.left + plot.width * i / 10;
      final fraction = controller.plotInvertX ? 1 - i / 10 : i / 10;
      final value = xMin + (xMax - xMin) * fraction;
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(x - 30, plot.bottom + 7),
        talBody,
        width: 60,
        align: TextAlign.center,
      );
    }
    _text(
      canvas,
      '时间 (s)',
      Offset(plot.center.dx - 45, plot.bottom + 25),
      talBody,
      width: 90,
      align: TextAlign.center,
    );
    canvas.save();
    canvas.translate(12, plot.center.dy + 28);
    canvas.rotate(-math.pi / 2);
    _text(
      canvas,
      '变量值',
      Offset.zero,
      talBody,
      width: 56,
      align: TextAlign.center,
    );
    canvas.restore();
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    WatchItem watch,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
  ) {
    final path = Path();
    var started = false;
    final samples = downsampleTelemetrySamples(
      controller.plotSamplesFor(watch),
      xMin: xMin,
      xMax: xMax,
      pixelWidth: plot.width,
    );
    for (final point in samples) {
      final xFraction = (point.dx - xMin) / (xMax - xMin);
      final yFraction = (point.dy - yMin) / (yMax - yMin);
      final x = controller.plotInvertX
          ? plot.right - xFraction * plot.width
          : plot.left + xFraction * plot.width;
      final y = controller.plotInvertY
          ? plot.top + yFraction * plot.height
          : plot.bottom - yFraction * plot.height;
      if (started) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        started = true;
      }
    }
    if (!started) return;
    canvas.drawPath(
      path,
      Paint()
        ..color = watch.color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawLegend(Canvas canvas, Rect plot, List<WatchItem> watches) {
    var x = plot.left + 10;
    final y = plot.top + 8;
    for (final watch in watches.take(6)) {
      canvas.drawRect(
        Rect.fromLTWH(x, y + 3, 10, 3),
        Paint()..color = watch.color,
      );
      x += 15;
      _text(canvas, watch.symbol.name, Offset(x, y - 3), talMuted, width: 100);
      x += 108;
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset offset,
    TextStyle style, {
    double width = 80,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: style.copyWith(
          fontFamily: talFontFamily,
          fontFamilyFallback: talFontFamilyFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TelemetryPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}
