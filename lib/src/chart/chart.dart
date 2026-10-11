import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'axis_settings.dart';
import 'cartesian_renderer.dart';
import 'desktop_axis_menu.dart';
import 'hover.dart';
import 'painter.dart';
import 'selection_painter.dart';
import 'viewport.dart';
import '../controller/controller.dart';
import '../theme/theme.dart';

export 'downsampling.dart';
export 'viewport.dart';

class TelemetryChart extends StatefulWidget {
  const TelemetryChart({required this.controller, super.key});

  final TakeALookController controller;

  @override
  State<TelemetryChart> createState() => _TelemetryChartState();
}

class _TelemetryChartState extends State<TelemetryChart> {
  final MenuController _desktopMenuController = MenuController();
  final ValueNotifier<Offset?> _hoverPosition = ValueNotifier(null);
  int? _dragPointer;
  Offset? _lastDragPosition;
  Offset? _dragStartPosition;
  Offset? _rightZoomAnchorFraction;
  Rect? _zoomSelection;
  bool _dragging = false;
  bool _rightZoomDragging = false;
  bool _pointerMoved = false;
  bool _horizontalPanStarted = false;
  Size _size = Size.zero;
  PointerDeviceKind _lastPointerKind = PointerDeviceKind.mouse;
  _DesktopMouseMode _desktopMouseMode = _DesktopMouseMode.pan;
  TalMenuAnimationLease? _menuAnimationLease;

  TakeALookController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return MenuAnchor(
          key: const ValueKey('desktop-plot-menu-anchor'),
          controller: _desktopMenuController,
          style: Theme.of(context).menuTheme.style,
          consumeOutsideTap: true,
          animated: true,
          onAnimationStatusChanged: _handleDesktopMenuAnimationStatus,
          menuChildren: _buildDesktopMenu(),
          child: MouseRegion(
            onHover: (event) {
              _rememberPointerKind(event.kind);
              _hoverPosition.value =
                  _dragPointer == null && !_desktopMenuController.isOpen
                  ? event.localPosition
                  : null;
            },
            onExit: (_) => _hoverPosition.value = null,
            cursor: _mouseCursor,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (details) {
                if (_lastPointerKind == PointerDeviceKind.mouse) return;
                _endDrag();
                _showTouchContextMenu(details.globalPosition);
              },
              child: Listener(
                key: const ValueKey('telemetry-chart-interaction'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                onPointerCancel: (event) {
                  if (event.pointer == _dragPointer) _endDrag();
                },
                onPointerSignal: _handlePointerSignal,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: TelemetryPainter(
                      controller,
                      hoverPosition: _hoverPosition,
                    ),
                    isComplex: true,
                    willChange: true,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_zoomSelection case final selection?)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: ZoomSelectionPainter(selection),
                            ),
                          ),
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
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  MouseCursor get _mouseCursor {
    if (_lastPointerKind != PointerDeviceKind.mouse) {
      return SystemMouseCursors.basic;
    }
    if (_rightZoomDragging) return SystemMouseCursors.grabbing;
    if (_desktopMouseMode == _DesktopMouseMode.rect) {
      return SystemMouseCursors.precise;
    }
    return _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab;
  }

  void _rememberPointerKind(PointerDeviceKind kind) {
    if (_lastPointerKind == kind) return;
    setState(() => _lastPointerKind = kind);
  }

  @override
  void dispose() {
    _hoverPosition.dispose();
    _releaseMenuAnimation();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _hoverPosition.value = null;
    if (_dragPointer != null) return;
    _rememberPointerKind(event.kind);
    if (_desktopMenuController.isOpen &&
        event.buttons & kSecondaryMouseButton == 0) {
      _desktopMenuController.close();
      return;
    }
    // Track clicks even on the axes or when mouse navigation is disabled.
    _dragPointer = event.pointer;
    _lastDragPosition = event.localPosition;
    _dragStartPosition = event.localPosition;
    _pointerMoved = false;
    if (event.buttons & kSecondaryMouseButton != 0) {
      if (event.kind == PointerDeviceKind.mouse) {
        _desktopMenuController.close();
        if (telemetryPlotRect(_size).contains(event.localPosition)) {
          final mapping = _mappingFor(telemetryViewport(controller, _size));
          _rightZoomAnchorFraction = Offset(
            mapping.xFractionAt(event.localPosition.dx),
            mapping.yFractionAt(event.localPosition.dy),
          );
        }
        setState(() => _rightZoomDragging = true);
      } else {
        _showTouchContextMenu(event.position);
      }
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0 ||
        !telemetryPlotRect(_size).contains(event.localPosition) ||
        (!controller.plotMouseXEnabled && !controller.plotMouseYEnabled)) {
      return;
    }
    setState(() => _dragging = true);
  }

  void _openDesktopMenu(Offset position) {
    if (!_desktopMenuController.isOpen && _menuAnimationLease == null) {
      _menuAnimationLease = beginTalMenuAnimation();
    }
    _desktopMenuController.open(position: position);
  }

  void _handleDesktopMenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _releaseMenuAnimation();
  }

