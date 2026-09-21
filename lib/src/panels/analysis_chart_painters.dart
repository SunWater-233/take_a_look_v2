part of '../panels.dart';

class _AnalysisChartPainter extends CustomPainter {
  const _AnalysisChartPainter({
    required this.series,
    required this.seriesVisibility,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.invertX,
    required this.invertY,
  });

  final List<AnalysisSeries> series;
  final List<bool> seriesVisibility;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final bool invertX;
  final bool invertY;

  Iterable<AnalysisSeries> get visibleSeries sync* {
    for (final (index, item) in series.indexed) {
      if (index >= seriesVisibility.length || seriesVisibility[index]) {
        yield item;
      }
    }
  }

  int get visibleSeriesCount => visibleSeries.length;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _analysisPlotRect(size);
    final viewport = CartesianPlotViewport(
      plot: plot,
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      invertX: invertX,
      invertY: invertY,
    );
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: viewport,
    );
    renderer.drawBackground();
    if (plot.width <= 2 || plot.height <= 2) return;
    renderer.drawGrid();
    canvas.save();
    canvas.clipRect(plot);
    for (final item in visibleSeries) {
      renderer.drawPolyline(
        downsampleAnalysisPoints(
          item.points,
          xMin: xMin,
          xMax: xMax,
          pixelWidth: plot.width,
        ),
        item.color,
      );
    }
    canvas.restore();
    renderer.drawAxisLabels(
      yLabelOffset: 50,
      xTickOffset: 5,
      xAxisLabelOffset: 15,
    );
    renderer.drawLegend([
      for (final item in visibleSeries)
        CartesianLegendItem(label: item.name, color: item.color),
    ], wrap: true);
  }

  @override
  bool shouldRepaint(covariant _AnalysisChartPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.seriesVisibility != seriesVisibility ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.yMin != yMin ||
      oldDelegate.yMax != yMax ||
      oldDelegate.invertX != invertX ||
      oldDelegate.invertY != invertY;
}

class _AnalysisSelectionPainter extends CustomPainter {
  const _AnalysisSelectionPainter({
    required this.xMin,
    required this.xMax,
    required this.selectionStart,
    required this.selectionEnd,
    required this.invertX,
  });

  final double xMin;
  final double xMax;
  final double? selectionStart;
  final double? selectionEnd;
  final bool invertX;

  @override
  void paint(Canvas canvas, Size size) {
    final start = selectionStart;
    final end = selectionEnd;
    if (start == null || end == null) return;
    final plot = _analysisPlotRect(size);
    final span = math.max(1e-9, xMax - xMin);
    final startPosition =
        plot.left + (math.min(start, end) - xMin) / span * plot.width;
    final endPosition =
        plot.left + (math.max(start, end) - xMin) / span * plot.width;
    final left = invertX
        ? plot.right - (endPosition - plot.left)
        : startPosition;
    final right = invertX
        ? plot.right - (startPosition - plot.left)
        : endPosition;
    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRect(
      Rect.fromLTRB(left, plot.top, right, plot.bottom),
      Paint()..color = TalColors.accent.withAlpha(38),
    );
    final border = Paint()
      ..color = TalColors.accent
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(left, plot.top), Offset(left, plot.bottom), border);
    canvas.drawLine(
      Offset(right, plot.top),
      Offset(right, plot.bottom),
      border,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AnalysisSelectionPainter oldDelegate) =>
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.invertX != invertX ||
      oldDelegate.selectionStart != selectionStart ||
      oldDelegate.selectionEnd != selectionEnd;
}

class _AnalysisRectangleZoomPainter extends CustomPainter {
  const _AnalysisRectangleZoomPainter(this.rectangle);

  final Rect rectangle;

  @override
  void paint(Canvas canvas, Size size) {
    final clipped = rectangle.intersect(_analysisPlotRect(size));
    if (clipped.isEmpty) return;
    canvas.drawRect(clipped, Paint()..color = TalColors.accent.withAlpha(30));
    canvas.drawRect(
      clipped,
      Paint()
        ..color = TalColors.accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _AnalysisRectangleZoomPainter oldDelegate) =>
      oldDelegate.rectangle != rectangle;
}
