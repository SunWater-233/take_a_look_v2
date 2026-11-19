import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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
typedef _OverviewFrame = ({
  Size size,
  CartesianPlotViewport? viewport,
  List<_OverviewSeries> series,
});

const _overviewHandleColor = Color(0xFFF4A567);
const _minimumSpan = 0.2;
const _liveRefreshInterval = Duration(milliseconds: 100);

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
  final _repaint = ValueNotifier(0);
  late PlotHistoryQuery _history;
  double? _historyEnd;
  final _focus = FocusNode(debugLabel: 'Plot time overview');
  Timer? _liveRefresh;
  _OverviewFrame? _frame;
  late _TimeRange _paintedWindow;
  late double _retentionSeconds;
  bool _dataDirty = true;
  _OverviewDrag? _drag;
  _OverviewAction? _hoverAction;
  bool _showFocus = false;
  bool _dragging = false;
  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _history = controller.createPlotHistoryQuery(onChanged: _refreshData);
    _listenTo(controller);
  }

  @override
  void didUpdateWidget(PlotOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      _stopListeningTo(oldWidget.controller);
      _history.dispose();
      _history = controller.createPlotHistoryQuery(onChanged: _refreshData);
      _historyEnd = null;
      _frame = null;
      _drag = null;
      _dragging = false;
      _hoverAction = null;
      _listenTo(controller);
      _refreshData();
    }
  }

  void _listenTo(TakeALookController source) {
    _retentionSeconds = source.plotRetentionSeconds;
    source.telemetryChanges.addListener(_scheduleLiveRefresh);
    source.watchChanges.addListener(_refreshData);
    source.samplingChanges.addListener(_refreshData);
    source.plotControlChanges.addListener(_refreshWindow);
  }

  void _stopListeningTo(TakeALookController source) {
    source.telemetryChanges.removeListener(_scheduleLiveRefresh);
    source.watchChanges.removeListener(_refreshData);
    source.samplingChanges.removeListener(_refreshData);
    source.plotControlChanges.removeListener(_refreshWindow);
    _liveRefresh?.cancel();
    _liveRefresh = null;
  }

  void _scheduleLiveRefresh() {
    // Coalesce telemetry into an overview frame even if sampling then stops.
    _liveRefresh ??= Timer(_liveRefreshInterval, _refreshData);
  }

  void _refreshData() {
    _liveRefresh?.cancel();
    _liveRefresh = null;
    _retentionSeconds = controller.plotRetentionSeconds;
    _dataDirty = true;
    _repaint.value++;
  }

  void _refreshWindow() {
    if (_retentionSeconds != controller.plotRetentionSeconds) {
      _refreshData();
    } else {
      _repaint.value++;
    }
  }

  @override
  void dispose() {
    _stopListeningTo(controller);
    _history.dispose();
    _repaint.dispose();
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

  _OverviewFrame _frameFor(Size size) {
    final cached = _frame;
    if (!_dataDirty && cached != null && cached.size == size) return cached;
    _dataDirty = false;
    final range = _dataRange;
    if (range == null || size.width <= 2 || size.height <= 2) {
      if (range == null) {
        _history.clear();
        _historyEnd = null;
      }
      return _frame = (size: size, viewport: null, series: const []);
    }
    final plot = (Offset.zero & size).deflate(1);
    // A two-pixel bucket still shows both extrema in this compact preview.
    final series = _series(range, plot.width / 2);
    var low = double.infinity, high = double.negativeInfinity;
    for (final entry in series) {
      for (final point in entry.points) {
        if (!point.isFinite) continue;
        low = math.min(low, point.dy);
        high = math.max(high, point.dy);
      }
    }
    final pad = math.max(1e-9, (high - low) * 0.12);
    final viewport = CartesianPlotViewport(
      plot: plot,
      xMin: range.start,
      xMax: range.end,
      yMin: low.isFinite ? low - pad : 0,
      yMax: high.isFinite ? high + pad : 1,
    );
    return _frame = (size: size, viewport: viewport, series: series);
  }

  List<_OverviewSeries> _series(_TimeRange range, double pixelWidth) {
    final livePath = controller.rawRecording['historyPath'] as String?;
    final plotted = controller.watches.where((watch) => watch.plotted).toList();
    final actualEnd = controller.elapsedSeconds;
    final refreshInterval = (controller.plotRetentionSeconds / 2).clamp(
      0.5,
      12.0,
    );
    final lastEnd = _historyEnd;
    if (lastEnd == null ||
        actualEnd < lastEnd ||
        actualEnd - lastEnd >= refreshInterval) {
      if (lastEnd != null && actualEnd < lastEnd) _history.clear();
      _historyEnd = actualEnd;
    }
    _history.update(
      livePath: livePath,
      watches: plotted,
      start: range.start,
      end: range.end,
      liveEnd: _historyEnd!,
      pixelWidth: pixelWidth,
      enabled: true,
      liveEnabled: plotted.any(
        (watch) =>
            watch.archivedHistoryPath == livePath &&
                watch.archivedHistoryPath != null ||
            watch.archivedHistoryPath == null &&
                watch.totalSampleCount > watch.samples.length,
      ),
    );
    return [
      for (final watch in plotted)
        (color: watch.color, points: _points(watch, range, pixelWidth)),
    ];
  }

  List<Offset> _points(WatchItem watch, _TimeRange range, double pixelWidth) {
    final recent = downsampleTelemetrySamples(
      watch.samples,
      xMin: range.start,
      xMax: range.end,
      pixelWidth: pixelWidth,
      cacheResult: false,
    );
    final history = _history.samplesFor(watch);
    if (history == null) return recent;
    final cutoff = recent.isEmpty ? range.end : recent.first.dx;
    if (cutoff < range.start) return recent;
    return [
      for (final point in downsampleTelemetrySamples(
        history,
        xMin: range.start,
        xMax: cutoff,
        pixelWidth: pixelWidth,
      ))
        if (recent.isEmpty || point.dx < cutoff) point,
      ...recent,
    ];
  }

  _OverviewAction _actionAt(PointerEvent event, CartesianPlotViewport mapping) {
    final window = _paintedWindow;
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

  void _onDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryButton != 0) {
      widget.onOpenRange(event.position);
      return;
    }
    if (event.buttons & kPrimaryButton == 0 || _drag != null) return;
    final mapping = _frame?.viewport;
    if (mapping == null) return;
    _drag = _OverviewDrag(
      event.pointer,
      event.localPosition.dx,
      _actionAt(event, mapping),
      mapping,
      _paintedWindow,
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
    _applyWindow(
      start.toDouble(),
      end.toDouble(),
      preserveFollowLatest:
          drag.action == _OverviewAction.startEdge ||
          drag.action == _OverviewAction.endEdge,
    );
  }

  void _applyWindow(
    double start,
    double end, {
    bool preserveFollowLatest = false,
  }) {
    if (preserveFollowLatest && controller.followLatest) {
      final span = end - start;
      if ((controller.plotVisibleWindowSeconds - span).abs() < 1e-9) return;
      controller.setPlotViewport(
        xMin: start,
        xMax: end,
        preserveFollowLatest: true,
      );
      return;
    }
    final current = telemetryTimeWindow(controller);
    if ((current.start - start).abs() < 1e-9 &&
        (current.end - end).abs() < 1e-9) {
      return;
    }
    controller.configurePlotView({
      if (!preserveFollowLatest) 'followLatest': false,
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
    final mapping = _frame?.viewport;
    if (direction == 0 || mapping == null) return KeyEventResult.ignored;
    final window = telemetryTimeWindow(controller);
    final delta = direction * (window.end - window.start) / 8;
    final (start, end) = clampCartesianWindow(
      window.start + delta,
      window.end + delta,
      mapping.xMin,
      mapping.xMax,
    );
    _applyWindow(start, end);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
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
              final mapping = _frame?.viewport;
              final action = mapping == null ? null : _actionAt(event, mapping);
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
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: (event) => _endDrag(event.pointer),
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _PlotOverviewPainter(
                    frameFor: _frameFor,
                    window: () =>
                        _paintedWindow = telemetryTimeWindow(controller),
                    focused: _showFocus,
                    showRange: _dragging,
                    repaint: _repaint,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
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
    required this.frameFor,
    required this.window,
    required this.focused,
    required this.showRange,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _OverviewFrame Function(Size) frameFor;
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
    final frame = frameFor(size);
    final track = frame.viewport;
    if (track != null) {
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
      _drawSeries(canvas, size, track, frame.series, box);
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
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: track,
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
  bool shouldRepaint(covariant _PlotOverviewPainter oldDelegate) =>
      focused != oldDelegate.focused || showRange != oldDelegate.showRange;
}