  void _releaseMenuAnimation() {
    _menuAnimationLease?.release();
    _menuAnimationLease = null;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer) return;
    _trackPointerMovement(event.localPosition);
    if (_rightZoomDragging) {
      if (event.buttons & kSecondaryMouseButton == 0) {
        _endDrag();
        return;
      }
      if (!_pointerMoved) return;
      _updateRightButtonZoom(event.localPosition);
      return;
    }
    final previous = _lastDragPosition;
    if (!_dragging ||
        previous == null ||
        event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    final plot = telemetryPlotRect(_size);
    if (plot.width <= 1 || plot.height <= 1) return;
    if (_lastPointerKind == PointerDeviceKind.mouse &&
        _desktopMouseMode == _DesktopMouseMode.rect) {
      final start = _dragStartPosition;
      if (start == null) return;
      setState(() {
        _lastDragPosition = event.localPosition;
        _zoomSelection = Rect.fromPoints(
          start,
          event.localPosition,
        ).intersect(plot);
      });
      return;
    }
    final viewport = telemetryViewport(controller, _size);
    final delta = event.localPosition - previous;
    _lastDragPosition = event.localPosition;
    var horizontalDelta = 0.0;
    if (controller.plotMouseXEnabled) {
      if (_horizontalPanStarted) {
        horizontalDelta = delta.dx;
      } else {
        final start = _dragStartPosition;
        final displacement = start == null
            ? 0.0
            : event.localPosition.dx - start.dx;
        // Ignore small sideways jitter during a vertical pan, but accumulate
        // slow horizontal movement until it becomes an intentional time pan.
        if (displacement.abs() > 3) {
          _horizontalPanStarted = true;
          horizontalDelta = displacement;
        }
      }
    }
    var xMin = viewport.xMin;
    var xMax = viewport.xMax;
    var yMin = viewport.yMin;
    var yMax = viewport.yMax;
    if (horizontalDelta != 0) {
      final direction = controller.plotInvertX ? -1.0 : 1.0;
      final shift = -horizontalDelta / plot.width * viewport.xSpan * direction;
      xMin += shift;
      xMax += shift;
      if (xMin < 0) {
        xMax -= xMin;
        xMin = 0;
      }
      final latest = math.max(controller.elapsedSeconds, viewport.xSpan);
      if (xMax > latest) {
        xMin -= xMax - latest;
        xMax = latest;
      }
    }
    if (controller.plotMouseYEnabled) {
      final direction = controller.plotInvertY ? -1.0 : 1.0;
      final shift = delta.dy / plot.height * viewport.ySpan * direction;
      yMin += shift;
      yMax += shift;
    }
    final timeWindowChanged =
        (xMin - viewport.xMin).abs() > 1e-9 ||
        (xMax - viewport.xMax).abs() > 1e-9;
    if (!timeWindowChanged &&
        (!controller.plotMouseYEnabled || delta.dy == 0)) {
      return;
    }
    if (controller.followLatest && !timeWindowChanged) {
      // Keep the configured duration during startup and while following live data.
      xMin = xMax - controller.plotVisibleWindowSeconds;
    }
    controller.setPlotViewport(
      xMin: xMin,
      xMax: math.max(xMin + 0.001, xMax),
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
      preserveFollowLatest: !timeWindowChanged,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _dragPointer) return;
    _trackPointerMovement(event.localPosition);
    if (!_pointerMoved && (Offset.zero & _size).contains(event.localPosition)) {
      final mapping = _mappingFor(telemetryViewport(controller, _size));
      final hit = hitTestTelemetrySeries(
        telemetryPlotSeries(controller, mapping),
        mapping,
        event.localPosition,
      );
      controller.setPlotHighlightedWatch(
        hit?.series.watch.symbol.key,
        selectWatchRow: true,
      );
      _hoverPosition.value = hit == null ? null : event.localPosition;
    }
    if (_rightZoomDragging) {
      final openMenu = !_pointerMoved;
      _endDrag();
      if (openMenu) _openDesktopMenu(event.localPosition);
      return;
    }
    if (event.buttons & kPrimaryMouseButton != 0) return;
    if (_zoomSelection case final selection?) {
      _applyZoomSelection(selection);
    }
    _endDrag();
  }

