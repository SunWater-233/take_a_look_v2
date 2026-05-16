part of '../take_a_look_app.dart';

class ChartLegend extends StatelessWidget {
  const ChartLegend({required this.controller, super.key});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final plotted = controller.watches
            .where((watch) => watch.plotting)
            .toList();
        if (plotted.isEmpty) {
          return const SizedBox.shrink();
        }
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final watch in plotted.take(10))
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: TalColors.surface.withAlpha(210),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: TalColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: watch.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(watch.symbol.name, style: TalText.legend),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class TelemetryChartPainter extends CustomPainter {
  TelemetryChartPainter(this.controller) : super(repaint: controller);

  final TakeALookController controller;

  static const leftPad = 54.0;
  static const rightPad = 18.0;
  static const topPad = 52.0;
  static const bottomPad = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(1, size.width - leftPad - rightPad),
      math.max(1, size.height - topPad - bottomPad),
    );

    final backgroundPaint = Paint()..color = TalColors.plotBackground;
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    final borderPaint = Paint()
      ..color = TalColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(plot, borderPaint);

    final end = math.max(
      controller.elapsedSeconds,
      controller.visibleWindowSeconds,
    );
    final start = math.max(0.0, end - controller.visibleWindowSeconds);
    var yMin = double.infinity;
    var yMax = -double.infinity;

    final plotted = controller.watches
        .where((watch) => watch.plotting)
        .toList(growable: false);
    final maxPoints = math.max(300, (plot.width * 1.6).round()).toInt();
    final stride = math
        .max(
          1,
          ((controller.visibleWindowSeconds * controller.sampleRateHz) /
                  maxPoints)
              .floor(),
        )
        .toInt();

    for (final watch in plotted) {
      watch.series.forEachWindow(start, end, stride, (_, value) {
        yMin = math.min(yMin, value);
        yMax = math.max(yMax, value);
      });
    }
    if (!yMin.isFinite || !yMax.isFinite || (yMax - yMin).abs() < 0.0001) {
      yMin = -1;
      yMax = 1;
    } else {
      final pad = (yMax - yMin) * 0.12;
      yMin -= pad;
      yMax += pad;
    }

    if (controller.showGrid) {
      _drawGrid(canvas, plot, start, end, yMin, yMax);
    } else {
      _drawAxisLabels(canvas, plot, start, end, yMin, yMax);
    }

    final clipPath = Path()..addRect(plot.deflate(1));
    canvas.save();
    canvas.clipPath(clipPath);
    for (final watch in plotted) {
      _drawSeries(canvas, plot, watch, start, end, yMin, yMax, stride);
    }
    canvas.restore();
  }

  void _drawGrid(
    Canvas canvas,
    Rect plot,
    double start,
    double end,
    double yMin,
    double yMax,
  ) {
    final gridPaint = Paint()
      ..color = TalColors.grid
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = TalColors.border
      ..strokeWidth = 1;

    for (var i = 0; i <= 6; i += 1) {
      final x = plot.left + plot.width * i / 6;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
    }
    for (var i = 0; i <= 4; i += 1) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      axisPaint,
    );
    canvas.drawLine(
      Offset(plot.left, plot.top),
      Offset(plot.left, plot.bottom),
      axisPaint,
    );
    _drawAxisLabels(canvas, plot, start, end, yMin, yMax);
  }

  void _drawAxisLabels(
    Canvas canvas,
    Rect plot,
    double start,
    double end,
    double yMin,
    double yMax,
  ) {
    for (var i = 0; i <= 3; i += 1) {
      final value = yMax - (yMax - yMin) * i / 3;
      final y = plot.top + plot.height * i / 3;
      _drawText(
        canvas,
        value.abs() >= 1000
            ? value.toStringAsFixed(0)
            : value.toStringAsFixed(2),
        Offset(8, y - 8),
        TalColors.textMuted,
        align: TextAlign.right,
        width: leftPad - 12,
      );
    }
    for (var i = 0; i <= 3; i += 1) {
      final value = start + (end - start) * i / 3;
      final x = plot.left + plot.width * i / 3;
      _drawText(
        canvas,
        '${value.toStringAsFixed(value < 10 ? 2 : 1)}s',
        Offset(x - 24, plot.bottom + 9),
        TalColors.textMuted,
        width: 48,
        align: TextAlign.center,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    WatchVariable watch,
    double start,
    double end,
    double yMin,
    double yMax,
    int stride,
  ) {
    final path = Path();
    var started = false;
    final xScale = plot.width / math.max(0.001, end - start);
    final yScale = plot.height / math.max(0.001, yMax - yMin);

    watch.series.forEachWindow(start, end, stride, (time, value) {
      final x = plot.left + (time - start) * xScale;
      final y = plot.bottom - (value - yMin) * yScale;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    });
    if (!started) {
      return;
    }
    final shadow = Paint()
      ..color = watch.color.withAlpha(36)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final paint = Paint()
      ..color = watch.color
      ..strokeWidth = 1.7
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, shadow);
    canvas.drawPath(path, paint);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color, {
    double width = 80,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          letterSpacing: 0,
          fontFeatures: const [],
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TelemetryChartPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}
