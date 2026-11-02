part of 'analysis_chart_panel.dart';

extension _AnalysisFftPanelBuilder on _AnalysisChartPanelState {
  Widget _buildFftPanel() {
    final signalIndex = _validFftSignalIndex;
    final spectrum = _spectrumForCurrentSelection(signalIndex);
    return _AnalysisFftPanel(
      series: _series,
      signalIndex: signalIndex,
      spectrum: spectrum,
      loading: _fftRequestedKey != null && _fftRequestedKey != _fftCacheKey,
      session: _session,
      onSessionChanged: _commitSession,
    );
  }

  Widget _buildFftToolbar() {
    return _AnalysisFftToolbar(
      series: _series,
      signalIndex: _validFftSignalIndex,
      timeSeriesIndex: _session.fftTimeSeriesIndex,
      onSignalChanged: (index) {
        if (index == null || index == _session.fftSeriesIndex) return;
        _setFftSignalIndex(index);
      },
      onTimeSeriesChanged: (index) {
        final value = index == -1 ? null : index;
        if (value == _session.fftTimeSeriesIndex) return;
        _setFftTimeSeriesIndex(value);
      },
    );
  }

  int? get _validFftSignalIndex {
    final index = _session.fftSeriesIndex;
    if (index != null && index >= 0 && index < _series.length) return index;
    return _series.isEmpty ? null : 0;
  }

  AnalysisSpectrum _spectrumForCurrentSelection(int? signalIndex) {
    if (signalIndex == null) {
      return const AnalysisSpectrum.error('请选择需要分析的信号');
    }
    final timeIndex = _session.fftTimeSeriesIndex;
    final timePoints =
        timeIndex != null && timeIndex >= 0 && timeIndex < _series.length
        ? _series[timeIndex].points
        : null;
    final range = _selectedRange;
    final signal = _series[signalIndex];
    final cacheKey = (
      signal.points,
      timePoints,
      range?.$1,
      range?.$2,
      _session.fftWindow,
      _session.fftRemoveDc,
    );
    if (_fftCacheKey == cacheKey && _fftCache != null) return _fftCache!;
    if (_fftRequestedKey != cacheKey) {
      _fftRequestedKey = cacheKey;
      _fftCache = null;
      unawaited(
        _fftWorker
            .analyze(
              signal.points,
              timePoints: timePoints,
              selectionStart: range?.$1,
              selectionEnd: range?.$2,
              window: _session.fftWindow,
              removeDc: _session.fftRemoveDc,
            )
            .then(
              (spectrum) {
                if (spectrum != null) _acceptFftResult(cacheKey, spectrum);
              },
              onError: (Object error, StackTrace stack) {
                _acceptFftResult(
                  cacheKey,
                  AnalysisSpectrum.error('频谱计算失败：$error'),
                );
              },
            ),
      );
    }
    return const AnalysisSpectrum.error('正在计算频谱…');
  }

  void _invalidateFftData() {
    _fftWorker.clearData();
    _fftCacheKey = _fftRequestedKey = null;
    _fftCache = null;
  }
}

class _AnalysisFftPanel extends StatefulWidget {
  const _AnalysisFftPanel({
    required this.series,
    required this.signalIndex,
    required this.spectrum,
    required this.loading,
    required this.session,
    required this.onSessionChanged,
  });

  final List<AnalysisSeries> series;
  final int? signalIndex;
  final AnalysisSpectrum spectrum;
  final bool loading;
  final AnalysisSession session;
  final VoidCallback onSessionChanged;

  @override
  State<_AnalysisFftPanel> createState() => _AnalysisFftPanelState();
}

class _AnalysisFftPanelState extends State<_AnalysisFftPanel> {
  final MenuController _menuController = MenuController();
  double? _dragStartX;
  Offset? _lastPanPosition;
  Offset? _lastRightZoomPosition;
  Offset? _rightZoomStartPosition;
  Offset? _rightZoomAnchorFraction;
  Offset? _rectangleZoomStart;
  Rect? _rectangleZoom;
  bool _selectionDragging = false;
  AnalysisSelectionDragTarget? _selectionDragTarget;
  bool _middleDragging = false;
  bool _rightZoomDragging = false;
  bool _rightZoomMoved = false;
  PointerDeviceKind _lastPointerKind = PointerDeviceKind.mouse;
  TalMenuAnimationLease? _menuAnimationLease;