  void _trackPointerMovement(Offset position) {
    final start = _dragStartPosition;
    if (start != null && (position - start).distanceSquared > 9) {
      _pointerMoved = true;
    }
  }

  void _endDrag() {
    _dragPointer = null;
    _lastDragPosition = null;
    _dragStartPosition = null;
    _rightZoomAnchorFraction = null;
    _pointerMoved = false;
    _horizontalPanStarted = false;
    if ((_dragging || _rightZoomDragging || _zoomSelection != null) &&
        mounted) {
      setState(() {
        _dragging = false;
        _rightZoomDragging = false;
        _zoomSelection = null;
      });
    }
  }

  void _updateRightButtonZoom(Offset position) {
    final previous = _lastDragPosition;
    final anchor = _rightZoomAnchorFraction;
    _lastDragPosition = position;
    if (previous == null || anchor == null) return;
    final delta = position - previous;
    if ((!controller.plotMouseXEnabled || delta.dx == 0) &&
        (!controller.plotMouseYEnabled || delta.dy == 0)) {
      return;
    }
    _zoomPlot(
      anchorFraction: anchor,
      xScale: math.pow(1.02, -delta.dx).toDouble(),
      yScale: math.pow(1.02, delta.dy).toDouble(),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !telemetryPlotRect(_size).contains(event.localPosition) ||
        (!controller.plotMouseXEnabled && !controller.plotMouseYEnabled)) {
      return;
    }
    final viewport = telemetryViewport(controller, _size);
    final mapping = _mappingFor(viewport);
    final scale = event.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
    _zoomPlot(
      anchorFraction: Offset(
        mapping.xFractionAt(event.localPosition.dx),
        mapping.yFractionAt(event.localPosition.dy),
      ),
      xScale: scale,
      yScale: scale,
    );
  }

