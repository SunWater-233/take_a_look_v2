import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'chart/axis_settings.dart';
import 'chart/desktop_axis_menu.dart';
import 'chart/painter.dart';
import 'chart/selection_painter.dart';
import 'chart/viewport.dart';
import 'controller.dart';
import 'theme.dart';

export 'chart/downsampling.dart';
export 'chart/viewport.dart';

class TelemetryChart extends StatefulWidget {
  const TelemetryChart({required this.controller, super.key});

  final TakeALookController controller;

  @override
  State<TelemetryChart> createState() => _TelemetryChartState();
}

class _TelemetryChartState extends State<TelemetryChart> {
  final MenuController _desktopMenuController = MenuController();
  Offset? _lastDragPosition;
  Offset? _dragStartPosition;
  Rect? _zoomSelection;
  bool _dragging = false;
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
          style: talContextMenuStyle,
          consumeOutsideTap: true,
          animated: true,
          onAnimationStatusChanged: _handleDesktopMenuAnimationStatus,
          menuChildren: _buildDesktopMenu(),
          child: MouseRegion(
            onHover: (event) => _rememberPointerKind(event.kind),
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
                onPointerCancel: (_) => _endDrag(),
                onPointerSignal: _handlePointerSignal,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: TelemetryPainter(controller),
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
    _releaseMenuAnimation();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _rememberPointerKind(event.kind);
    if (event.buttons & kSecondaryMouseButton != 0) {
      if (event.kind == PointerDeviceKind.mouse) {
        _endDrag();
        _openDesktopMenu(event.localPosition);
      } else {
        _showTouchContextMenu(event.position);
      }
      return;
    }
    if (_desktopMenuController.isOpen) {
      _desktopMenuController.close();
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0 ||
        !telemetryPlotRect(_size).contains(event.localPosition) ||
        (!controller.plotMouseXEnabled && !controller.plotMouseYEnabled)) {
      return;
    }
    _lastDragPosition = event.localPosition;
    _dragStartPosition = event.localPosition;
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
    var xMin = viewport.xMin;
    var xMax = viewport.xMax;
    var yMin = viewport.yMin;
    var yMax = viewport.yMax;
    if (controller.plotMouseXEnabled) {
      final direction = controller.plotInvertX ? -1.0 : 1.0;
      final shift = -delta.dx / plot.width * viewport.xSpan * direction;
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
    controller.setPlotViewport(
      xMin: math.max(0, xMin),
      xMax: math.max(xMin + 0.001, xMax),
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.buttons & kPrimaryMouseButton != 0) return;
    if (_zoomSelection case final selection?) {
      _applyZoomSelection(selection);
    }
    _endDrag();
  }

  void _endDrag() {
    _lastDragPosition = null;
    _dragStartPosition = null;
    if ((_dragging || _zoomSelection != null) && mounted) {
      setState(() {
        _dragging = false;
        _zoomSelection = null;
      });
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !telemetryPlotRect(_size).contains(event.localPosition) ||
        (!controller.plotMouseXEnabled && !controller.plotMouseYEnabled)) {
      return;
    }
    final plot = telemetryPlotRect(_size);
    final viewport = telemetryViewport(controller, _size);
    final scale = event.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
    var xMin = viewport.xMin;
    var xMax = viewport.xMax;
    var yMin = viewport.yMin;
    var yMax = viewport.yMax;
    if (controller.plotMouseXEnabled) {
      var fraction = ((event.localPosition.dx - plot.left) / plot.width).clamp(
        0.0,
        1.0,
      );
      if (controller.plotInvertX) fraction = 1 - fraction;
      final anchor = viewport.xMin + viewport.xSpan * fraction;
      final span = (viewport.xSpan * scale).clamp(0.2, 120).toDouble();
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
    if (controller.plotMouseYEnabled) {
      var fraction = (1 - (event.localPosition.dy - plot.top) / plot.height)
          .clamp(0.0, 1.0);
      if (controller.plotInvertY) fraction = 1 - fraction;
      final anchor = viewport.yMin + viewport.ySpan * fraction;
      final span = math.max(1e-9, viewport.ySpan * scale);
      yMin = anchor - span * fraction;
      yMax = yMin + span;
    }
    controller.setPlotViewport(
      xMin: math.max(0, xMin),
      xMax: math.max(xMin + 0.001, xMax),
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
    );
  }

  void _applyZoomSelection(Rect selection) {
    final plot = telemetryPlotRect(_size);
    if (selection.width < 5 || selection.height < 5) return;
    final viewport = telemetryViewport(controller, _size);
    var leftFraction = ((selection.left - plot.left) / plot.width).clamp(
      0.0,
      1.0,
    );
    var rightFraction = ((selection.right - plot.left) / plot.width).clamp(
      0.0,
      1.0,
    );
    var topFraction = (1 - (selection.top - plot.top) / plot.height).clamp(
      0.0,
      1.0,
    );
    var bottomFraction = (1 - (selection.bottom - plot.top) / plot.height)
        .clamp(0.0, 1.0);
    if (controller.plotInvertX) {
      final oldLeft = leftFraction;
      leftFraction = 1 - rightFraction;
      rightFraction = 1 - oldLeft;
    }
    if (controller.plotInvertY) {
      final oldTop = topFraction;
      topFraction = 1 - bottomFraction;
      bottomFraction = 1 - oldTop;
    }
    final xMin = viewport.xMin + viewport.xSpan * leftFraction;
    final xMax = viewport.xMin + viewport.xSpan * rightFraction;
    final yMin = viewport.yMin + viewport.ySpan * bottomFraction;
    final yMax = viewport.yMin + viewport.ySpan * topFraction;
    controller.setPlotViewport(
      xMin: controller.plotMouseXEnabled ? xMin : viewport.xMin,
      xMax: controller.plotMouseXEnabled ? xMax : viewport.xMax,
      yMin: controller.plotMouseYEnabled ? yMin : null,
      yMax: controller.plotMouseYEnabled ? yMax : null,
    );
  }

  List<Widget> _buildDesktopMenu() {
    return [
      MenuItemButton(
        key: const ValueKey('desktop-plot-view-all'),
        style: talContextMenuButtonStyle,
        onPressed: controller.showAllPlotSamples,
        child: const Text('View All'),
      ),
      SubmenuButton(
        key: const ValueKey('desktop-plot-x-axis'),
        style: talContextMenuButtonStyle,
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
        style: talContextMenuButtonStyle,
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
        style: talContextMenuButtonStyle,
        menuStyle: talContextSubmenuStyle,
        animated: true,
        menuChildren: [
          RadioMenuButton<_DesktopMouseMode>(
            key: const ValueKey('desktop-mouse-mode-pan'),
            style: talContextMenuButtonStyle,
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
            style: talContextMenuButtonStyle,
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
          child: Text('鼠标模式：左键平移 · 滚轮缩放'),
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
    final result = await showDialog<AxisSettings>(
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
