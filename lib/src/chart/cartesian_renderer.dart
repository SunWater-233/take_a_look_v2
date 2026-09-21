import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Axis bounds and coordinate mapping shared by realtime and analysis charts.
class CartesianPlotViewport {
  const CartesianPlotViewport({
    required this.plot,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    this.invertX = false,
    this.invertY = false,
  });

  final Rect plot;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final bool invertX;
  final bool invertY;

  double get xSpan => math.max(1e-9, xMax - xMin);
  double get ySpan => math.max(1e-9, yMax - yMin);

  double mapX(double value) {
    final fraction = (value - xMin) / xSpan;
    final mapped = invertX ? 1 - fraction : fraction;
    return plot.left + plot.width * mapped;
  }

  double mapY(double value) {
    final fraction = (value - yMin) / ySpan;
    final mapped = invertY ? fraction : 1 - fraction;
    return plot.top + plot.height * mapped;
  }

  double xFractionAt(double pixelX) {
    final fraction = ((pixelX - plot.left) / math.max(1, plot.width)).clamp(
      0.0,
      1.0,
    );
    return invertX ? 1 - fraction : fraction;
  }

  double yFractionAt(double pixelY) {
    final fraction = invertY
        ? (pixelY - plot.top) / math.max(1, plot.height)
        : (plot.bottom - pixelY) / math.max(1, plot.height);
    return fraction.clamp(0.0, 1.0);
  }

  double unmapX(double pixelX) => xMin + xSpan * xFractionAt(pixelX);

  double unmapY(double pixelY) => yMin + ySpan * yFractionAt(pixelY);
}

(double, double) clampCartesianWindow(
  double minimum,
  double maximum,
  double dataMinimum,
  double dataMaximum,
) {
  final span = maximum - minimum;
  if (span >= dataMaximum - dataMinimum) return (dataMinimum, dataMaximum);
  if (minimum < dataMinimum) return (dataMinimum, dataMinimum + span);
  if (maximum > dataMaximum) return (dataMaximum - span, dataMaximum);
  return (minimum, maximum);
}

(double, double) zoomCartesianWindow({
  required double minimum,
  required double maximum,
  required double dataMinimum,
  required double dataMaximum,
  required double anchorFraction,
  required double scale,
}) {
  final dataSpan = dataMaximum - dataMinimum;
  final span = ((maximum - minimum) * scale).clamp(
    math.max(dataSpan * 0.0001, 1e-9),
    dataSpan,
  );
  final anchor = minimum + (maximum - minimum) * anchorFraction;
  final nextMinimum = anchor - span * anchorFraction;
  return clampCartesianWindow(
    nextMinimum,
    nextMinimum + span,
    dataMinimum,
    dataMaximum,
  );
}

class CartesianLegendItem {
  const CartesianLegendItem({required this.label, required this.color});

  final String label;
  final Color color;
}

/// Stateless drawing primitives used by every cartesian line chart.
///
/// Panels keep ownership of their data and gestures; this class owns the
/// shared visual language: coordinate mapping, grids, ticks, lines and legend.
class CartesianChartRenderer {
  const CartesianChartRenderer({
    required this.canvas,
    required this.size,
    required this.viewport,
  });

  final Canvas canvas;
  final Size size;
  final CartesianPlotViewport viewport;

  void drawBackground() {
    canvas.drawRect(Offset.zero & size, Paint()..color = TalColors.input);
  }