  void _zoomPlot({
    required Offset anchorFraction,
    required double xScale,
    required double yScale,
  }) {
    final viewport = telemetryViewport(controller, _size);
    final following = controller.followLatest;
    // Use the configured duration even before the first full window is sampled.
    final currentXSpan = following
        ? controller.plotVisibleWindowSeconds
        : viewport.xSpan;
    var xMin = following ? viewport.xMax - currentXSpan : viewport.xMin;
    var xMax = viewport.xMax;
    var yMin = viewport.yMin;
    var yMax = viewport.yMax;
    if (controller.plotMouseXEnabled) {
      final span = (currentXSpan * xScale).clamp(0.2, 120).toDouble();
      if (following) {
        xMin = xMax - span;
      } else {
        final fraction = anchorFraction.dx;
        final anchor = viewport.xMin + viewport.xSpan * fraction;
        xMin = anchor - span * fraction;
        xMax = xMin + span;
        if (xMin < 0) {
          xMax -= xMin;
          xMin = 0;
        }
        final latest = math.max(controller.elapsedSeconds, span);
        if (xMax > latest) {
          xMin -= xMax - latest;
          xMax = latest;
        }
      }
    }
    if (controller.plotMouseYEnabled) {
      final fraction = anchorFraction.dy;
      final anchor = viewport.yMin + viewport.ySpan * fraction;
      final span = math.max(1e-9, viewport.ySpan * yScale);
      yMin = anchor - span * fraction;
      yMax = yMin + span;
    }
    controller.setPlotViewport(
      xMin: xMin,
      xMax: math.max(xMin + 0.001, xMax),
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
      preserveFollowLatest: true,
    );
  }

  void _applyZoomSelection(Rect selection) {
    if (selection.width < 5 || selection.height < 5) return;
    final viewport = telemetryViewport(controller, _size);
    final mapping = _mappingFor(viewport);
    final firstX = mapping.unmapX(selection.left);
    final secondX = mapping.unmapX(selection.right);
    final firstY = mapping.unmapY(selection.top);
    final secondY = mapping.unmapY(selection.bottom);
    final xMin = math.min(firstX, secondX);
    final xMax = math.max(firstX, secondX);
    final yMin = math.min(firstY, secondY);
    final yMax = math.max(firstY, secondY);
    final currentXMin = controller.followLatest
        ? viewport.xMax - controller.plotVisibleWindowSeconds
        : viewport.xMin;
    controller.setPlotViewport(
      xMin: controller.plotMouseXEnabled ? xMin : currentXMin,
      xMax: controller.plotMouseXEnabled ? xMax : viewport.xMax,
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
      preserveFollowLatest: true,
    );
  }

  CartesianPlotViewport _mappingFor(TelemetryViewport viewport) {
    return CartesianPlotViewport(
      plot: viewport.plot,
      xMin: viewport.xMin,
      xMax: viewport.xMax,
      yMin: viewport.yMin,
      yMax: viewport.yMax,
      invertX: controller.plotInvertX,
      invertY: controller.plotInvertY,
    );
  }

