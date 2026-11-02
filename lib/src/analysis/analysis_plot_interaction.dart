import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';

import '../chart/cartesian_renderer.dart';
import 'analysis.dart';

enum AnalysisSelectionDragTarget { newRange, lowerBound, upperBound }

/// Owns analysis plot gestures and viewport transitions without a widget tree.
class AnalysisPlotInteraction {
  AnalysisPlotInteraction({
    required this.session,
    required this.onChanged,
    required this.onSelectionChanged,
    required this.onCommit,
  });

  final AnalysisSession Function() session;
  final VoidCallback onChanged;
  final VoidCallback onSelectionChanged;
  final VoidCallback onCommit;
  static const selectionHandleHitSlop = 12.0;

  static Rect plotRect(Size size) => Rect.fromLTRB(
    54,
    12,
    math.max(55, size.width - 14),
    math.max(13, size.height - 32),
  );
  AnalysisSession get _session => session();
  List<AnalysisSeries> get _series => _session.series;
  (double, double)? get _selectedRange => _session.selectedRange;
  Rect? get rectangleZoom => _rectangleZoom;
  bool get middleDragging => _middleDragging;
  bool get rightZoomDragging => _rightZoomDragging;

  void cancelRectangleZoom() {
    _rectangleZoom = null;
    _rectangleZoomStart = null;
  }

  double? _dragStartX;
  Offset? _lastPanPosition;
  Offset? _lastRightZoomPosition;
  Offset? _rightZoomStartPosition;
  Offset? _rightZoomAnchorFraction;
  Rect? _rectangleZoom;
  Offset? _rectangleZoomStart;
  bool _rightZoomMoved = false;
  bool _selectionDragging = false;
  AnalysisSelectionDragTarget? _selectionDragTarget;
  bool _middleDragging = false;
  bool _rightZoomDragging = false;
  double? get _selectionStart => _session.selectionStart;
  set _selectionStart(double? value) => _session.selectionStart = value;
  double? get _selectionEnd => _session.selectionEnd;
  set _selectionEnd(double? value) => _session.selectionEnd = value;
  double? get _viewXMin => _session.viewXMin;
  set _viewXMin(double? value) => _session.viewXMin = value;
  double? get _viewXMax => _session.viewXMax;
  set _viewXMax(double? value) => _session.viewXMax = value;
  double? get _viewYMin => _session.viewYMin;
  set _viewYMin(double? value) => _session.viewYMin = value;
  double? get _viewYMax => _session.viewYMax;
  set _viewYMax(double? value) => _session.viewYMax = value;
  AnalysisMouseMode get _mouseMode => _session.mouseMode;
  bool get _mouseXEnabled => _session.mouseXEnabled;
  bool get _mouseYEnabled => _session.mouseYEnabled;
  bool get _invertX => _session.invertX;
  bool get _invertY => _session.invertY;
  bool get resizingSelectionBoundary =>
      _selectionDragTarget == AnalysisSelectionDragTarget.lowerBound ||
      _selectionDragTarget == AnalysisSelectionDragTarget.upperBound;

  void handlePointerDown(PointerDownEvent event, Size size) {
    if (event.kind != PointerDeviceKind.mouse ||
        !plotRect(size).contains(event.localPosition)) {
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) {
      final plot = plotRect(size);
      _rightZoomDragging = true;
      _lastRightZoomPosition = event.localPosition;
      _rightZoomStartPosition = event.localPosition;
      _rightZoomMoved = false;
      _rightZoomAnchorFraction = Offset(
        _xFractionForPosition(event.localPosition.dx, plot),
        _yFractionForPosition(event.localPosition.dy, plot),
      );
      _notifyChartChanged();
      return;
    }
    if (event.buttons & kMiddleMouseButton != 0) {
      _middleDragging = true;
      _lastPanPosition = event.localPosition;
      _notifyChartChanged();
      return;
    }
    if (event.buttons & kPrimaryMouseButton != 0) {
      if (_mouseMode == AnalysisMouseMode.rectangle) {
        _rectangleZoomStart = event.localPosition;
        _rectangleZoom = Rect.fromPoints(
          event.localPosition,
          event.localPosition,
        );
        _notifyChartChanged();
        return;
      }
      _startSelection(event.localPosition.dx, size);
    }
  }

