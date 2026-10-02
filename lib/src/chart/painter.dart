import 'package:flutter/material.dart';

import '../controller/controller.dart';
import 'cartesian_renderer.dart';
import 'downsampling.dart';
import 'viewport.dart';

class TelemetryPainter extends CustomPainter {
  TelemetryPainter(this.controller) : super(repaint: controller.plotChanges);

  final TakeALookController controller;

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

    final plotted = controller.watches.where((item) => item.plotted).toList();
    if (plotted.isNotEmpty) {
      canvas.save();
      canvas.clipRect(viewport.plot);
      for (final watch in plotted) {
        renderer.drawPolyline(
          downsampleTelemetrySamples(
            controller.plotSamplesFor(watch),
            xMin: viewport.xMin,
            xMax: viewport.xMax,
            pixelWidth: viewport.plot.width,
          ),
          watch.color,
        );
      }
      canvas.restore();
    }

    renderer.drawAxisLabels(yLabelOffset: 42);
    if (controller.plotShowLegend) {
      renderer.drawLegend([
        for (final watch in plotted)
          CartesianLegendItem(label: watch.symbol.name, color: watch.color),
      ], maximumItems: 6);
    }
  }

  @override
  bool shouldRepaint(covariant TelemetryPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}
