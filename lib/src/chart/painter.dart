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
      _drawGrid(
        canvas,
        plot,
        xMin: viewport.xMin,
        xMax: viewport.xMax,
        yMin: viewport.yMin,
        yMax: viewport.yMax,
      );
    } else {
      _drawPlotOutline(canvas, plot);
    }
    _drawTitle(canvas, size);

    final plotted = controller.watches.where((item) => item.plotted).toList();
    if (plotted.isEmpty) {
      _drawAxisLabels(canvas, plot, viewport);
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
    _drawAxisLabels(canvas, plot, viewport);
    if (controller.plotShowLegend) _drawLegend(canvas, plot, plotted);
  }

  void _drawGrid(
    Canvas canvas,
    Rect plot, {
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
  }) {
    final minor = Paint()..color = TalColors.gridMinor;
    final major = Paint()..color = TalColors.gridMajor;

    _drawValueGridLines(
      min: xMin,
      max: xMax,
      targetMajorCount: 10,
      minorDivisions: 5,
      paint: minor,
      majorPaint: major,
      position: (value) {
        final fraction = (value - xMin) / (xMax - xMin);
        final mapped = controller.plotInvertX ? 1 - fraction : fraction;
        return plot.left + plot.width * mapped;
      },
      line: (position, paint) => canvas.drawLine(
        Offset(position, plot.top),
        Offset(position, plot.bottom),
        paint,
      ),
    );
    _drawValueGridLines(
      min: yMin,
      max: yMax,
      targetMajorCount: 5,
      minorDivisions: 2,
      paint: minor,
      majorPaint: major,
      position: (value) {
        final fraction = (value - yMin) / (yMax - yMin);
        final mapped = controller.plotInvertY ? fraction : 1 - fraction;
        return plot.top + plot.height * mapped;
      },
      line: (position, paint) => canvas.drawLine(
        Offset(plot.left, position),
        Offset(plot.right, position),
        paint,
      ),
    );
    _drawPlotOutline(canvas, plot);
  }

  void _drawValueGridLines({
    required double min,
    required double max,
    required int targetMajorCount,
    required int minorDivisions,
    required Paint paint,
    required Paint majorPaint,
    required double Function(double value) position,
    required void Function(double position, Paint paint) line,
  }) {
    final majorStep = _niceStep(max - min, targetMajorCount);
    final minorStep = majorStep / minorDivisions;
    final first = (min / minorStep).ceil();
    final last = (max / minorStep).floor();
    for (var index = first; index <= last; index += 1) {
      final value = index * minorStep;
      final isMajor = index % minorDivisions == 0;
      line(position(value), isMajor ? majorPaint : paint);
    }
  }

  double _niceStep(double span, int targetMajorCount) {
    final raw = span / targetMajorCount;
    if (!raw.isFinite || raw <= 0) return 1;
    final magnitude = math
        .pow(10, (math.log(raw) / math.ln10).floor())
        .toDouble();
    final normalized = raw / magnitude;
    final factor = normalized <= 1
        ? 1
        : normalized <= 2
        ? 2
        : normalized <= 5
        ? 5
        : 10;
    return factor * magnitude;
  }

  List<double> _majorTicks(double min, double max, int targetMajorCount) {
    final step = _niceStep(max - min, targetMajorCount);
    final first = (min / step).ceil();
    final last = (max / step).floor();
    return [for (var index = first; index <= last; index += 1) index * step];
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

  void _drawAxisLabels(Canvas canvas, Rect plot, TelemetryViewport viewport) {
    final xMin = viewport.xMin;
    final xMax = viewport.xMax;
    final yMin = viewport.yMin;
    final yMax = viewport.yMax;
    for (final value in _majorTicks(yMin, yMax, 5)) {
      final fraction = (value - yMin) / (yMax - yMin);
      final mapped = controller.plotInvertY ? fraction : 1 - fraction;
      final y = plot.top + plot.height * mapped;
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(plot.left - 42, y - 7),
        talBody,
        width: 46,
        align: TextAlign.right,
      );
    }
    for (final value in _majorTicks(xMin, xMax, 10)) {
      final fraction = (value - xMin) / (xMax - xMin);
      final mapped = controller.plotInvertX ? 1 - fraction : fraction;
      final x = plot.left + plot.width * mapped;
      final labelInset = math.min(30.0, plot.width / 2);
      final labelCenter = x
          .clamp(plot.left + labelInset, plot.right - labelInset)
          .toDouble();
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(labelCenter - 30, plot.bottom + 2),
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
