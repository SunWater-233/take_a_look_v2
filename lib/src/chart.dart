import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

class TelemetryChart extends StatelessWidget {
  const TelemetryChart({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _TelemetryPainter(controller),
        isComplex: true,
        willChange: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: controller.plotChanges,
              builder: (context, _) {
                if (!controller.plottingPaused) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 16,
                  bottom: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: TalColors.surfaceAlt,
                      border: Border.all(color: TalColors.accent),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('绘图已暂停', style: talStrong),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TelemetryPainter extends CustomPainter {
  _TelemetryPainter(this.controller) : super(repaint: controller.plotChanges);

  final TakeALookController controller;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TalColors.input);
    final plot = Rect.fromLTRB(
      52,
      48,
      math.max(54, size.width - 10),
      math.max(50, size.height - 46),
    );
    if (plot.width <= 1 || plot.height <= 1) return;

    _drawGrid(canvas, plot);
    _drawTitle(canvas, size);

    final plotted = controller.watches.where((item) => item.plotted).toList();
    if (plotted.isEmpty) {
      _drawAxisLabels(canvas, plot, -500, 500, 0.5, 1.5);
      return;
    }

    var xMax = controller.plotWindowEndSeconds;
    var xMin = math.max(0.0, xMax - 12.0);
    var yMin = double.infinity;
    var yMax = -double.infinity;
    for (final watch in plotted) {
      for (final point in controller.plotSamplesFor(watch)) {
        if (point.dx < xMin) continue;
        yMin = math.min(yMin, point.dy);
        yMax = math.max(yMax, point.dy);
      }
    }
    if (!yMin.isFinite || !yMax.isFinite) {
      yMin = -1;
      yMax = 1;
    }
    if ((yMax - yMin).abs() < 0.001) {
      yMin -= 1;
      yMax += 1;
    } else {
      final pad = (yMax - yMin) * 0.12;
      yMin -= pad;
      yMax += pad;
    }
    if (xMax <= xMin) xMax = xMin + 12;

    canvas.save();
    canvas.clipRect(plot);
    for (final watch in plotted) {
      _drawSeries(canvas, plot, watch, xMin, xMax, yMin, yMax);
    }
    canvas.restore();
    _drawAxisLabels(canvas, plot, xMin * 1000, xMax * 1000, yMin, yMax);
    _drawLegend(canvas, plot, plotted);
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
      final value = yMin + (yMax - yMin) * i / 5;
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
      final value = xMin + (xMax - xMin) * i / 10;
      _text(
        canvas,
        value.toStringAsFixed(0),
        Offset(x - 30, plot.bottom + 7),
        talBody,
        width: 60,
        align: TextAlign.center,
      );
    }
    _text(
      canvas,
      '时间 (ms)',
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
      final x = plot.left + (point.dx - xMin) / (xMax - xMin) * plot.width;
      final y = plot.bottom - (point.dy - yMin) / (yMax - yMin) * plot.height;
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
  bool shouldRepaint(covariant _TelemetryPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}

List<Offset> downsampleTelemetrySamples(
  Iterable<Offset> samples, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  final visible = [
    for (final point in samples)
      if (point.dx >= xMin && point.dx <= xMax) point,
  ];
  final bucketCount = math.max(1, pixelWidth.floor());
  if (visible.length <= bucketCount * 2 || xMax <= xMin) return visible;

  final result = <Offset>[];
  var currentBucket = -1;
  Offset? minimum;
  Offset? maximum;
  var minimumIndex = 0;
  var maximumIndex = 0;
  var pointIndex = 0;

  void flushBucket() {
    final low = minimum;
    final high = maximum;
    if (low == null || high == null) return;
    if (minimumIndex <= maximumIndex) {
      _appendDistinctPoint(result, low);
      _appendDistinctPoint(result, high);
    } else {
      _appendDistinctPoint(result, high);
      _appendDistinctPoint(result, low);
    }
  }

  for (final point in visible) {
    final bucket = (((point.dx - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flushBucket();
      currentBucket = bucket;
      minimum = point;
      maximum = point;
      minimumIndex = pointIndex;
      maximumIndex = pointIndex;
    } else {
      if (point.dy < minimum!.dy) {
        minimum = point;
        minimumIndex = pointIndex;
      }
      if (point.dy > maximum!.dy) {
        maximum = point;
        maximumIndex = pointIndex;
      }
    }
    pointIndex += 1;
  }
  flushBucket();
  _appendDistinctPoint(result, visible.last);
  return result;
}

void _appendDistinctPoint(List<Offset> points, Offset point) {
  if (points.isEmpty || points.last != point) points.add(point);
}