  AnalysisSession get session => widget.session;
  bool get _resizingSelectionBoundary =>
      _selectionDragTarget == AnalysisSelectionDragTarget.lowerBound ||
      _selectionDragTarget == AnalysisSelectionDragTarget.upperBound;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signal = widget.signalIndex == null
        ? null
        : widget.series[widget.signalIndex!];
    return Container(
      key: const ValueKey('analysis-fft-panel'),
      color: TalColors.input,
      child: _buildInteractiveChart(signal),
    );
  }

  Widget _buildInteractiveChart(AnalysisSeries? signal) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final bounds = _viewportBounds;
        return MenuAnchor(
          key: const ValueKey('analysis-fft-menu-anchor'),
          controller: _menuController,
          style: Theme.of(context).menuTheme.style,
          consumeOutsideTap: true,
          animated: true,
          onAnimationStatusChanged: _handleMenuAnimationStatus,
          menuChildren: _buildDesktopMenu(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: _handleLongPress,
            child: MouseRegion(
              cursor: _resizingSelectionBoundary
                  ? SystemMouseCursors.resizeLeftRight
                  : _rightZoomDragging
                  ? SystemMouseCursors.zoomIn
                  : _middleDragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.precise,
              child: Listener(
                key: const ValueKey('analysis-fft-interaction'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => _handlePointerDown(event, size),
                onPointerMove: (event) => _handlePointerMove(event, size),
                onPointerUp: (event) => _finishPointerInteraction(size, event),
                onPointerCancel: (_) => _finishPointerInteraction(size, null),
                onPointerSignal: (event) => _handlePointerSignal(event, size),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('analysis-fft-chart'),
                        painter: _AnalysisFftPainter(
                          spectrum: widget.spectrum,
                          signalName: signal?.name ?? '',
                          color: signal?.color ?? TalColors.accent,
                          xMin: bounds.$1,
                          xMax: bounds.$2,
                          yMin: bounds.$3,
                          yMax: bounds.$4,
                          invertX: session.fftInvertX,
                          invertY: session.fftInvertY,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          key: const ValueKey('analysis-fft-selection-layer'),
                          painter: _AnalysisSelectionPainter(
                            xMin: bounds.$1,
                            xMax: bounds.$2,
                            selectionStart: session.fftSelectionStart,
                            selectionEnd: session.fftSelectionEnd,
                            invertX: session.fftInvertX,
                          ),
                        ),
                      ),
                    ),
                    if (_rectangleZoom case final rectangle?)
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _AnalysisRectangleZoomPainter(rectangle),
                        ),
                      ),
                    if (widget.spectrum.error case final error?)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            error,
                            key: widget.loading
                                ? const ValueKey('analysis-fft-loading')
                                : null,
                            style: talMuted,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    else
                      Positioned(
                        top: 8,
                        right: 12,
                        child: _buildSpectrumSummary(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSpectrumSummary() {
    final spectrum = widget.spectrum;
    final selectionStart = session.fftSelectionStart;
    final selectionEnd = session.fftSelectionEnd;
    final selection = selectionStart == null || selectionEnd == null
        ? ''
        : '\n已选 ${_formatFftValue(math.min(selectionStart, selectionEnd))}'
              '–${_formatFftValue(math.max(selectionStart, selectionEnd))} Hz';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: TalColors.surface.withAlpha(220),
        border: Border.all(color: TalColors.borderSoft),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          '峰值 ${_formatFftValue(spectrum.peakFrequency)} Hz  '
          '幅值 ${_formatFftValue(spectrum.peakAmplitude)}\n'
          'Fs ${_formatFftValue(spectrum.sampleRate)} Hz  '
          'N ${spectrum.sampleCount}  '
          'Δf ${_formatFftValue(spectrum.frequencyResolution)} Hz'
          '${spectrum.resampled ? '  · 已重采样' : ''}$selection',
          style: talMuted,
          textAlign: TextAlign.right,
        ),
      ),
    );
  }

  List<Widget> _buildDesktopMenu() => [
    MenuItemButton(
      key: const ValueKey('analysis-fft-view-all'),
      onPressed: _showAll,
      child: const Text('View All'),
    ),
    MenuItemButton(
      key: const ValueKey('analysis-fft-select-all'),
      onPressed: _selectAll,
      child: const Text('Select All'),
    ),
    MenuItemButton(
      key: const ValueKey('analysis-fft-clear-selection'),
      onPressed: _clearSelection,
      child: const Text('Clear Selection'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-fft-x-axis'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: _buildAxisMenu(xAxis: true),
      child: const Text('X Axis'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-fft-y-axis'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: _buildAxisMenu(xAxis: false),
      child: const Text('Y Axis'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-fft-mouse-mode'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: [
        RadioMenuButton<AnalysisMouseMode>(
          value: AnalysisMouseMode.threeButton,
          groupValue: session.fftMouseMode,
          onChanged: _setMouseMode,
          child: const Text('3 Button'),
        ),
        RadioMenuButton<AnalysisMouseMode>(
          value: AnalysisMouseMode.rectangle,
          groupValue: session.fftMouseMode,
          onChanged: _setMouseMode,
          child: const Text('1 Button'),
        ),
      ],
      child: const Text('Mouse Mode'),
    ),
  ];

  List<Widget> _buildAxisMenu({required bool xAxis}) => [
    MenuItemButton(
      onPressed: () => _resetAxis(xAxis: xAxis),
      child: const Text('Auto'),
    ),
    MenuItemButton(
      onPressed: () => unawaited(_showAxisSettings(xAxis: xAxis)),
      child: const Text('Manual…'),
    ),
  ];

  void _setMouseMode(AnalysisMouseMode? mode) {
    if (mode == null || mode == session.fftMouseMode) return;
    setState(() {
      session.fftMouseMode = mode;
      _rectangleZoom = null;
      _rectangleZoomStart = null;
    });
    widget.onSessionChanged();
  }

  void _showAll() {
    setState(() {
      session.resetFftViewport();
      _resetTransientInteraction();
    });
    widget.onSessionChanged();
  }

  void _selectAll() {
    final bounds = _dataBounds;
    setState(() {
      session.fftSelectionStart = bounds.$1;
      session.fftSelectionEnd = bounds.$2;
      _selectionDragTarget = null;
    });
    widget.onSessionChanged();
  }

  void _clearSelection() {
    setState(() {
      session.fftSelectionStart = null;
      session.fftSelectionEnd = null;
      _selectionDragTarget = null;
    });
    widget.onSessionChanged();
  }

  void _resetAxis({required bool xAxis}) {
    setState(() {
      if (xAxis) {
        session.fftViewXMin = null;
        session.fftViewXMax = null;
      } else {
        session.fftViewYMin = null;
        session.fftViewYMax = null;
      }
    });
    widget.onSessionChanged();
  }

  Future<void> _showAxisSettings({required bool xAxis}) async {
    final bounds = _viewportBounds;
    final result = await showTalDialog<AxisSettings>(
      context: context,
      builder: (context) => PlotAxisSettingsDialog(
        xAxis: xAxis,
        automatic: xAxis
            ? session.fftViewXMin == null
            : session.fftViewYMin == null,
        minimum: xAxis ? bounds.$1 : bounds.$3,
        maximum: xAxis ? bounds.$2 : bounds.$4,
        mouseEnabled: xAxis
            ? session.fftMouseXEnabled
            : session.fftMouseYEnabled,
        inverted: xAxis ? session.fftInvertX : session.fftInvertY,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (xAxis) {
        session.fftMouseXEnabled = result.mouseEnabled;
        session.fftInvertX = result.inverted;
        session.fftViewXMin = result.automatic ? null : result.minimum;
        session.fftViewXMax = result.automatic ? null : result.maximum;
      } else {
        session.fftMouseYEnabled = result.mouseEnabled;
        session.fftInvertY = result.inverted;
        session.fftViewYMin = result.automatic ? null : result.minimum;
        session.fftViewYMax = result.automatic ? null : result.maximum;
      }
    });
    widget.onSessionChanged();
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    _lastPointerKind = event.kind;
    if (_menuController.isOpen && event.buttons & kSecondaryMouseButton == 0) {
      _menuController.close();
      return;
    }
    if (event.kind != PointerDeviceKind.mouse ||
        !_analysisPlotRect(size).contains(event.localPosition)) {
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) {
      final plot = _analysisPlotRect(size);
      setState(() {
        _rightZoomDragging = true;
        _lastRightZoomPosition = event.localPosition;
        _rightZoomStartPosition = event.localPosition;
        _rightZoomMoved = false;
        _rightZoomAnchorFraction = Offset(
          _xFractionForPosition(event.localPosition.dx, plot),
          _yFractionForPosition(event.localPosition.dy, plot),
        );
      });
      return;
    }
    if (event.buttons & kMiddleMouseButton != 0) {
      setState(() {
        _middleDragging = true;
        _lastPanPosition = event.localPosition;
      });
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0) return;
    if (session.fftMouseMode == AnalysisMouseMode.rectangle) {
      setState(() {
        _rectangleZoomStart = event.localPosition;
        _rectangleZoom = Rect.fromPoints(
          event.localPosition,
          event.localPosition,
        );
      });
      return;
    }
    _startSelection(event.localPosition.dx, size);
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) {
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
      setState(() {
        _rectangleZoom = Rect.fromPoints(rectangleStart, event.localPosition);
      });
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
    final plot = _analysisPlotRect(size);
    if (plot.width <= 1 || plot.height <= 1) return;
    final bounds = _viewportBounds;
    final data = _dataBounds;
    final delta = event.localPosition - previous;
    final xShift =
        (session.fftInvertX ? 1 : -1) *
        delta.dx /
        plot.width *
        (bounds.$2 - bounds.$1);
    final yShift =
        (session.fftInvertY ? -1 : 1) *
        delta.dy /
        plot.height *
        (bounds.$4 - bounds.$3);
    final xWindow = session.fftMouseXEnabled
        ? clampCartesianWindow(
            bounds.$1 + xShift,
            bounds.$2 + xShift,
            data.$1,
            data.$2,
          )
        : (bounds.$1, bounds.$2);
    final yWindow = session.fftMouseYEnabled
        ? clampCartesianWindow(
            bounds.$3 + yShift,
            bounds.$4 + yShift,
            data.$3,
            data.$4,
          )
        : (bounds.$3, bounds.$4);
    setState(() {
      _lastPanPosition = event.localPosition;
      _setViewport(xWindow, yWindow);
    });
  }

  void _updateRightButtonZoom(Offset position) {
    final previous = _lastRightZoomPosition;
    final anchor = _rightZoomAnchorFraction;
    if (previous == null || anchor == null) return;
    final delta = position - previous;
    if (delta == Offset.zero) return;
    final bounds = _viewportBounds;
    final data = _dataBounds;
    final xWindow = session.fftMouseXEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$1,
            maximum: bounds.$2,
            dataMinimum: data.$1,
            dataMaximum: data.$2,
            anchorFraction: anchor.dx,
            scale: math.pow(1.02, -delta.dx).toDouble(),
          )
        : (bounds.$1, bounds.$2);
    final yWindow = session.fftMouseYEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$3,
            maximum: bounds.$4,
            dataMinimum: data.$3,
            dataMaximum: data.$4,
            anchorFraction: anchor.dy,
            scale: math.pow(1.02, delta.dy).toDouble(),
          )
        : (bounds.$3, bounds.$4);
    setState(() {
      _lastRightZoomPosition = position;
      _setViewport(xWindow, yWindow);
    });
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    final plot = _analysisPlotRect(size);
    if (!plot.contains(event.localPosition)) return;
    final bounds = _viewportBounds;
    final data = _dataBounds;
    final scale = event.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
    final xWindow = session.fftMouseXEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$1,
            maximum: bounds.$2,
            dataMinimum: data.$1,
            dataMaximum: data.$2,
            anchorFraction: _xFractionForPosition(event.localPosition.dx, plot),
            scale: scale,
          )
        : (bounds.$1, bounds.$2);
    final yWindow = session.fftMouseYEnabled
        ? zoomCartesianWindow(
            minimum: bounds.$3,
            maximum: bounds.$4,
            dataMinimum: data.$3,
            dataMaximum: data.$4,
            anchorFraction: _yFractionForPosition(event.localPosition.dy, plot),
            scale: scale,
          )
        : (bounds.$3, bounds.$4);
    setState(() => _setViewport(xWindow, yWindow));
    widget.onSessionChanged();
  }

  void _finishPointerInteraction(Size size, PointerUpEvent? event) {
    final wasSelecting = _selectionDragging;
    final rectangle = _rectangleZoom;
    final openMenu =
        event != null &&
        _rightZoomDragging &&
        !_rightZoomMoved &&
        event.kind == PointerDeviceKind.mouse;
    setState(() {
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
        _dragStartX = null;
        _selectionDragTarget = null;
        final start = session.fftSelectionStart;
        final end = session.fftSelectionEnd;
        if (start != null && end != null && (start - end).abs() < 1e-9) {
          session.fftSelectionStart = null;
          session.fftSelectionEnd = null;
        } else if (start != null && end != null) {
          session.fftSelectionStart = math.min(start, end);
          session.fftSelectionEnd = math.max(start, end);
        }
      } else if (rectangle != null) {
        _applyRectangleZoom(rectangle, size);
      }
    });
    widget.onSessionChanged();
    if (openMenu) _openDesktopMenu(event.localPosition);
  }

  void _startSelection(double position, Size size) {
    final range = _selectedRange;
    final target = _selectionTargetAt(position, size, range);
    _selectionDragging = true;
    if (range != null && target != null) {
      setState(() {
        _selectionDragTarget = target;
        _dragStartX = null;
        session.fftSelectionStart = range.$1;
        session.fftSelectionEnd = range.$2;
      });
      return;
    }
    final value = _xForPosition(position, size);
    setState(() {
      _selectionDragTarget = AnalysisSelectionDragTarget.newRange;
      _dragStartX = value;
      session.fftSelectionStart = value;
      session.fftSelectionEnd = value;
    });
  }

  void _updateSelection(double position, Size size) {
    final value = _xForPosition(position, size);
    setState(() {
      switch (_selectionDragTarget) {
        case AnalysisSelectionDragTarget.newRange:
          if (_dragStartX == null) return;
          session.fftSelectionEnd = value;
        case AnalysisSelectionDragTarget.lowerBound:
          final upper = session.fftSelectionEnd;
          if (upper == null) return;
          session.fftSelectionStart = math.min(value, upper);
        case AnalysisSelectionDragTarget.upperBound:
          final lower = session.fftSelectionStart;
          if (lower == null) return;
          session.fftSelectionEnd = math.max(value, lower);
        case null:
          return;
      }
    });
  }

  (double, double)? get _selectedRange {
    final start = session.fftSelectionStart;
    final end = session.fftSelectionEnd;
    if (start == null || end == null) return null;
    return (math.min(start, end), math.max(start, end));
  }

  AnalysisSelectionDragTarget? _selectionTargetAt(
    double position,
    Size size,
    (double, double)? range,
  ) {
    if (range == null) return null;
    final viewport = _interactionViewport(_analysisPlotRect(size));
    final lowerDistance = (position - viewport.mapX(range.$1)).abs();
    final upperDistance = (position - viewport.mapX(range.$2)).abs();
    if (math.min(lowerDistance, upperDistance) >
        AnalysisPlotInteraction.selectionHandleHitSlop) {
      return null;
    }
    return lowerDistance <= upperDistance
        ? AnalysisSelectionDragTarget.lowerBound
        : AnalysisSelectionDragTarget.upperBound;
  }

  void _applyRectangleZoom(Rect rectangle, Size size) {
    final plot = _analysisPlotRect(size);
    final clipped = rectangle.intersect(plot);
    if (clipped.width < 5 || clipped.height < 5) return;
    final viewport = _interactionViewport(plot);
    final left = viewport.unmapX(clipped.left);
    final right = viewport.unmapX(clipped.right);
    final top = viewport.unmapY(clipped.top);
    final bottom = viewport.unmapY(clipped.bottom);
    if (session.fftMouseXEnabled) {
      session.fftViewXMin = math.min(left, right);
      session.fftViewXMax = math.max(left, right);
    }
    if (session.fftMouseYEnabled) {
      session.fftViewYMin = math.min(top, bottom);
      session.fftViewYMax = math.max(top, bottom);
    }
  }

  void _setViewport((double, double) xWindow, (double, double) yWindow) {
    session.fftViewXMin = xWindow.$1;
    session.fftViewXMax = xWindow.$2;
    session.fftViewYMin = yWindow.$1;
    session.fftViewYMax = yWindow.$2;
  }

  (double, double, double, double) get _dataBounds {
    final points = widget.spectrum.points;
    final xMaximum = points.isEmpty ? 1.0 : math.max(1e-9, points.last.x);
    final yMaximum = points.isEmpty
        ? 0.0
        : math.max(widget.spectrum.peakAmplitude, points.first.y);
    return (0.0, xMaximum, 0.0, yMaximum <= 0 ? 1.0 : yMaximum * 1.12);
  }

  (double, double, double, double) get _viewportBounds {
    final data = _dataBounds;
    var xMinimum = session.fftViewXMin ?? data.$1;
    var xMaximum = session.fftViewXMax ?? data.$2;
    var yMinimum = session.fftViewYMin ?? data.$3;
    var yMaximum = session.fftViewYMax ?? data.$4;
    if (xMaximum <= xMinimum) {
      xMinimum = data.$1;
      xMaximum = data.$2;
    }
    if (yMaximum <= yMinimum) {
      yMinimum = data.$3;
      yMaximum = data.$4;
    }
    return (xMinimum, xMaximum, yMinimum, yMaximum);
  }

  CartesianPlotViewport _interactionViewport(Rect plot) {
    final bounds = _viewportBounds;
    return CartesianPlotViewport(
      plot: plot,
      xMin: bounds.$1,
      xMax: bounds.$2,
      yMin: bounds.$3,
      yMax: bounds.$4,
      invertX: session.fftInvertX,
      invertY: session.fftInvertY,
    );
  }

  double _xForPosition(double position, Size size) =>
      _interactionViewport(_analysisPlotRect(size)).unmapX(position);

  double _xFractionForPosition(double position, Rect plot) =>
      _interactionViewport(plot).xFractionAt(position);

  double _yFractionForPosition(double position, Rect plot) =>
      _interactionViewport(plot).yFractionAt(position);

  void _resetTransientInteraction() {
    _dragStartX = null;
    _lastPanPosition = null;
    _lastRightZoomPosition = null;
    _rightZoomStartPosition = null;
    _rightZoomAnchorFraction = null;
    _rectangleZoomStart = null;
    _rectangleZoom = null;
    _selectionDragging = false;
    _selectionDragTarget = null;
    _middleDragging = false;
    _rightZoomDragging = false;
    _rightZoomMoved = false;
  }

  void _openDesktopMenu(Offset position) {
    if (!_menuController.isOpen && _menuAnimationLease == null) {
      _menuAnimationLease = beginTalMenuAnimation();
    }
    _menuController.open(position: position);
  }

  void _handleMenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _releaseMenuAnimation();
  }

  void _releaseMenuAnimation() {
    _menuAnimationLease?.release();
    _menuAnimationLease = null;
  }

  void _handleLongPress(LongPressStartDetails details) {
    if (_lastPointerKind == PointerDeviceKind.mouse) return;
    unawaited(_showTouchMenu(details.globalPosition));
  }

  Future<void> _showTouchMenu(Offset globalPosition) async {
    if (_menuController.isOpen) _menuController.close();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);
    final action = await showTalContextMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        overlay.size.width - local.dx,
        overlay.size.height - local.dy,
      ),
      touchOptimized: true,
      items: [
        _analysisPopupItem(value: 'all', label: '显示全部', touchOptimized: true),
        _analysisPopupItem(
          value: 'select-all',
          label: '选择全部',
          touchOptimized: true,
        ),
        _analysisPopupItem(
          value: 'clear-selection',
          label: '取消选择',
          touchOptimized: true,
        ),
        const PopupMenuDivider(),
        _analysisPopupItem(value: 'x', label: 'X 轴详细设置…', touchOptimized: true),
        _analysisPopupItem(value: 'y', label: 'Y 轴详细设置…', touchOptimized: true),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'all':
        _showAll();
      case 'select-all':
        _selectAll();
      case 'clear-selection':
        _clearSelection();
      case 'x':
        await _showAxisSettings(xAxis: true);
      case 'y':
        await _showAxisSettings(xAxis: false);
    }
  }
}