  void drawGrid({bool visible = true}) {
    if (visible) {
      final minor = Paint()..color = TalColors.gridMinor;
      final major = Paint()..color = TalColors.gridMajor;
      _drawValueGridLines(
        min: viewport.xMin,
        max: viewport.xMax,
        targetMajorCount: 10,
        minorDivisions: 5,
        position: viewport.mapX,
        line: (position, paint) => canvas.drawLine(
          Offset(position, viewport.plot.top),
          Offset(position, viewport.plot.bottom),
          paint,
        ),
        minorPaint: minor,
        majorPaint: major,
      );
      _drawValueGridLines(
        min: viewport.yMin,
        max: viewport.yMax,
        targetMajorCount: 5,
        minorDivisions: 2,
        position: viewport.mapY,
        line: (position, paint) => canvas.drawLine(
          Offset(viewport.plot.left, position),
          Offset(viewport.plot.right, position),
          paint,
        ),
        minorPaint: minor,
        majorPaint: major,
      );
    }
    canvas.drawRect(
      viewport.plot,
      Paint()
        ..color = TalColors.text
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void drawTitle(String title, {double top = 16}) {
    drawText(
      title,
      Offset(size.width / 2 - 70, top),
      const TextStyle(
        color: TalColors.text,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
      width: 140,
      align: TextAlign.center,
    );
  }

  void drawAxisLabels({
    String xAxisLabel = '时间 (s)',
    double yLabelOffset = 48,
    double xTickOffset = 2,
    double xAxisLabelOffset = 25,
  }) {
    final yStep = niceStep(viewport.ySpan, 5);
    for (final value in majorTicks(viewport.yMin, viewport.yMax, 5)) {
      drawText(
        formatTick(value, yStep),
        Offset(viewport.plot.left - yLabelOffset, viewport.mapY(value) - 7),
        talBody,
        width: 46,
        align: TextAlign.right,
      );
    }
    final xStep = niceStep(viewport.xSpan, 10);
    for (final value in majorTicks(viewport.xMin, viewport.xMax, 10)) {
      final x = viewport.mapX(value);
      final inset = math.min(30.0, viewport.plot.width / 2);
      final center = x
          .clamp(viewport.plot.left + inset, viewport.plot.right - inset)
          .toDouble();
      drawText(
        formatTick(value, xStep),
        Offset(center - 30, viewport.plot.bottom + xTickOffset),
        talBody,
        width: 60,
        align: TextAlign.center,
      );
    }
    drawText(
      xAxisLabel,
      Offset(
        viewport.plot.center.dx - 45,
        viewport.plot.bottom + xAxisLabelOffset,
      ),
      talBody,
      width: 90,
      align: TextAlign.center,
    );
  }

  void drawPolyline(
    Iterable<Offset> points,
    Color color, {
    double strokeWidth = 1.8,
  }) {
    final path = Path();
    var started = false;
    for (final point in points) {
      if (point.dx < viewport.xMin || point.dx > viewport.xMax) continue;
      final x = viewport.mapX(point.dx);
      final y = viewport.mapY(point.dy);
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
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void drawLegend(
    Iterable<CartesianLegendItem> items, {
    bool wrap = false,
    int? maximumItems,
  }) {
    var x = viewport.plot.left + 10;
    var y = viewport.plot.top + 8;
    final visibleItems = maximumItems == null
        ? items
        : items.take(maximumItems);
    for (final item in visibleItems) {
      if (wrap && x + 123 > viewport.plot.right) {
        x = viewport.plot.left + 10;
        y += 18;
      }
      if (y + 12 > viewport.plot.bottom) break;
      canvas.drawRect(
        Rect.fromLTWH(x, y + 3, 10, 3),
        Paint()..color = item.color,
      );
      drawText(item.label, Offset(x + 15, y - 3), talMuted, width: 100);
      x += 123;
    }
  }

  void drawText(
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

  static double niceStep(double span, int targetMajorCount) {
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

  static List<double> majorTicks(double min, double max, int targetMajorCount) {
    final step = niceStep(max - min, targetMajorCount);
    final first = (min / step).ceil();
    final last = (max / step).floor();
    return [for (var index = first; index <= last; index += 1) index * step];
  }

  static String formatTick(double value, double step) {
    final absolute = value.abs();
    if (absolute >= 10000 || (absolute > 0 && absolute < 0.001)) {
      return value.toStringAsExponential(1);
    }
    final decimals = step >= 1
        ? 0
        : (-(math.log(step) / math.ln10).floor()).clamp(0, 6);
    return value.toStringAsFixed(decimals);
  }

  void _drawValueGridLines({
    required double min,
    required double max,
    required int targetMajorCount,
    required int minorDivisions,
    required double Function(double value) position,
    required void Function(double position, Paint paint) line,
    required Paint minorPaint,
    required Paint majorPaint,
  }) {
    final majorStep = niceStep(max - min, targetMajorCount);
    final minorStep = majorStep / minorDivisions;
    final first = (min / minorStep).ceil();
    final last = (max / minorStep).floor();
    for (var index = first; index <= last; index += 1) {
      line(
        position(index * minorStep),
        index % minorDivisions == 0 ? majorPaint : minorPaint,
      );
    }
  }
}
