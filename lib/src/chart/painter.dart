import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../theme/theme.dart';
import 'cartesian_renderer.dart';
import 'hover.dart';
import 'viewport.dart';

class TelemetryPainter extends CustomPainter {
  TelemetryPainter(
    this.controller, {
    this.hoverPosition,
    this.paintInspection = true,
  }) : super(
         repaint: Listenable.merge([
           controller.plotChanges,
           if (paintInspection) hoverPosition,
         ]),
       );

  final TakeALookController controller;
  final ValueListenable<Offset?>? hoverPosition;
  final bool paintInspection;

  @override
  void paint(Canvas canvas, Size size) {
    final telemetry = telemetryViewport(controller, size);
    final viewport = CartesianPlotViewport(
      plot: telemetry.plot,
      xMin: telemetry.xMin,
      xMax: telemetry.xMax,
      yMin: telemetry.yMin,
      yMax: telemetry.yMax,
      invertX: controller.plotInvertX,
      invertY: controller.plotInvertY,
    );
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: viewport,
    );
    renderer.drawBackground();
    if (viewport.plot.width <= 1 || viewport.plot.height <= 1) return;
    renderer.drawGrid(visible: controller.plotShowGrid);
    renderer.drawTitle('变量实时趋势');

    final plotted = telemetryPlotSeries(controller, viewport);
    final pointer = hoverPosition?.value;
    final hovered = !paintInspection
        ? null
        : inspectTelemetrySeries(
            plotted,
            viewport,
            position: pointer,
            highlightedWatchKey: controller.plotHighlightedWatchKey,
          );
    if (plotted.isNotEmpty) {
      canvas.save();
      canvas.clipRect(viewport.plot);
      for (final series in plotted) {
        renderer.drawPolyline(series.points, series.watch.color);
      }
      if (hovered != null) {
        _drawHighlightedSeries(canvas, renderer, hovered);
      }
      canvas.restore();
    }

    if (paintInspection) _drawChrome(canvas, viewport, plotted, renderer);
    if (hovered != null) {
      _drawHoverTooltip(canvas, size, pointer ?? hovered.position, hovered);
    }
  }

  void _drawChrome(
    Canvas canvas,
    CartesianPlotViewport viewport,
    List<TelemetryPlotSeries> plotted,
    CartesianChartRenderer renderer,
  ) {
    final retained = plotted.where((series) => series.samples.isNotEmpty);
    if (retained.isNotEmpty &&
        retained.any(
          (series) => series.watch.totalSampleCount > series.samples.length,
        )) {
      final earliest = retained
          .map((series) => series.samples.first.dx)
          .reduce(math.min);
      if (viewport.xMin < earliest - 0.001) {
        final notice = TextPainter(
          text: TextSpan(
            text: '绘图历史从 ${earliest.toStringAsFixed(2)} s 开始；更早记录请导出原始 CSV',
            style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 12),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.max(1, viewport.plot.width - 16));
        notice.paint(
          canvas,
          Offset(viewport.plot.left + 8, viewport.plot.bottom - 22),
        );
        notice.dispose();
      }
    }

    renderer.drawAxisLabels(yLabelOffset: 42);
    if (controller.plotShowLegend) {
      renderer.drawLegend([
        for (final series in plotted)
          CartesianLegendItem(
            label: series.watch.symbol.name,
            color: series.watch.color,
          ),
      ], maximumItems: 6);
    }
  }

  void _drawHighlightedSeries(
    Canvas canvas,
    CartesianChartRenderer renderer,
    TelemetryHoverHit hovered,
  ) {
    final series = hovered.series;
    renderer.drawPolyline(
      series.points,
      series.watch.color.withValues(alpha: 0.25),
      strokeWidth: 7,
    );
    renderer.drawPolyline(
      series.points,
      Color.lerp(series.watch.color, Colors.white, 0.3)!,
      strokeWidth: 3.4,
    );
    canvas.drawCircle(hovered.position, 4, Paint()..color = series.watch.color);
    canvas.drawCircle(
      hovered.position,
      4,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawHoverTooltip(
    Canvas canvas,
    Size size,
    Offset pointer,
    TelemetryHoverHit hovered,
  ) {
    final maxWidth = math.max(1.0, math.min(280.0, size.width - 36));
    final title = TextPainter(
      text: TextSpan(text: hovered.series.watch.symbol.name, style: talStrong),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final values = TextPainter(
      text: TextSpan(text: hovered.valueText, style: talMono),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final width = math.max(title.width, values.width) + 20;
    final height = title.height + values.height + 20;
    var left = pointer.dx + 14;
    var top = pointer.dy + 14;
    if (left + width > size.width - 8) left = pointer.dx - width - 14;
    if (top + height > size.height - 8) top = pointer.dy - height - 14;
    left = left.clamp(8.0, math.max(8.0, size.width - width - 8));
    top = top.clamp(8.0, math.max(8.0, size.height - height - 8));
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, width, height),
      const Radius.circular(6),
    );
    canvas.drawRRect(box, Paint()..color = TalColors.surfaceAlt);
    canvas.drawRRect(
      box,
      Paint()
        ..color = hovered.series.watch.color
        ..style = PaintingStyle.stroke,
    );
    title.paint(canvas, Offset(left + 10, top + 8));
    values.paint(canvas, Offset(left + 10, top + 12 + title.height));
    title.dispose();
    values.dispose();
  }

  @override
  bool shouldRepaint(covariant TelemetryPainter oldDelegate) {
    return oldDelegate.controller != controller ||
        oldDelegate.hoverPosition != hoverPosition ||
        oldDelegate.paintInspection != paintInspection;
  }
}

class TelemetryInspectionPainter extends CustomPainter {
  TelemetryInspectionPainter(this.controller, {required this.hoverPosition})
    : super(repaint: Listenable.merge([controller.plotChanges, hoverPosition]));

  final TakeALookController controller;
  final ValueListenable<Offset?> hoverPosition;

  @override
  void paint(Canvas canvas, Size size) {
    final telemetry = telemetryViewport(controller, size);
    final viewport = CartesianPlotViewport(
      plot: telemetry.plot,
      xMin: telemetry.xMin,
      xMax: telemetry.xMax,
      yMin: telemetry.yMin,
      yMax: telemetry.yMax,
      invertX: controller.plotInvertX,
      invertY: controller.plotInvertY,
    );
    if (viewport.plot.width <= 1 || viewport.plot.height <= 1) return;
    final pointer = hoverPosition.value;
    final plotted = telemetryPlotSeries(controller, viewport);
    final hit = inspectTelemetrySeries(
      plotted,
      viewport,
      position: pointer,
      highlightedWatchKey: controller.plotHighlightedWatchKey,
    );
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: viewport,
    );
    final delegate = TelemetryPainter(controller);
    if (hit != null) {
      canvas.save();
      canvas.clipRect(viewport.plot);
      delegate._drawHighlightedSeries(canvas, renderer, hit);
      canvas.restore();
    }
    delegate._drawChrome(canvas, viewport, plotted, renderer);
    if (hit != null) {
      delegate._drawHoverTooltip(canvas, size, pointer ?? hit.position, hit);
    }
  }

  @override
  bool shouldRepaint(covariant TelemetryInspectionPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.hoverPosition != hoverPosition;
}