  void handlePointerMove(PointerMoveEvent event, Size size) {
    if (_rightZoomDragging && event.buttons & kSecondaryMouseButton != 0) {
      final start = _rightZoomStartPosition;
      if (start != null && (event.localPosition - start).distanceSquared > 9) {
        _rightZoomMoved = true;
      }
      _updateRightButtonZoom(event.localPosition);
      return;
    }
    final rectangleStart = _rectangleZoomStart;
    if (rectangleStart != null && event.buttons & kPrimaryMouseButton != 0) {
      _rectangleZoom = Rect.fromPoints(rectangleStart, event.localPosition);
      _notifyChartChanged();
      return;
    }
    if (_selectionDragging && event.buttons & kPrimaryMouseButton != 0) {
      _updateSelection(event.localPosition.dx, size);
      return;
    }
    final previous = _lastPanPosition;
    if (!_middleDragging ||
        previous == null ||
        event.buttons & kMiddleMouseButton == 0) {
      return;
    }
    final plot = plotRect(size);
    if (plot.width <= 1 || plot.height <= 1) return;
    final bounds = viewportBounds;
    final data = _dataBounds;
    final delta = event.localPosition - previous;
    final xSpan = bounds.$2 - bounds.$1;
    final ySpan = bounds.$4 - bounds.$3;
    final xShift = (_invertX ? 1 : -1) * delta.dx / plot.width * xSpan;
    final yShift = (_invertY ? -1 : 1) * delta.dy / plot.height * ySpan;
    final xWindow = _mouseXEnabled
        ? clampCartesianWindow(
            bounds.$1 + xShift,
            bounds.$2 + xShift,
            data.$1,
            data.$2,
          )
        : (bounds.$1, bounds.$2);
    final yWindow = _mouseYEnabled
        ? clampCartesianWindow(
            bounds.$3 + yShift,
            bounds.$4 + yShift,
            data.$3,
            data.$4,
          )
        : (bounds.$3, bounds.$4);
    _lastPanPosition = event.localPosition;
    _viewXMin = xWindow.$1;
    _viewXMax = xWindow.$2;
    _viewYMin = yWindow.$1;
    _viewYMax = yWindow.$2;
    _notifyChartChanged();
  }