  List<Widget> _buildDesktopMenu() {
    return [
      MenuItemButton(
        key: const ValueKey('desktop-plot-view-all'),
        onPressed: controller.showAllPlotSamples,
        child: const Text('View All'),
      ),
      SubmenuButton(
        key: const ValueKey('desktop-plot-x-axis'),
        menuStyle: desktopAxisSubmenuStyle,
        animated: true,
        menuChildren: [
          DesktopAxisMenu(
            key: const ValueKey('desktop-plot-x-axis-controls'),
            controller: controller,
            xAxis: true,
            onChanged: _refreshDesktopMenu,
          ),
        ],
        child: const Text('X Axis'),
      ),
      SubmenuButton(
        key: const ValueKey('desktop-plot-y-axis'),
        menuStyle: desktopAxisSubmenuStyle,
        animated: true,
        menuChildren: [
          DesktopAxisMenu(
            key: const ValueKey('desktop-plot-y-axis-controls'),
            controller: controller,
            xAxis: false,
            onChanged: _refreshDesktopMenu,
          ),
        ],
        child: const Text('Y Axis'),
      ),
      SubmenuButton(
        key: const ValueKey('desktop-plot-mouse-mode'),
        menuStyle: Theme.of(
          context,
        ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
        animated: true,
        menuChildren: [
          RadioMenuButton<_DesktopMouseMode>(
            key: const ValueKey('desktop-mouse-mode-pan'),
            value: _DesktopMouseMode.pan,
            groupValue: _desktopMouseMode,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _desktopMouseMode = value);
            },
            child: const Text('3 Button'),
          ),
          RadioMenuButton<_DesktopMouseMode>(
            key: const ValueKey('desktop-mouse-mode-rect'),
            value: _DesktopMouseMode.rect,
            groupValue: _desktopMouseMode,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _desktopMouseMode = value);
            },
            child: const Text('1 Button'),
          ),
        ],
        child: const Text('Mouse Mode'),
      ),
    ];
  }

  void _refreshDesktopMenu() {
    if (mounted) setState(() {});
  }

  Future<void> _showTouchContextMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);
    final action = await showTalContextMenu<_PlotMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        overlay.size.width - local.dx,
        overlay.size.height - local.dy,
      ),
      touchOptimized: true,
      items: [
        const PopupMenuItem(
          value: _PlotMenuAction.showAll,
          child: Text('显示全部'),
        ),
        CheckedPopupMenuItem(
          value: _PlotMenuAction.followLatest,
          checked: controller.followLatest,
          child: const Text('跟随最新'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _PlotMenuAction.xAxis,
          child: Text('X 轴详细设置…'),
        ),
        const PopupMenuItem(
          value: _PlotMenuAction.yAxis,
          child: Text('Y 轴详细设置…'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: _PlotMenuAction.grid,
          checked: controller.plotShowGrid,
          child: const Text('显示网格'),
        ),
        CheckedPopupMenuItem(
          value: _PlotMenuAction.legend,
          checked: controller.plotShowLegend,
          child: const Text('显示图例'),
        ),
        const PopupMenuItem<_PlotMenuAction>(
          enabled: false,
          child: Text('鼠标模式：左键平移 · 右键拖动分轴缩放 · 滚轮缩放'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _PlotMenuAction.reset,
          child: Text('恢复默认视图'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _PlotMenuAction.showAll:
        controller.showAllPlotSamples();
      case _PlotMenuAction.followLatest:
        controller.toggleFollowLatest();
      case _PlotMenuAction.xAxis:
        await _showAxisSettings(xAxis: true);
      case _PlotMenuAction.yAxis:
        await _showAxisSettings(xAxis: false);
      case _PlotMenuAction.grid:
        controller.configurePlotView({
          'plotShowGrid': !controller.plotShowGrid,
        });
      case _PlotMenuAction.legend:
        controller.configurePlotView({
          'plotShowLegend': !controller.plotShowLegend,
        });
      case _PlotMenuAction.reset:
        controller.resetPlotView();
    }
  }

  Future<void> _showAxisSettings({required bool xAxis}) async {
    final viewport = telemetryViewport(controller, _size);
    final result = await showTalDialog<AxisSettings>(
      context: context,
      builder: (context) => PlotAxisSettingsDialog(
        xAxis: xAxis,
        automatic: xAxis ? controller.followLatest : controller.plotAutoY,
        minimum: xAxis ? viewport.xMin : viewport.yMin,
        maximum: xAxis ? viewport.xMax : viewport.yMax,
        mouseEnabled: xAxis
            ? controller.plotMouseXEnabled
            : controller.plotMouseYEnabled,
        inverted: xAxis ? controller.plotInvertX : controller.plotInvertY,
        minimumAllowed: xAxis ? 0 : null,
      ),
    );
    if (!mounted || result == null) return;
    if (xAxis) {
      controller.configurePlotView({
        'followLatest': result.automatic,
        'plotMouseXEnabled': result.mouseEnabled,
        'plotInvertX': result.inverted,
        if (!result.automatic) 'xMin': result.minimum,
        if (!result.automatic) 'xMax': result.maximum,
      });
    } else {
      controller.configurePlotView({
        'plotAutoY': result.automatic,
        'plotMouseYEnabled': result.mouseEnabled,
        'plotInvertY': result.inverted,
        if (!result.automatic) 'yMin': result.minimum,
        if (!result.automatic) 'yMax': result.maximum,
      });
    }
  }
}

enum _PlotMenuAction {
  showAll,
  followLatest,
  xAxis,
  yAxis,
  grid,
  legend,
  reset,
}

enum _DesktopMouseMode { pan, rect }