class _AnalysisFftToolbar extends StatelessWidget {
  const _AnalysisFftToolbar({
    required this.series,
    required this.signalIndex,
    required this.timeSeriesIndex,
    required this.onSignalChanged,
    required this.onTimeSeriesChanged,
  });

  final List<AnalysisSeries> series;
  final int? signalIndex;
  final int? timeSeriesIndex;
  final ValueChanged<int?> onSignalChanged;
  final ValueChanged<int?> onTimeSeriesChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: TalUiTheme.of(context).targetExtent(34),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (constraints.maxWidth >= 430) ...[
              const SizedBox(width: 8),
              const Icon(Icons.graphic_eq, size: 15, color: TalColors.accent),
              const SizedBox(width: 5),
              const Text('FFT', style: talStrong),
            ],
            const Spacer(),
            SizedBox(
              width: 192,
              child: _AnalysisFftSelector<int>(
                label: 'Y轴',
                key: const ValueKey('analysis-fft-signal-select'),
                value: signalIndex,
                values: [for (final (index, _) in series.indexed) index],
                valueLabel: (index) => series[index].name,
                onChanged: onSignalChanged,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 132,
              child: _AnalysisFftSelector<int>(
                label: '时间',
                key: const ValueKey('analysis-fft-time-select'),
                value: timeSeriesIndex ?? -1,
                values: [-1, for (final (index, _) in series.indexed) index],
                valueLabel: (index) => index == -1 ? 'X 轴' : series[index].name,
                onChanged: onTimeSeriesChanged,
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

class _AnalysisFftSelector<T> extends StatelessWidget {
  const _AnalysisFftSelector({
    required this.label,
    required this.value,
    required this.values,
    required this.valueLabel,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T? value;
  final List<T> values;
  final String Function(T value) valueLabel;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(label, style: talMuted, textAlign: TextAlign.right),
        const SizedBox(width: 6),
        Flexible(
          child: value == null
              ? const SizedBox.shrink()
              : TalDropdown<T>(
                  key: ValueKey('analysis-fft-$label-dropdown'),
                  value: value as T,
                  values: values,
                  label: valueLabel,
                  onChanged: (next) => onChanged(next),
                ),
        ),
      ],
    );
  }
}

class _AnalysisFftPainter extends CustomPainter {
  const _AnalysisFftPainter({
    required this.spectrum,
    required this.signalName,
    required this.color,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.invertX,
    required this.invertY,
  });

  final AnalysisSpectrum spectrum;
  final String signalName;
  final Color color;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final bool invertX;
  final bool invertY;

  @override
  void paint(Canvas canvas, Size size) {
    final points = spectrum.points;
    final plot = _analysisPlotRect(size);
    final viewport = CartesianPlotViewport(
      plot: plot,
      xMin: 0,
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
    if (points.isNotEmpty) {
      canvas.save();
      canvas.clipRect(plot);
      renderer.drawPolyline(
        downsampleAnalysisPoints(
          points,
          xMin: xMin,
          xMax: xMax,
          pixelWidth: plot.width,
        ),
        color,
      );
      canvas.restore();
    }
    renderer.drawAxisLabels(
      xAxisLabel: '频率 (Hz)',
      yLabelOffset: 50,
      xTickOffset: 5,
      xAxisLabelOffset: 15,
    );
    if (signalName.isNotEmpty) {
      renderer.drawLegend([
        CartesianLegendItem(label: signalName, color: color),
      ]);
    }
  }

  @override
  bool shouldRepaint(covariant _AnalysisFftPainter oldDelegate) =>
      oldDelegate.spectrum != spectrum ||
      oldDelegate.signalName != signalName ||
      oldDelegate.color != color ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.yMin != yMin ||
      oldDelegate.yMax != yMax ||
      oldDelegate.invertX != invertX ||
      oldDelegate.invertY != invertY;
}

String _formatFftValue(double value) {
  final absolute = value.abs();
  if (absolute >= 10000 || (absolute > 0 && absolute < 0.001)) {
    return value.toStringAsExponential(2);
  }
  if (absolute >= 100) return value.toStringAsFixed(1);
  if (absolute >= 1) return value.toStringAsFixed(2);
  return value.toStringAsFixed(4);
}
