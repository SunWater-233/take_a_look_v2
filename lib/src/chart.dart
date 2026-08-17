import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

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
                    painter: _TelemetryPainter(controller),
                    isComplex: true,
                    willChange: true,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_zoomSelection case final selection?)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _ZoomSelectionPainter(selection),
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
        !_plotRect(_size).contains(event.localPosition) ||
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
    final plot = _plotRect(_size);
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
        !_plotRect(_size).contains(event.localPosition) ||
        (!controller.plotMouseXEnabled && !controller.plotMouseYEnabled)) {
      return;
    }
    final plot = _plotRect(_size);
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
    final plot = _plotRect(_size);
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
        menuStyle: _desktopAxisSubmenuStyle,
        animated: true,
        menuChildren: [
          _DesktopAxisMenu(
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
        menuStyle: _desktopAxisSubmenuStyle,
        animated: true,
        menuChildren: [
          _DesktopAxisMenu(
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
    final result = await showDialog<_AxisSettings>(
      context: context,
      builder: (context) => _PlotAxisSettingsDialog(
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

final MenuStyle _desktopAxisSubmenuStyle = talContextSubmenuStyle.copyWith(
  minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
  padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
);

class _DesktopAxisMenu extends StatefulWidget {
  const _DesktopAxisMenu({
    required this.controller,
    required this.xAxis,
    required this.onChanged,
    super.key,
  });

  final TakeALookController controller;
  final bool xAxis;
  final VoidCallback onChanged;

  @override
  State<_DesktopAxisMenu> createState() => _DesktopAxisMenuState();
}

class _DesktopAxisMenuState extends State<_DesktopAxisMenu> {
  late bool automatic;
  late bool mouseEnabled;
  late bool inverted;
  late final TextEditingController minimumController;
  late final TextEditingController maximumController;
  String? errorText;

  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final viewport = telemetryViewport(controller, const Size(720, 480));
    automatic = widget.xAxis ? controller.followLatest : controller.plotAutoY;
    mouseEnabled = widget.xAxis
        ? controller.plotMouseXEnabled
        : controller.plotMouseYEnabled;
    inverted = widget.xAxis ? controller.plotInvertX : controller.plotInvertY;
    minimumController = TextEditingController(
      text: _compactNumber(widget.xAxis ? viewport.xMin : viewport.yMin),
    );
    maximumController = TextEditingController(
      text: _compactNumber(widget.xAxis ? viewport.xMax : viewport.yMax),
    );
  }

  @override
  void dispose() {
    minimumController.dispose();
    maximumController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey(
        widget.xAxis ? 'desktop-x-axis-panel' : 'desktop-y-axis-panel',
      ),
      width: 249,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: TalColors.text,
            fontFamily: talFontFamily,
            fontSize: 12.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DesktopChoiceRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-manual' : 'desktop-y-manual',
                ),
                label: 'Manual',
                selected: !automatic,
                onTap: () => _setAutomatic(false),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _rangeField(
                      controller: minimumController,
                      key: ValueKey(
                        widget.xAxis
                            ? 'desktop-x-minimum'
                            : 'desktop-y-minimum',
                      ),
                    ),
                    const SizedBox(width: 3),
                    _rangeField(
                      controller: maximumController,
                      key: ValueKey(
                        widget.xAxis
                            ? 'desktop-x-maximum'
                            : 'desktop-y-maximum',
                      ),
                    ),
                  ],
                ),
              ),
              _DesktopChoiceRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-auto' : 'desktop-y-auto',
                ),
                label: 'Auto',
                selected: automatic,
                onTap: () => _setAutomatic(true),
                trailing: Container(
                  width: 72,
                  height: 27,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: TalColors.input,
                    border: Border.all(color: TalColors.border),
                  ),
                  child: const Text('100%'),
                ),
              ),
              _DesktopCheckRow(
                label: 'Visible Data Only',
                value: !widget.xAxis,
                enabled: false,
                onChanged: (_) {},
              ),
              _DesktopCheckRow(
                label: 'Auto Pan Only',
                value: widget.xAxis && automatic,
                enabled: false,
                onChanged: (_) {},
              ),
              _DesktopCheckRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-invert' : 'desktop-y-invert',
                ),
                label: 'Invert Axis',
                value: inverted,
                onChanged: _setInverted,
              ),
              _DesktopCheckRow(
                key: ValueKey(
                  widget.xAxis
                      ? 'desktop-x-mouse-enabled'
                      : 'desktop-y-mouse-enabled',
                ),
                label: 'Mouse Enabled',
                value: mouseEnabled,
                onChanged: _setMouseEnabled,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Expanded(child: Text('Link Axis:')),
                  Container(
                    width: 108,
                    height: 27,
                    decoration: BoxDecoration(
                      color: TalColors.input,
                      border: Border.all(color: TalColors.border),
                    ),
                    child: const Align(
                      alignment: Alignment.centerRight,
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: 19,
                        color: TalColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
              if (errorText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    errorText!,
                    style: const TextStyle(
                      color: Color(0xFFE25858),
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rangeField({
    required TextEditingController controller,
    required Key key,
  }) {
    return SizedBox(
      width: 60,
      height: 27,
      child: TextField(
        key: key,
        controller: controller,
        enabled: !automatic,
        style: const TextStyle(fontSize: 11.5, color: TalColors.text),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        textInputAction: TextInputAction.done,
        onEditingComplete: _applyManualRange,
        onSubmitted: (_) => _applyManualRange(),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: TalColors.border),
          ),
        ),
      ),
    );
  }

  void _setAutomatic(bool value) {
    setState(() {
      automatic = value;
      errorText = null;
    });
    if (widget.xAxis) {
      controller.configurePlotView({'followLatest': value});
    } else {
      controller.configurePlotView({'plotAutoY': value});
    }
    widget.onChanged();
  }

  void _setMouseEnabled(bool value) {
    setState(() => mouseEnabled = value);
    controller.configurePlotView({
      widget.xAxis ? 'plotMouseXEnabled' : 'plotMouseYEnabled': value,
    });
    widget.onChanged();
  }

  void _setInverted(bool value) {
    setState(() => inverted = value);
    controller.configurePlotView({
      widget.xAxis ? 'plotInvertX' : 'plotInvertY': value,
    });
    widget.onChanged();
  }

  void _applyManualRange() {
    final minimum = double.tryParse(minimumController.text.trim());
    final maximum = double.tryParse(maximumController.text.trim());
    if (minimum == null ||
        maximum == null ||
        !minimum.isFinite ||
        !maximum.isFinite ||
        maximum <= minimum ||
        (widget.xAxis && minimum < 0)) {
      setState(() => errorText = 'Invalid range');
      return;
    }
    setState(() {
      automatic = false;
      errorText = null;
    });
    controller.configurePlotView({
      if (widget.xAxis) ...{
        'followLatest': false,
        'xMin': minimum,
        'xMax': maximum,
      } else ...{
        'plotAutoY': false,
        'yMin': minimum,
        'yMax': maximum,
      },
    });
    widget.onChanged();
  }
}

class _DesktopChoiceRow extends StatelessWidget {
  const _DesktopChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.trailing,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 98,
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: selected ? TalColors.accent : TalColors.muted,
                  ),
                  const SizedBox(width: 4),
                  Text(label),
                ],
              ),
            ),
            const Spacer(),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _DesktopCheckRow extends StatelessWidget {
  const _DesktopCheckRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: enabled ? (next) => onChanged(next ?? false) : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: const VisualDensity(
                  horizontal: -4,
                  vertical: -4,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: enabled ? TalColors.text : TalColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomSelectionPainter extends CustomPainter {
  const _ZoomSelectionPainter(this.selection);

  final Rect selection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(selection, Paint()..color = TalColors.accent.withAlpha(35));
    canvas.drawRect(
      selection,
      Paint()
        ..color = TalColors.accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ZoomSelectionPainter oldDelegate) {
    return oldDelegate.selection != selection;
  }
}

String _compactNumber(double value) => value.toStringAsPrecision(6);

Rect _plotRect(Size size) => Rect.fromLTRB(
  52,
  48,
  math.max(54, size.width - 10),
  math.max(50, size.height - 46),
);

class TelemetryViewport {
  const TelemetryViewport({
    required this.plot,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });

  final Rect plot;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

  double get xSpan => math.max(0.001, xMax - xMin);
  double get ySpan => math.max(1e-9, yMax - yMin);
}

TelemetryViewport telemetryViewport(TakeALookController controller, Size size) {
  final plot = _plotRect(size);
  final plotted = controller.watches.where((item) => item.plotted);
  var xMax = controller.plotWindowEndSeconds;
  final window = math.max(0.2, controller.plotVisibleWindowSeconds);
  var xMin = math.max(0.0, xMax - window);
  if (xMax <= xMin) xMax = xMin + window;

  var yMin = controller.plotAutoY
      ? double.infinity
      : controller.plotYMin ?? double.infinity;
  var yMax = controller.plotAutoY
      ? -double.infinity
      : controller.plotYMax ?? -double.infinity;
  if (controller.plotAutoY || !yMin.isFinite || !yMax.isFinite) {
    yMin = double.infinity;
    yMax = -double.infinity;
    for (final watch in plotted) {
      for (final point in controller.plotSamplesFor(watch)) {
        if (point.dx < xMin || point.dx > xMax) continue;
        yMin = math.min(yMin, point.dy);
        yMax = math.max(yMax, point.dy);
      }
    }
    if (!yMin.isFinite || !yMax.isFinite) {
      yMin = -1;
      yMax = 1;
    }
    if ((yMax - yMin).abs() < 0.001) {
      yMin -= 1;
      yMax += 1;
    } else {
      final pad = (yMax - yMin) * 0.12;
      yMin -= pad;
      yMax += pad;
    }
  }
  return TelemetryViewport(
    plot: plot,
    xMin: xMin,
    xMax: xMax,
    yMin: yMin,
    yMax: yMax,
  );
}

class _AxisSettings {
  const _AxisSettings({
    required this.automatic,
    required this.minimum,
    required this.maximum,
    required this.mouseEnabled,
    required this.inverted,
  });

  final bool automatic;
  final double minimum;
  final double maximum;
  final bool mouseEnabled;
  final bool inverted;
}

class _PlotAxisSettingsDialog extends StatefulWidget {
  const _PlotAxisSettingsDialog({
    required this.xAxis,
    required this.automatic,
    required this.minimum,
    required this.maximum,
    required this.mouseEnabled,
    required this.inverted,
  });

  final bool xAxis;
  final bool automatic;
  final double minimum;
  final double maximum;
  final bool mouseEnabled;
  final bool inverted;

  @override
  State<_PlotAxisSettingsDialog> createState() =>
      _PlotAxisSettingsDialogState();
}

class _PlotAxisSettingsDialogState extends State<_PlotAxisSettingsDialog> {
  late bool automatic;
  late bool mouseEnabled;
  late bool inverted;
  late final TextEditingController minimumController;
  late final TextEditingController maximumController;
  String? errorText;

  @override
  void initState() {
    super.initState();
    automatic = widget.automatic;
    mouseEnabled = widget.mouseEnabled;
    inverted = widget.inverted;
    minimumController = TextEditingController(
      text: widget.minimum.toStringAsFixed(4),
    );
    maximumController = TextEditingController(
      text: widget.maximum.toStringAsFixed(4),
    );
  }

  @override
  void dispose() {
    minimumController.dispose();
    maximumController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final axis = widget.xAxis ? 'X' : 'Y';
    final unit = widget.xAxis ? '（秒）' : '';
    return AlertDialog(
      title: Text('$axis 轴详细设置'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(widget.xAxis ? '自动跟随最新' : '自动范围'),
              value: automatic,
              onChanged: (value) => setState(() => automatic = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用鼠标拖动与缩放'),
              value: mouseEnabled,
              onChanged: (value) => setState(() => mouseEnabled = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('反向坐标轴'),
              value: inverted,
              onChanged: (value) => setState(() => inverted = value),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('plot-${axis.toLowerCase()}-minimum'),
                    controller: minimumController,
                    enabled: !automatic,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(labelText: '最小值$unit'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: ValueKey('plot-${axis.toLowerCase()}-maximum'),
                    controller: maximumController,
                    enabled: !automatic,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(labelText: '最大值$unit'),
                  ),
                ),
              ],
            ),
            if (errorText != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errorText!,
                  style: const TextStyle(color: Color(0xFFE25858)),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _apply, child: const Text('应用')),
      ],
    );
  }

  void _apply() {
    final minimum = double.tryParse(minimumController.text.trim());
    final maximum = double.tryParse(maximumController.text.trim());
    if (minimum == null ||
        maximum == null ||
        !minimum.isFinite ||
        !maximum.isFinite ||
        maximum <= minimum ||
        (widget.xAxis && minimum < 0)) {
      setState(() {
        errorText = widget.xAxis
            ? '请输入有效范围，且 X 轴最小值不能小于 0。'
            : '请输入有效范围，最大值必须大于最小值。';
      });
      return;
    }
    Navigator.of(context).pop(
      _AxisSettings(
        automatic: automatic,
        minimum: minimum,
        maximum: maximum,
        mouseEnabled: mouseEnabled,
        inverted: inverted,
      ),
    );
  }
}

class _TelemetryPainter extends CustomPainter {
  _TelemetryPainter(this.controller) : super(repaint: controller.plotChanges);

  final TakeALookController controller;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TalColors.input);
    final viewport = telemetryViewport(controller, size);
    final plot = viewport.plot;
    if (plot.width <= 1 || plot.height <= 1) return;

    if (controller.plotShowGrid) {
      _drawGrid(canvas, plot);
    } else {
      _drawPlotOutline(canvas, plot);
    }
    _drawTitle(canvas, size);

    final plotted = controller.watches.where((item) => item.plotted).toList();
    if (plotted.isEmpty) {
      _drawAxisLabels(
        canvas,
        plot,
        viewport.xMin,
        viewport.xMax,
        viewport.yMin,
        viewport.yMax,
      );
      return;
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final watch in plotted) {
      _drawSeries(
        canvas,
        plot,
        watch,
        viewport.xMin,
        viewport.xMax,
        viewport.yMin,
        viewport.yMax,
      );
    }
    canvas.restore();
    _drawAxisLabels(
      canvas,
      plot,
      viewport.xMin,
      viewport.xMax,
      viewport.yMin,
      viewport.yMax,
    );
    if (controller.plotShowLegend) _drawLegend(canvas, plot, plotted);
  }

  void _drawGrid(Canvas canvas, Rect plot) {
    final minor = Paint()..color = TalColors.gridMinor;
    final major = Paint()..color = TalColors.gridMajor;
    for (var i = 0; i <= 50; i += 1) {
      final x = plot.left + plot.width * i / 50;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        i % 5 == 0 ? major : minor,
      );
    }
    for (var i = 0; i <= 20; i += 1) {
      final y = plot.top + plot.height * i / 20;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        i % 2 == 0 ? major : minor,
      );
    }
    _drawPlotOutline(canvas, plot);
  }

  void _drawPlotOutline(Canvas canvas, Rect plot) {
    canvas.drawRect(
      plot,
      Paint()
        ..color = TalColors.text
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawTitle(Canvas canvas, Size size) {
    _text(
      canvas,
      '变量实时趋势',
      Offset(size.width / 2 - 70, 16),
      const TextStyle(
        color: TalColors.text,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
      width: 140,
      align: TextAlign.center,
    );
  }

  void _drawAxisLabels(
    Canvas canvas,
    Rect plot,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
  ) {
    for (var i = 0; i <= 5; i += 1) {
      final y = plot.bottom - plot.height * i / 5;
      final fraction = controller.plotInvertY ? 1 - i / 5 : i / 5;
      final value = yMin + (yMax - yMin) * fraction;
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(2, y - 7),
        talBody,
        width: 46,
        align: TextAlign.right,
      );
    }
    for (var i = 0; i <= 10; i += 1) {
      final x = plot.left + plot.width * i / 10;
      final fraction = controller.plotInvertX ? 1 - i / 10 : i / 10;
      final value = xMin + (xMax - xMin) * fraction;
      _text(
        canvas,
        value.toStringAsFixed(value.abs() >= 100 ? 0 : 1),
        Offset(x - 30, plot.bottom + 7),
        talBody,
        width: 60,
        align: TextAlign.center,
      );
    }
    _text(
      canvas,
      '时间 (s)',
      Offset(plot.center.dx - 45, plot.bottom + 25),
      talBody,
      width: 90,
      align: TextAlign.center,
    );
    canvas.save();
    canvas.translate(12, plot.center.dy + 28);
    canvas.rotate(-math.pi / 2);
    _text(
      canvas,
      '变量值',
      Offset.zero,
      talBody,
      width: 56,
      align: TextAlign.center,
    );
    canvas.restore();
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    WatchItem watch,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
  ) {
    final path = Path();
    var started = false;
    final samples = downsampleTelemetrySamples(
      controller.plotSamplesFor(watch),
      xMin: xMin,
      xMax: xMax,
      pixelWidth: plot.width,
    );
    for (final point in samples) {
      final xFraction = (point.dx - xMin) / (xMax - xMin);
      final yFraction = (point.dy - yMin) / (yMax - yMin);
      final x = controller.plotInvertX
          ? plot.right - xFraction * plot.width
          : plot.left + xFraction * plot.width;
      final y = controller.plotInvertY
          ? plot.top + yFraction * plot.height
          : plot.bottom - yFraction * plot.height;
      if (started) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        started = true;
      }
    }
    if (!started) return;
    canvas.drawPath(
      path,
      Paint()
        ..color = watch.color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawLegend(Canvas canvas, Rect plot, List<WatchItem> watches) {
    var x = plot.left + 10;
    final y = plot.top + 8;
    for (final watch in watches.take(6)) {
      canvas.drawRect(
        Rect.fromLTWH(x, y + 3, 10, 3),
        Paint()..color = watch.color,
      );
      x += 15;
      _text(canvas, watch.symbol.name, Offset(x, y - 3), talMuted, width: 100);
      x += 108;
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset offset,
    TextStyle style, {
    double width = 80,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: style.copyWith(
          fontFamily: talFontFamily,
          fontFamilyFallback: talFontFamilyFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _TelemetryPainter oldDelegate) {
    return oldDelegate.controller != controller;
  }
}

List<Offset> downsampleTelemetrySamples(
  Iterable<Offset> samples, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  final visible = [
    for (final point in samples)
      if (point.dx >= xMin && point.dx <= xMax) point,
  ];
  final bucketCount = math.max(1, pixelWidth.floor());
  if (visible.length <= bucketCount * 2 || xMax <= xMin) return visible;

  final result = <Offset>[];
  var currentBucket = -1;
  Offset? minimum;
  Offset? maximum;
  var minimumIndex = 0;
  var maximumIndex = 0;
  var pointIndex = 0;

  void flushBucket() {
    final low = minimum;
    final high = maximum;
    if (low == null || high == null) return;
    if (minimumIndex <= maximumIndex) {
      _appendDistinctPoint(result, low);
      _appendDistinctPoint(result, high);
    } else {
      _appendDistinctPoint(result, high);
      _appendDistinctPoint(result, low);
    }
  }

  for (final point in visible) {
    final bucket = (((point.dx - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flushBucket();
      currentBucket = bucket;
      minimum = point;
      maximum = point;
      minimumIndex = pointIndex;
      maximumIndex = pointIndex;
    } else {
      if (point.dy < minimum!.dy) {
        minimum = point;
        minimumIndex = pointIndex;
      }
      if (point.dy > maximum!.dy) {
        maximum = point;
        maximumIndex = pointIndex;
      }
    }
    pointIndex += 1;
  }
  flushBucket();
  _appendDistinctPoint(result, visible.last);
  return result;
}

void _appendDistinctPoint(List<Offset> points, Offset point) {
  if (points.isEmpty || points.last != point) points.add(point);
}
