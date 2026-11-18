import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../telemetry/plot_history.dart';
import '../theme/theme.dart';
import 'cartesian_renderer.dart';
import 'downsampling.dart';
import 'viewport.dart';

typedef _TimeRange = ({double start, double end});
typedef _OverviewSeries = ({Color color, List<Offset> points});

const _overviewHandleColor = Color(0xFFF4A567);
const _minimumSpan = 0.2;

enum _OverviewAction { seek, pan, startEdge, endEdge }

class PlotOverview extends StatefulWidget {
  const PlotOverview({
    required this.controller,
    required this.onOpenRange,
    super.key,
  });

  final TakeALookController controller;
  final void Function(Offset? position) onOpenRange;

  @override
  State<PlotOverview> createState() => _PlotOverviewState();
}

class _PlotOverviewState extends State<PlotOverview> {
  final _historyChanges = ValueNotifier(0);
  final _histories = <String, PlotHistory>{};
  final _historyEnds = <String, double>{};
  final _focus = FocusNode(debugLabel: 'Plot time overview');
  _OverviewDrag? _drag;
  _OverviewAction? _hoverAction;
  bool _showFocus = false;
  bool _dragging = false;
  TakeALookController get controller => widget.controller;

  @override
  void didUpdateWidget(PlotOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      _clearHistories();
      _drag = null;
      _dragging = false;
    }
  }

  void _clearHistories() {
    for (final history in _histories.values) {
      history.dispose();
    }
    _histories.clear();
    _historyEnds.clear();
  }

  @override
  void dispose() {
    _clearHistories();
    _historyChanges.dispose();
    _focus.dispose();
    super.dispose();
  }

  _TimeRange? get _dataRange {
    if (!controller.watches.any((watch) => watch.plotted)) return null;
    final range = controller.plotRecordedTimeRange;
    if (range == null) return null;
    final end = math.max(_minimumSpan, range.end);
    return (start: math.min(range.start, end - _minimumSpan), end: end);
  }

  Rect _track(Size size) => (Offset.zero & size).deflate(1);

  CartesianPlotViewport? _mapping(Size size) {
    final range = _dataRange;
    if (range == null || size.width <= 2 || size.height <= 2) return null;
    return CartesianPlotViewport(
      plot: _track(size),
      xMin: range.start,
      xMax: range.end,
      yMin: 0,
      yMax: 1,
    );
  }

  List<_OverviewSeries> _series(CartesianPlotViewport viewport) {
    final livePath = controller.rawRecording['historyPath'] as String?;
    final plotted = controller.watches.where((watch) => watch.plotted).toList();
    final byPath = <String, List<WatchItem>>{};
    for (final watch in plotted) {
      final path =
          watch.archivedHistoryPath ??
          (watch.totalSampleCount > watch.samples.length ? livePath : null);
      if (path != null) (byPath[path] ??= []).add(watch);
    }
    _histories.removeWhere((path, history) {
      if (byPath.containsKey(path)) return false;
      history.dispose();
      _historyEnds.remove(path);
      return true;
    });
    final cached = <String, PlotHistory>{};
    for (final entry in byPath.entries) {
      final path = entry.key;
      final watches = entry.value;
      final history = _histories.putIfAbsent(
        path,
        () => PlotHistory(onChanged: () => _historyChanges.value++),
      );
      final sourceEnd = path == livePath
          ? controller.elapsedSeconds
          : watches
                .map((watch) => watch.archivedHistoryEndSeconds)
                .reduce(math.max);
      final previousEnd = _historyEnds[path];
      // The recent buffer covers the tail while the indexed prefix is refreshed.
      final refreshInterval = (controller.plotRetentionSeconds / 2).clamp(
        0.5,
        12.0,
      );
      if (previousEnd == null ||
          sourceEnd < previousEnd ||
          sourceEnd - previousEnd >= refreshInterval) {
        if (previousEnd != null && sourceEnd < previousEnd) history.clear();
        _historyEnds[path] = sourceEnd;
      }
      final end = _historyEnds[path]!;
      history.update(
        path: path,
        keys: [for (final watch in watches) watch.symbol.key],
        start: 0,
        end: math.max(_minimumSpan, end),
        sourceEnd: end,
        pixelWidth: viewport.plot.width,
        enabled: true,
      );
      for (final watch in watches) {
        cached[watch.symbol.key] = history;
      }
    }
    return [
      for (final watch in plotted)
        (
          color: watch.color,
          points: _points(watch, cached[watch.symbol.key], viewport),
        ),
    ];
  }

  List<Offset> _points(
    WatchItem watch,
    PlotHistory? cache,
    CartesianPlotViewport viewport,
  ) {
    final recent = downsampleTelemetrySamples(
      watch.samples,
      xMin: viewport.xMin,
      xMax: viewport.xMax,
      pixelWidth: viewport.plot.width,
    );
    final history = cache?.samplesFor(
      watch.symbol.key,
      minimumTime: watch.historyStartSeconds,
    );
    if (history == null) return recent;
    final cutoff = recent.isEmpty ? viewport.xMax : recent.first.dx;
    if (cutoff < viewport.xMin) return recent;
    return [
      for (final point in downsampleTelemetrySamples(
        history,
        xMin: viewport.xMin,
        xMax: cutoff,
        pixelWidth: viewport.plot.width,
      ))
        if (recent.isEmpty || point.dx < cutoff) point,
      ...recent,
    ];
  }

  _OverviewAction _actionAt(PointerEvent event, CartesianPlotViewport mapping) {
    final window = telemetryTimeWindow(controller);
    final left = mapping.mapX(window.start.clamp(mapping.xMin, mapping.xMax));
    final right = mapping.mapX(window.end.clamp(mapping.xMin, mapping.xMax));
    if (right <= left) return _OverviewAction.seek;
    final hitSize = math.min(
      (right - left) / 3,
      event.kind == PointerDeviceKind.touch ? 12.0 : 8.0,
    );
    final x = event.localPosition.dx;
    if ((x - left).abs() <= hitSize) return _OverviewAction.startEdge;
    if ((x - right).abs() <= hitSize) return _OverviewAction.endEdge;
    return x > left && x < right ? _OverviewAction.pan : _OverviewAction.seek;
  }

  void _onDown(PointerDownEvent event, Size size) {
    if (event.buttons & kSecondaryButton != 0) {
      widget.onOpenRange(event.position);
      return;
    }
    if (event.buttons & kPrimaryButton == 0 || _drag != null) return;
    final mapping = _mapping(size);
    if (mapping == null) return;
    _drag = _OverviewDrag(
      event.pointer,
      event.localPosition.dx,
      _actionAt(event, mapping),
      mapping,
      telemetryTimeWindow(controller),
    );
  }

  void _onMove(PointerMoveEvent event) {
    final drag = _drag;
    if (drag == null || event.pointer != drag.pointer) return;
    if (!_dragging && (event.localPosition.dx - drag.origin).abs() <= 3) return;
    if (!_dragging) setState(() => _dragging = true);
    _updateRange(drag, event.localPosition.dx);
  }

  void _onUp(PointerUpEvent event) {
    final drag = _drag;
    if (drag == null || event.pointer != drag.pointer) return;
    if (_dragging || drag.action == _OverviewAction.seek) {
      _updateRange(drag, event.localPosition.dx);
    }
    _endDrag(event.pointer);
  }

  void _endDrag(int pointer) {
    if (_drag?.pointer != pointer) return;
    _drag = null;
    if (_dragging) setState(() => _dragging = false);
  }

  void _updateRange(_OverviewDrag drag, double position) {
    final mapping = drag.mapping;
    final window = drag.window;
    final span = window.end - window.start;
    final time = mapping.unmapX(position);
    final minimum = mapping.xMin;
    final maximum = mapping.xMax;
    final shift = (position - drag.origin) / mapping.plot.width * mapping.xSpan;
    final left = window.start.clamp(
      minimum,
      math.max(minimum, maximum - _minimumSpan),
    );
    final right = window.end.clamp(
      math.min(maximum, minimum + _minimumSpan),
      maximum,
    );
    final (start, end) = switch (drag.action) {
      _OverviewAction.seek => clampCartesianWindow(
        time - span / 2,
        time + span / 2,
        minimum,
        maximum,
      ),
      _OverviewAction.pan => clampCartesianWindow(
        window.start + shift,
        window.end + shift,
        minimum,
        maximum,
      ),
      _OverviewAction.startEdge => (
        time.clamp(minimum, math.max(minimum, right - _minimumSpan)),
        right,
      ),
      _OverviewAction.endEdge => (
        left,
        time.clamp(math.min(maximum, left + _minimumSpan), maximum),
      ),
    };
    _applyWindow(start.toDouble(), end.toDouble());
  }

  void _applyWindow(double start, double end) {
    final current = telemetryTimeWindow(controller);
    if ((current.start - start).abs() < 1e-9 &&
        (current.end - end).abs() < 1e-9) {
      return;
    }
    controller.configurePlotView({
      'followLatest': false,
      'xMin': start,
      'xMax': end,
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) widget.onOpenRange(null);
      return KeyEventResult.handled;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    final range = _dataRange;
    if (direction == 0 || range == null) return KeyEventResult.ignored;
    final window = telemetryTimeWindow(controller);
    final delta = direction * (window.end - window.start) / 8;
    final (start, end) = clampCartesianWindow(
      window.start + delta,
      window.end + delta,
      range.start,
      range.end,
    );
    _applyWindow(start, end);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Focus(
          canRequestFocus: false,
          onKeyEvent: _onKey,
          child: FocusableActionDetector(
            focusNode: _focus,
            onShowFocusHighlight: (value) => setState(() => _showFocus = value),
            child: Semantics(
              button: true,
              label: '记录缩略图',
              hint: '拖动时间窗或两端调节范围。按 Enter 设置精确范围。',
              onTap: () => widget.onOpenRange(null),
              child: MouseRegion(
                onHover: (event) {
                  final mapping = _mapping(size);
                  final action = mapping == null
                      ? null
                      : _actionAt(event, mapping);
                  if (action != _hoverAction) {
                    setState(() => _hoverAction = action);
                  }
                },
                cursor: switch (_drag?.action ?? _hoverAction) {
                  _OverviewAction.pan =>
                    _dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab,
                  _OverviewAction.startEdge ||
                  _OverviewAction.endEdge => SystemMouseCursors.resizeLeftRight,
                  _OverviewAction.seek => SystemMouseCursors.precise,
                  null => SystemMouseCursors.basic,
                },
                child: Listener(
                  key: const ValueKey('plot-overview'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => _onDown(event, size),
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: (event) => _endDrag(event.pointer),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _PlotOverviewPainter(
                        mapping: _mapping,
                        series: _series,
                        window: () => telemetryTimeWindow(controller),
                        focused: _showFocus,
                        showRange: _dragging,
                        repaint: Listenable.merge([
                          controller.telemetryChanges,
                          controller.plotChanges,
                          controller.watchChanges,
                          controller.samplingChanges,
                          _historyChanges,
                        ]),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OverviewDrag {
  const _OverviewDrag(
    this.pointer,
    this.origin,
    this.action,
    this.mapping,
    this.window,
  );
  final int pointer;
  final double origin;
  final _OverviewAction action;
  final CartesianPlotViewport mapping;
  final _TimeRange window;
}

class _PlotOverviewPainter extends CustomPainter {
  _PlotOverviewPainter({
    required this.mapping,
    required this.series,
    required this.window,
    required this.focused,
    required this.showRange,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final CartesianPlotViewport? Function(Size) mapping;
  final List<_OverviewSeries> Function(CartesianPlotViewport) series;
  final _TimeRange Function() window;
  final bool focused;
  final bool showRange;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      const Radius.circular(4),
    );
    canvas.drawRRect(outline, Paint()..color = TalColors.input);
    final track = mapping(size);
    if (track != null) {
      final record = series(track);
      final visible = window();
      final box = Rect.fromLTRB(
        track.mapX(visible.start.clamp(track.xMin, track.xMax)),
        track.plot.top,
        track.mapX(visible.end.clamp(track.xMin, track.xMax)),
        track.plot.bottom,
      );
      canvas.save();
      canvas.clipRRect(outline);
      if (box.width > 0) {
        canvas.drawRect(
          box,
          Paint()..color = _overviewHandleColor.withValues(alpha: 0.14),
        );
      }
      if (showRange && size.width > 100) {
        final label = TextPainter(
          text: TextSpan(
            text:
                '${visible.start.toStringAsFixed(3)}–${visible.end.toStringAsFixed(3)} s',
            style: talMono.copyWith(fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final halfWidth = label.width / 2 + 5;
        if (halfWidth * 2 < size.width - 2) {
          final center = box.center.dx.clamp(
            halfWidth + 1,
            size.width - halfWidth - 1,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(center, box.center.dy),
                width: halfWidth * 2,
                height: label.height + 6,
              ),
              const Radius.circular(3),
            ),
            Paint()..color = TalColors.surfaceAlt,
          );
          label.paint(
            canvas,
            Offset(center - label.width / 2, box.center.dy - label.height / 2),
          );
        }
        label.dispose();
      }
      _drawSeries(canvas, size, track, record, box);
      if (box.width > 0) {
        canvas.drawRect(
          box,
          Paint()
            ..color = _overviewHandleColor.withValues(alpha: 0.76)
            ..style = PaintingStyle.stroke,
        );
        for (final x in [box.left, box.right]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(x.clamp(3, size.width - 3), box.center.dy),
                width: 5,
                height: 14,
              ),
              const Radius.circular(1.5),
            ),
            Paint()..color = _overviewHandleColor,
          );
        }
      }
      canvas.restore();
    }
    canvas.drawRRect(
      outline,
      Paint()
        ..color = focused ? TalColors.accent : TalColors.border
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawSeries(
    Canvas canvas,
    Size size,
    CartesianPlotViewport track,
    List<_OverviewSeries> record,
    Rect box,
  ) {
    var low = double.infinity, high = double.negativeInfinity;
    for (final entry in record) {
      for (final point in entry.points) {
        if (!point.isFinite) continue;
        low = math.min(low, point.dy);
        high = math.max(high, point.dy);
      }
    }
    if (!low.isFinite) return;
    final pad = math.max(1e-9, (high - low) * 0.12);
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: CartesianPlotViewport(
        plot: track.plot,
        xMin: track.xMin,
        xMax: track.xMax,
        yMin: low - pad,
        yMax: high + pad,
      ),
    );
    for (final entry in record) {
      renderer.drawPolyline(
        entry.points,
        entry.color.withValues(alpha: 0.45),
        strokeWidth: 1,
      );
    }
    if (box.width <= 0) return;
    canvas.save();
    canvas.clipRect(box);
    for (final entry in record) {
      renderer.drawPolyline(entry.points, entry.color, strokeWidth: 1);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlotOverviewPainter oldDelegate) => true;
}