  void _updateRightButtonZoom(Offset position) {
    final previous = _lastRightZoomPosition;
    final anchor = _rightZoomAnchorFraction;
    if (previous == null || anchor == null) return;
    final delta = position - previous;
    if (delta == Offset.zero) return;
    final bounds = viewportBounds;
    final data = _dataBounds;
    final xScale = math.pow(1.02, -delta.dx).toDouble();
    final yScale = math.pow(1.02, delta.dy).toDouble();
    final xWindow = _mouseXEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$1,
            maximum: bounds.$2,
            dataMinimum: data.$1,
            dataMaximum: data.$2,
            anchorFraction: anchor.dx,
            scale: xScale,
          )
        : (bounds.$1, bounds.$2);
    final yWindow = _mouseYEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$3,
            maximum: bounds.$4,
            dataMinimum: data.$3,
            dataMaximum: data.$4,
            anchorFraction: anchor.dy,
            scale: yScale,
          )
        : (bounds.$3, bounds.$4);
    _lastRightZoomPosition = position;
    _viewXMin = xWindow.$1;
    _viewXMax = xWindow.$2;
    _viewYMin = yWindow.$1;
    _viewYMax = yWindow.$2;
    _notifyChartChanged();
  }

  void handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    final plot = plotRect(size);
    if (!plot.contains(event.localPosition)) return;
    final bounds = viewportBounds;
    final data = _dataBounds;
    final scale = event.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
    final xFraction = _xFractionForPosition(event.localPosition.dx, plot);
    final yFraction = _yFractionForPosition(event.localPosition.dy, plot);
    final xWindow = _mouseXEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$1,
            maximum: bounds.$2,
            dataMinimum: data.$1,
            dataMaximum: data.$2,
            anchorFraction: xFraction,
            scale: scale,
          )
        : (bounds.$1, bounds.$2);
    final yWindow = _mouseYEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$3,
            maximum: bounds.$4,
            dataMinimum: data.$3,
            dataMaximum: data.$4,
            anchorFraction: yFraction,
            scale: scale,
          )
        : (bounds.$3, bounds.$4);
    _viewXMin = xWindow.$1;
    _viewXMax = xWindow.$2;
    _viewYMin = yWindow.$1;
    _viewYMax = yWindow.$2;
    _notifyChartChanged();
    onCommit();
  }

  bool finishPointerInteraction(Size size, PointerUpEvent? event) {
    final wasSelecting = _selectionDragging;
    final rectangle = _rectangleZoom;
    final openMenu =
        event != null &&
        _rightZoomDragging &&
        !_rightZoomMoved &&
        event.kind == PointerDeviceKind.mouse;
    _selectionDragging = false;
    _middleDragging = false;
    _rightZoomDragging = false;
    _lastPanPosition = null;
    _lastRightZoomPosition = null;
    _rightZoomStartPosition = null;
    _rightZoomAnchorFraction = null;
    _rightZoomMoved = false;
    _rectangleZoom = null;
    _rectangleZoomStart = null;
    if (wasSelecting) {
      _finishSelection();
    } else if (rectangle != null) {
      _applyRectangleZoom(rectangle, size);
    } else {
      _notifyChartChanged();
    }
    onCommit();
    return openMenu;
  }

  void _startSelection(double position, Size size) {
    if (_series.isEmpty || size.width <= 0) return;
    final range = _selectedRange;
    final target = _selectionTargetAt(position, size, range);
    _selectionDragging = true;
    if (range != null && target != null) {
      _selectionDragTarget = target;
      _dragStartX = null;
      _selectionStart = range.$1;
      _selectionEnd = range.$2;
      _notifyChartChanged();
      return;
    }
    _selectionDragTarget = AnalysisSelectionDragTarget.newRange;
    _dragStartX = _xForPosition(position, size);
    _selectionStart = _dragStartX;
    _selectionEnd = _dragStartX;
    _notifyChartChanged();
  }

  void _updateSelection(double position, Size size) {
    if (size.width <= 0) return;
    final value = _xForPosition(position, size);
    switch (_selectionDragTarget) {
      case AnalysisSelectionDragTarget.newRange:
        if (_dragStartX == null) return;
        _selectionEnd = value;
      case AnalysisSelectionDragTarget.lowerBound:
        final upper = _selectionEnd;
        if (upper == null) return;
        _selectionStart = math.min(value, upper);
      case AnalysisSelectionDragTarget.upperBound:
        final lower = _selectionStart;
        if (lower == null) return;
        _selectionEnd = math.max(value, lower);
      case null:
        return;
    }
    _notifyChartChanged();
  }

  void _finishSelection() {
    _dragStartX = null;
    _selectionDragTarget = null;
    if (_selectionStart == null || _selectionEnd == null) return;
    if ((_selectionStart! - _selectionEnd!).abs() < 1e-9) {
      _selectionStart = null;
      _selectionEnd = null;
      _session.selectionStats = const [];
    } else {
      final lower = math.min(_selectionStart!, _selectionEnd!);
      final upper = math.max(_selectionStart!, _selectionEnd!);
      _selectionStart = lower;
      _selectionEnd = upper;
      _session.updateSelectionStats();
    }
    _notifyChartChanged();
    onSelectionChanged();
  }

  AnalysisSelectionDragTarget? _selectionTargetAt(
    double position,
    Size size,
    (double, double)? range,
  ) {
    if (range == null) return null;
    final viewport = _interactionViewport(plotRect(size));
    final lowerDistance = (position - viewport.mapX(range.$1)).abs();
    final upperDistance = (position - viewport.mapX(range.$2)).abs();
    if (math.min(lowerDistance, upperDistance) > selectionHandleHitSlop) {
      return null;
    }
    return lowerDistance <= upperDistance
        ? AnalysisSelectionDragTarget.lowerBound
        : AnalysisSelectionDragTarget.upperBound;
  }

  void _notifyChartChanged() => onChanged();

  double _xForPosition(double position, Size size) {
    return _interactionViewport(plotRect(size)).unmapX(position);
  }

  double _yForPosition(double position, Size size) {
    return _interactionViewport(plotRect(size)).unmapY(position);
  }

  double _xFractionForPosition(double position, Rect plot) {
    return _interactionViewport(plot).xFractionAt(position);
  }

  double _yFractionForPosition(double position, Rect plot) {
    return _interactionViewport(plot).yFractionAt(position);
  }

  CartesianPlotViewport _interactionViewport(Rect plot) {
    final bounds = viewportBounds;
    return CartesianPlotViewport(
      plot: plot,
      xMin: bounds.$1,
      xMax: bounds.$2,
      yMin: bounds.$3,
      yMax: bounds.$4,
      invertX: _invertX,
      invertY: _invertY,
    );
  }

  void _applyRectangleZoom(Rect rectangle, Size size) {
    final plot = plotRect(size);
    final clipped = rectangle.intersect(plot);
    if (clipped.width < 5 || clipped.height < 5) {
      _notifyChartChanged();
      return;
    }
    final left = _xForPosition(clipped.left, size);
    final right = _xForPosition(clipped.right, size);
    final top = _yForPosition(clipped.top, size);
    final bottom = _yForPosition(clipped.bottom, size);
    if (_mouseXEnabled) {
      _viewXMin = math.min(left, right);
      _viewXMax = math.max(left, right);
    }
    if (_mouseYEnabled) {
      _viewYMin = math.min(top, bottom);
      _viewYMax = math.max(top, bottom);
    }
    _notifyChartChanged();
  }

  (double, double, double, double) get viewportBounds {
    final data = _dataBounds;
    return (
      _viewXMin ?? data.$1,
      _viewXMax ?? data.$2,
      _viewYMin ?? data.$3,
      _viewYMax ?? data.$4,
    );
  }

  (double, double, double, double) get _dataBounds => _session.dataBounds;

  void resetViewport() {
    _viewXMin = null;
    _viewXMax = null;
    _viewYMin = null;
    _viewYMax = null;
    _dragStartX = null;
    _lastPanPosition = null;
    _lastRightZoomPosition = null;
    _rightZoomStartPosition = null;
    _rightZoomAnchorFraction = null;
    _rightZoomMoved = false;
    _rectangleZoom = null;
    _rectangleZoomStart = null;
    _selectionDragging = false;
    _selectionDragTarget = null;
    _middleDragging = false;
    _rightZoomDragging = false;
  }
}
