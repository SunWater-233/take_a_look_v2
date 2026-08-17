import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared mutable geometry for resizable data tables.
class ResizableTableLayout {
  ResizableTableLayout({
    required List<double> widths,
    required List<double> minimumWidths,
    required double rowHeight,
  }) : assert(widths.length == minimumWidths.length),
       _widths = List<double>.of(widths),
       minimumWidths = List<double>.unmodifiable(minimumWidths),
       _rowHeight = rowHeight;

  List<double> _widths;
  final List<double> minimumWidths;
  double _rowHeight;
  List<double>? _resizeWidths;
  double? _resizeRowHeight;

  List<double> get widths => _widths;
  double get rowHeight => _rowHeight;
  double get totalWidth => _widths.fold(0, (sum, width) => sum + width);

  void beginResize() {
    _resizeWidths = List<double>.of(_widths);
    _resizeRowHeight = _rowHeight;
  }

  bool resizeAll(
    Offset delta, {
    required double columnScale,
    required double rowScale,
    required double minimumRowHeight,
  }) {
    final widths = _resizeWidths;
    final rowHeight = _resizeRowHeight;
    if (widths == null || rowHeight == null) return false;
    final columnDelta = delta.dx * columnScale;
    _widths = [
      for (var index = 0; index < widths.length; index += 1)
        math.max(minimumWidths[index], widths[index] + columnDelta),
    ];
    _rowHeight = math.max(minimumRowHeight, rowHeight + delta.dy * rowScale);
    return true;
  }

  bool resizeColumn(int index, double delta) {
    if (index < 0 || index >= _widths.length) return false;
    final next = List<double>.of(_widths);
    next[index] = math.max(minimumWidths[index], next[index] + delta);
    _widths = next;
    return true;
  }
}
