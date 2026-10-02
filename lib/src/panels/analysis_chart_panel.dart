part of 'panels.dart';

enum _AnalysisImportSource { csv, realtime }

enum _AnalysisSelectionDragTarget { newRange, lowerBound, upperBound }

const _analysisSelectionHandleHitSlop = 12.0;

const _analysisStatsColumnLabels = <String>[
  '曲线',
  '样本数',
  '最小值',
  '最大值',
  '平均值',
  '峰峰值',
  '是否绘制',
];

Rect _analysisPlotRect(Size size) => Rect.fromLTRB(
  54,
  12,
  math.max(55, size.width - 14),
  math.max(13, size.height - 32),
);

class _AnalysisChartPanel extends StatefulWidget {
  const _AnalysisChartPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_AnalysisChartPanel> createState() => _AnalysisChartPanelState();
}

class _AnalysisChartPanelState extends State<_AnalysisChartPanel> {
  final MenuController _plotMenuController = MenuController();
  late AnalysisSession _session;
  late final ResizableTableLayout _statsTableLayout;
  late final ScrollController _statsHorizontalScrollController;
  final ValueNotifier<int> _chartChanges = ValueNotifier<int>(0);
  final ValueNotifier<int> _statsChanges = ValueNotifier<int>(0);
  Object? _fftCacheKey;
  Object? _fftRequestedKey;
  AnalysisSpectrum? _fftCache;
  final FftAnalysisWorker _fftWorker = FftAnalysisWorker();
  late List<AnalysisSeries> _fftSourceSeries;
  double? _dragStartX;
  Offset? _lastPanPosition;
  Offset? _lastRightZoomPosition;
  Offset? _rightZoomStartPosition;
  Offset? _rightZoomAnchorFraction;
  Rect? _rectangleZoom;
  Offset? _rectangleZoomStart;
  bool _rightZoomMoved = false;
  bool _selectionDragging = false;
  _AnalysisSelectionDragTarget? _selectionDragTarget;
  bool _middleDragging = false;
  bool _rightZoomDragging = false;
  TalMenuAnimationLease? _plotMenuAnimationLease;
  PointerDeviceKind _lastPlotPointerKind = PointerDeviceKind.mouse;

  TakeALookController get controller => widget.controller;
  double get _statsHeight => _session.statsHeight;
  set _statsHeight(double value) => _session.statsHeight = value;
  List<AnalysisSeries> get _series => _session.series;
  List<bool> get _seriesVisibility => _session.seriesVisibility;
  set _seriesVisibility(List<bool> value) => _session.seriesVisibility = value;
  Set<int> get _selectedColumns => _session.selectedColumns;
  Set<int> get _hiddenColumns => _session.hiddenColumns;
  String get _sourceLabel => _session.sourceLabel;
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
  set _mouseMode(AnalysisMouseMode value) => _session.mouseMode = value;
  bool get _mouseXEnabled => _session.mouseXEnabled;
  bool get _mouseYEnabled => _session.mouseYEnabled;
  bool get _invertX => _session.invertX;
  bool get _invertY => _session.invertY;
  bool get _resizingSelectionBoundary =>
      _selectionDragTarget == _AnalysisSelectionDragTarget.lowerBound ||
      _selectionDragTarget == _AnalysisSelectionDragTarget.upperBound;

  @override
  void initState() {
    super.initState();
    _session = controller.analysisSession;
    _fftSourceSeries = _series;
    _statsTableLayout = ResizableTableLayout(
      widths: _session.statsColumnWidths,
      minimumWidths: const [100, 70, 80, 80, 80, 80, 72],
      rowHeight: _session.statsRowHeight,
    );
    _statsHorizontalScrollController = ScrollController(
      initialScrollOffset: _session.statsHorizontalOffset,
    )..addListener(_rememberStatsHorizontalOffset);
    controller.analysisChanges.addListener(_handleAnalysisSessionChanged);
  }

  @override
  void didUpdateWidget(covariant _AnalysisChartPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.analysisChanges.removeListener(
      _handleAnalysisSessionChanged,
    );
    _invalidateFftData();
    _session = controller.analysisSession;
    _fftSourceSeries = _series;
    _restoreStatsLayout();
    controller.analysisChanges.addListener(_handleAnalysisSessionChanged);
  }

  void _handleAnalysisSessionChanged() {
    if (!mounted) return;
    if (!identical(_fftSourceSeries, _series)) {
      _invalidateFftData();
      _fftSourceSeries = _series;
    } else if (!_session.fftVisible) {
      _fftWorker.cancel();
      _fftRequestedKey = null;
    }
    _restoreStatsLayout();
    setState(() {
      _chartChanges.value += 1;
      _statsChanges.value += 1;
    });
  }

  void _acceptFftResult(Object key, AnalysisSpectrum spectrum) {
    if (!mounted || !_session.fftVisible || _fftRequestedKey != key) return;
    setState(() {
      _fftCacheKey = key;
      _fftCache = spectrum;
    });
  }

  void _restoreStatsLayout() {
    _statsTableLayout.restore(
      widths: _session.statsColumnWidths,
      rowHeight: _session.statsRowHeight,
    );
  }

  void _rememberStatsHorizontalOffset() {
    if (_statsHorizontalScrollController.hasClients) {
      _session.statsHorizontalOffset = _statsHorizontalScrollController.offset;
    }
  }

  void _rememberStatsLayout() {
    _session.statsColumnWidths = List<double>.of(_statsTableLayout.widths);
    _session.statsRowHeight = _statsTableLayout.rowHeight;
  }

  void _commitSession({bool includeData = false}) {
    _rememberStatsHorizontalOffset();
    _rememberStatsLayout();
    controller.commitAnalysisSession(includeData: includeData);
  }

  @override
  void dispose() {
    _fftWorker.dispose();
    _releasePlotMenuAnimation();
    controller.analysisChanges.removeListener(_handleAnalysisSessionChanged);
    _rememberStatsHorizontalOffset();
    _rememberStatsLayout();
    _statsHorizontalScrollController.removeListener(
      _rememberStatsHorizontalOffset,
    );
    _statsHorizontalScrollController.dispose();
    _chartChanges.dispose();
    _statsChanges.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(),
        Expanded(
          child: _series.isEmpty ? _buildEmptyState() : _buildAnalysisBody(),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: TalUiTheme.of(context).controlHeight + 16,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: TalColors.surface,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: Row(
        children: [
          Text('分析图表', style: talStrong),
          if (_sourceLabel.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text('· $_sourceLabel · ${_series.length} 条曲线', style: talMuted),
          ],
          const Spacer(),
          if (_series.isNotEmpty) ...[
            TalButton.icon(
              key: const ValueKey('analysis-fft-toggle'),
              style: _session.fftVisible
                  ? talSelectedOutlinedButtonStyle
                  : null,
              onPressed: _toggleFft,
              icon: const Icon(Icons.graphic_eq, size: 16),
              label: const Text('FFT'),
            ),
            const SizedBox(width: 8),
          ],
          _importButton(),
          if (_series.isNotEmpty) ...[
            const SizedBox(width: 8),
            TalButton(
              onPressed: () {
                setState(_session.clearData);
                _commitSession(includeData: true);
              },
              child: const Text('清除'),
            ),
          ],
        ],
      ),
    );
  }

  void _toggleFft() {
    setState(() {
      _session.fftVisible = !_session.fftVisible;
      if (_session.fftVisible) {
        final selected = _session.selectedSeriesIndex;
        if (selected != null && selected >= 0 && selected < _series.length) {
          _session.fftSeriesIndex = selected;
        }
      }
    });
    _commitSession();
  }

  void _setFftSignalIndex(int index) {
    if (index == _session.fftSeriesIndex) return;
    setState(() {
      _session.fftSeriesIndex = index;
      _session.fftSelectionStart = null;
      _session.fftSelectionEnd = null;
      _session.resetFftViewport();
      _fftCacheKey = null;
      _fftRequestedKey = null;
    });
    _commitSession();
  }

  void _setFftTimeSeriesIndex(int? index) {
    if (index == _session.fftTimeSeriesIndex) return;
    setState(() {
      _session.fftTimeSeriesIndex = index;
      _session.fftSelectionStart = null;
      _session.fftSelectionEnd = null;
      _session.resetFftViewport();
      _fftCacheKey = null;
      _fftRequestedKey = null;
    });
    _commitSession();
  }

  Widget _importButton() {
    return TalPopupMenuButton<_AnalysisImportSource>(
      tooltip: '导入分析数据',
      onSelected: _handleImport,
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _AnalysisImportSource.csv,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.upload_file_outlined),
            title: Text('本地 CSV'),
            subtitle: Text('选择一个 CSV 文件'),
          ),
        ),
        PopupMenuItem(
          value: _AnalysisImportSource.realtime,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.sensors_outlined),
            title: Text('当前实时数据'),
            subtitle: Text('使用当前采样缓存'),
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.file_open_outlined, size: 16),
          const SizedBox(width: 7),
          Text(_series.isEmpty ? '导入数据' : '重新导入'),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.analytics_outlined, size: 42, color: TalColors.muted),
          const SizedBox(height: 12),
          const Text('导入一段数据开始分析', style: talStrong),
          const SizedBox(height: 6),
          const Text('支持本地 CSV，或直接使用当前实时采样缓存', style: talMuted),
          const SizedBox(height: 16),
          _importButton(),
        ],
      ),
    );
  }

  Widget _buildAnalysisBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxStatsHeight = math.max(64.0, constraints.maxHeight - 140);
        final minStatsHeight = math.min(88.0, maxStatsHeight);
        final statsHeight = _statsHeight
            .clamp(minStatsHeight, maxStatsHeight)
            .toDouble();
        return Column(
          children: [
            _buildChartToolbar(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: _session.fftVisible
                    ? Row(
                        key: const ValueKey('analysis-fft-split-view'),
                        children: [
                          Expanded(child: _buildTimeDomainChart()),
                          Container(width: 1, color: TalColors.panelBorder),
                          Expanded(child: _buildFftPanel()),
                        ],
                      )
                    : _buildTimeDomainChart(),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _statsChanges,
              builder: (context, _, _) {
                final selection = _selectedRange;
                return _buildStats(
                  selection?.$1,
                  selection?.$2,
                  height: statsHeight,
                  minimumHeight: minStatsHeight,
                  maximumHeight: maxStatsHeight,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildTimeDomainChart() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return ValueListenableBuilder<int>(
          valueListenable: _chartChanges,
          builder: (context, _, _) {
            final bounds = _viewportBounds;
            final selection = _selectedRange;
            return MenuAnchor(
              key: const ValueKey('analysis-plot-menu-anchor'),
              controller: _plotMenuController,
              style: Theme.of(context).menuTheme.style,
              consumeOutsideTap: true,
              animated: true,
              onAnimationStatusChanged: _handlePlotMenuAnimationStatus,
              menuChildren: _buildPlotDesktopMenu(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: _handlePlotLongPress,
                child: MouseRegion(
                  cursor: _resizingSelectionBoundary
                      ? SystemMouseCursors.resizeLeftRight
                      : _rightZoomDragging
                      ? SystemMouseCursors.zoomIn
                      : _middleDragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.precise,
                  child: Listener(
                    key: const ValueKey('analysis-chart-interaction'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) => _handlePointerDown(event, size),
                    onPointerMove: (event) => _handlePointerMove(event, size),
                    onPointerUp: (event) =>
                        _finishPointerInteraction(size, event),
                    onPointerCancel: (_) =>
                        _finishPointerInteraction(size, null),
                    onPointerSignal: (event) =>
                        _handlePointerSignal(event, size),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('analysis-chart-series-layer'),
                            painter: _AnalysisChartPainter(
                              series: _series,
                              seriesVisibility: _seriesVisibility,
                              xMin: bounds.$1,
                              xMax: bounds.$2,
                              yMin: bounds.$3,
                              yMax: bounds.$4,
                              invertX: _invertX,
                              invertY: _invertY,
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              key: const ValueKey(
                                'analysis-chart-selection-layer',
                              ),
                              painter: _AnalysisSelectionPainter(
                                xMin: bounds.$1,
                                xMax: bounds.$2,
                                selectionStart: selection?.$1,
                                selectionEnd: selection?.$2,
                                invertX: _invertX,
                              ),
                            ),
                          ),
                        ),
                        if (_rectangleZoom case final rect?)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _AnalysisRectangleZoomPainter(rect),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  (double, double)? get _selectedRange {
    return _session.selectedRange;
  }

  Widget _buildChartToolbar() {
    return Container(
      height: TalUiTheme.of(context).targetExtent(34),
      color: TalColors.surfaceAlt,
      child: Row(
        children: [
          const Expanded(
            child: Row(
              children: [
                SizedBox(width: 8),
                Icon(
                  Icons.analytics_outlined,
                  key: ValueKey('analysis-data-heading-icon'),
                  size: 15,
                  color: TalColors.accent,
                ),
                SizedBox(width: 5),
                Text(
                  '数据',
                  key: ValueKey('analysis-data-heading'),
                  style: talStrong,
                ),
              ],
            ),
          ),
          if (_session.fftVisible) ...[
            const VerticalDivider(width: 1, color: TalColors.borderSoft),
            Expanded(child: _buildFftToolbar()),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildPlotDesktopMenu() => [
    MenuItemButton(
      key: const ValueKey('analysis-plot-view-all'),
      onPressed: _showAllAnalysisData,
      child: const Text('View All'),
    ),
    MenuItemButton(
      key: const ValueKey('analysis-plot-select-all'),
      onPressed: _selectAllAnalysisRange,
      child: const Text('Select All'),
    ),
    MenuItemButton(
      key: const ValueKey('analysis-plot-clear-selection'),
      onPressed: _clearAnalysisSelection,
      child: const Text('Clear Selection'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-plot-x-axis'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: _buildAxisMenu(xAxis: true),
      child: const Text('X Axis'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-plot-y-axis'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: _buildAxisMenu(xAxis: false),
      child: const Text('Y Axis'),
    ),
    SubmenuButton(
      key: const ValueKey('analysis-plot-mouse-mode'),
      menuStyle: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
      animated: true,
      menuChildren: [
        RadioMenuButton<AnalysisMouseMode>(
          value: AnalysisMouseMode.threeButton,
          groupValue: _mouseMode,
          onChanged: _setAnalysisMouseMode,
          child: const Text('3 Button'),
        ),
        RadioMenuButton<AnalysisMouseMode>(
          value: AnalysisMouseMode.rectangle,
          groupValue: _mouseMode,
          onChanged: _setAnalysisMouseMode,
          child: const Text('1 Button'),
        ),
      ],
      child: const Text('Mouse Mode'),
    ),
  ];

  List<Widget> _buildAxisMenu({required bool xAxis}) => [
    MenuItemButton(
      onPressed: () => _resetAnalysisAxis(xAxis: xAxis),
      child: const Text('Auto'),
    ),
    MenuItemButton(
      onPressed: () => unawaited(_showAnalysisAxisSettings(xAxis: xAxis)),
      child: const Text('Manual…'),
    ),
  ];

  void _setAnalysisMouseMode(AnalysisMouseMode? mode) {
    if (mode == null || mode == _mouseMode) return;
    _mouseMode = mode;
    _rectangleZoom = null;
    _rectangleZoomStart = null;
    _notifyChartChanged();
    _commitSession();
  }

  void _showAllAnalysisData() {
    _resetViewport();
    _notifyChartChanged();
    _commitSession();
  }

  void _selectAllAnalysisRange() {
    final bounds = _dataBounds;
    _selectionStart = bounds.$1;
    _selectionEnd = bounds.$2;
    _updateSelectionStats();
    _notifyChartChanged();
    _statsChanges.value += 1;
    _commitSession();
  }

  void _clearAnalysisSelection() {
    _selectionStart = null;
    _selectionEnd = null;
    _session.selectionStats = const [];
    _notifyChartChanged();
    _statsChanges.value += 1;
    _commitSession();
  }

  void _resetAnalysisAxis({required bool xAxis}) {
    if (xAxis) {
      _viewXMin = null;
      _viewXMax = null;
    } else {
      _viewYMin = null;
      _viewYMax = null;
    }
    _notifyChartChanged();
    _commitSession();
  }

  Future<void> _showAnalysisAxisSettings({required bool xAxis}) async {
    final bounds = _viewportBounds;
    final result = await showTalDialog<AxisSettings>(
      context: context,
      builder: (context) => PlotAxisSettingsDialog(
        xAxis: xAxis,
        automatic: xAxis ? _viewXMin == null : _viewYMin == null,
        minimum: xAxis ? bounds.$1 : bounds.$3,
        maximum: xAxis ? bounds.$2 : bounds.$4,
        mouseEnabled: xAxis ? _mouseXEnabled : _mouseYEnabled,
        inverted: xAxis ? _invertX : _invertY,
      ),
    );
    if (!mounted || result == null) return;
    if (xAxis) {
      _session.mouseXEnabled = result.mouseEnabled;
      _session.invertX = result.inverted;
      _viewXMin = result.automatic ? null : result.minimum;
      _viewXMax = result.automatic ? null : result.maximum;
    } else {
      _session.mouseYEnabled = result.mouseEnabled;
      _session.invertY = result.inverted;
      _viewYMin = result.automatic ? null : result.minimum;
      _viewYMax = result.automatic ? null : result.maximum;
    }
    _notifyChartChanged();
    _commitSession();
  }

  void _openPlotDesktopMenu(Offset position) {
    if (!_plotMenuController.isOpen && _plotMenuAnimationLease == null) {
      _plotMenuAnimationLease = beginTalMenuAnimation();
    }
    _plotMenuController.open(position: position);
  }

  void _handlePlotMenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _releasePlotMenuAnimation();
  }

  void _releasePlotMenuAnimation() {
    _plotMenuAnimationLease?.release();
    _plotMenuAnimationLease = null;
  }

  Future<void> _showPlotTouchMenu(Offset globalPosition) async {
    if (_plotMenuController.isOpen) _plotMenuController.close();
    final action = await showTalContextMenu<String>(
      context: context,
      position: _statsMenuPosition(globalPosition),
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
        _showAllAnalysisData();
      case 'select-all':
        _selectAllAnalysisRange();
      case 'clear-selection':
        _clearAnalysisSelection();
      case 'x':
        await _showAnalysisAxisSettings(xAxis: true);
      case 'y':
        await _showAnalysisAxisSettings(xAxis: false);
    }
  }

  void _handlePlotLongPress(LongPressStartDetails details) {
    if (_lastPlotPointerKind == PointerDeviceKind.mouse) return;
    unawaited(_showPlotTouchMenu(details.globalPosition));
  }

  Widget _buildStats(
    double? start,
    double? end, {
    required double height,
    required double minimumHeight,
    required double maximumHeight,
  }) {
    final selected = start != null && end != null;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              key: const ValueKey('analysis-stats-height-resize'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) => _resizeStatsHeight(
                details.delta.dy,
                minimumHeight,
                maximumHeight,
              ),
              onVerticalDragEnd: (_) => _commitSession(),
              child: Container(
                height: 8,
                color: TalColors.surface,
                alignment: Alignment.center,
                child: Container(width: 44, height: 2, color: TalColors.border),
              ),
            ),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: TalColors.surface,
                border: Border(top: BorderSide(color: TalColors.border)),
              ),
              child: selected
                  ? _ResizableTableViewport(
                      layout: _statsTableLayout,
                      contentWidth: _statsTableWidth,
                      horizontalController: _statsHorizontalScrollController,
                      contentKey: const ValueKey(
                        'analysis-stats-table-content',
                      ),
                      resizeRegionKey: const ValueKey(
                        'analysis-stats-table-resize-region',
                      ),
                      minimumRowHeight: 24,
                      onLayoutChanged: _onStatsLayoutChanged,
                      header: _buildStatsHeader(),
                      body: ListView(
                        children: [
                          for (final (index, series) in _series.indexed)
                            _buildStatsRow(series, index),
                        ],
                      ),
                    )
                  : const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('选择时间段后显示最小值、最大值、平均值和峰峰值', style: talMuted),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _resizeStatsHeight(
    double delta,
    double minimumHeight,
    double maximumHeight,
  ) {
    setState(() {
      _statsHeight = (_statsHeight - delta)
          .clamp(minimumHeight, maximumHeight)
          .toDouble();
    });
  }

  void _onStatsLayoutChanged() {
    setState(() {});
    _commitSession();
  }

  Widget _buildStatsHeader() {
    return Container(
      height: TalUiTheme.of(context).targetExtent(36),
      decoration: const BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: Row(
        children: [
          for (final (index, label) in _analysisStatsColumnLabels.indexed)
            if (!_hiddenColumns.contains(index))
              _AnalysisStatsHeaderCell(
                key: ValueKey('analysis-stats-header-$index'),
                label: label,
                width: _statsTableLayout.widths[index],
                columnIndex: index,
                onResize: _resizeStatsColumn,
                selected: _selectedColumns.contains(index),
                onSelect: _selectStatsColumn,
                hideLabel: _statsHeaderTargets(index).length == 1
                    ? '隐藏该列'
                    : '隐藏所选列（${_statsHeaderTargets(index).length}）',
                canHide: _canHideStatsColumns(_statsHeaderTargets(index)),
                onHide: () => _hideStatsColumns(_statsHeaderTargets(index)),
                onShowAll: _showAllStatsColumns,
                onTouchContextMenu: (request) =>
                    _showStatsHeaderContextMenu(index, request),
              ),
        ],
      ),
    );
  }

  void _resizeStatsColumn(int index, double delta) {
    if (_statsTableLayout.resizeColumn(index, delta)) {
      setState(() {});
      _commitSession();
    }
  }

  double get _statsTableWidth => _statsTableLayout.widths.indexed
      .where((entry) => !_hiddenColumns.contains(entry.$1))
      .fold(0, (sum, entry) => sum + entry.$2);

  void _selectStatsColumn(int index) {
    final additive = HardwareKeyboard.instance.isShiftPressed;
    if (additive) {
      if (!_selectedColumns.add(index)) _selectedColumns.remove(index);
    } else {
      _selectedColumns
        ..clear()
        ..add(index);
    }
    _session.selectedSeriesIndex = null;
    _session.selectedCellColumn = null;
    _statsChanges.value += 1;
    _commitSession();
  }

  RelativeRect _statsMenuPosition(Offset globalPosition) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);
    return RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
  }

  Future<void> _showStatsHeaderContextMenu(
    int clickedColumn,
    _ContextMenuRequest request,
  ) async {
    final targetColumns = _statsHeaderTargets(clickedColumn);
    final canHide = _canHideStatsColumns(targetColumns);
    final action = await showTalContextMenu<String>(
      context: context,
      position: _statsMenuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _analysisPopupItem(
          value: 'hide',
          label: targetColumns.length == 1
              ? '隐藏该列'
              : '隐藏所选列（${targetColumns.length}）',
          enabled: canHide,
          touchOptimized: request.touchOptimized,
        ),
        _analysisPopupItem(
          value: 'showAll',
          label: '显示全列',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'showAll') {
      _showAllStatsColumns();
    } else {
      _hideStatsColumns(targetColumns);
    }
  }

  List<int> _statsHeaderTargets(int clickedColumn) =>
      _selectedColumns.length > 1
      ? (_selectedColumns.toList()..sort())
      : <int>[clickedColumn];

  bool _canHideStatsColumns(List<int> columns) =>
      _analysisStatsColumnLabels.length - _hiddenColumns.length > 1 &&
      columns.any((column) => !_hiddenColumns.contains(column));

  void _hideStatsColumns(List<int> columns) {
    for (final column in columns) {
      if (_analysisStatsColumnLabels.length - _hiddenColumns.length <= 1) {
        break;
      }
      _hiddenColumns.add(column);
    }
    _statsChanges.value += 1;
    _commitSession();
  }

  void _showAllStatsColumns() {
    _hiddenColumns.clear();
    _statsChanges.value += 1;
    _commitSession();
  }

  Widget _buildStatsRow(AnalysisSeries series, int seriesIndex) {
    final stats = seriesIndex < _session.selectionStats.length
        ? _session.selectionStats[seriesIndex]
        : null;
    final count = stats?.count.toString() ?? '—';
    final minimum = stats == null ? '—' : _formatNumber(stats.minimum);
    final maximum = stats == null ? '—' : _formatNumber(stats.maximum);
    final average = stats == null ? '—' : _formatNumber(stats.average);
    final range = stats == null
        ? '—'
        : _formatNumber(stats.maximum - stats.minimum);
    final isVisible =
        seriesIndex >= _seriesVisibility.length ||
        _seriesVisibility[seriesIndex];
    final textByColumn = <String>[
      series.name,
      count,
      minimum,
      maximum,
      average,
      range,
      isVisible ? '是' : '否',
    ];
    final widgetsByColumn = <Widget>[
      Row(
        children: [
          Container(width: 10, height: 3, color: series.color),
          const SizedBox(width: 7),
          Expanded(child: Text(series.name, overflow: TextOverflow.ellipsis)),
        ],
      ),
      Text(count, style: talMono),
      Text(minimum, style: talMono),
      Text(maximum, style: talMono),
      Text(average, style: talMono),
      Text(range, style: talMono),
      Center(
        child: Checkbox(
          key: ValueKey('analysis-series-visible-$seriesIndex'),
          value: isVisible,
          onChanged: (value) {
            _selectStatsCell(
              seriesIndex,
              _analysisStatsColumnLabels.length - 1,
            );
            _setSeriesVisibility(seriesIndex, value: value ?? false);
          },
          visualDensity: VisualDensity.compact,
        ),
      ),
    ];
    return Container(
      key: ValueKey('analysis-stats-row-${series.name}'),
      height: _statsTableLayout.rowHeight,
      decoration: const BoxDecoration(
        color: TalColors.input,
        border: Border(bottom: BorderSide(color: TalColors.borderSoft)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < widgetsByColumn.length; index += 1)
            if (!_hiddenColumns.contains(index))
              _AnalysisStatsCell(
                key: ValueKey('analysis-stats-cell-$seriesIndex-$index'),
                width: _statsTableLayout.widths[index],
                selected:
                    _session.selectedSeriesIndex == seriesIndex &&
                    _session.selectedCellColumn == index,
                onTap: () {
                  _selectStatsCell(seriesIndex, index);
                  if (index == _analysisStatsColumnLabels.length - 1) {
                    _setSeriesVisibility(seriesIndex, value: !isVisible);
                  }
                },
                onMenuOpen: () => _selectStatsCell(seriesIndex, index),
                onCopy: () =>
                    Clipboard.setData(ClipboardData(text: textByColumn[index])),
                onOnly: () => _setOnlySeriesVisible(seriesIndex),
                onAll: _setAllSeriesVisible,
                onTouchContextMenu: (request) => _showStatsCellContextMenu(
                  seriesIndex,
                  index,
                  textByColumn[index],
                  request,
                ),
                child: widgetsByColumn[index],
              ),
        ],
      ),
    );
  }

  void _selectStatsCell(int seriesIndex, int columnIndex) {
    _selectedColumns.clear();
    _session.selectedSeriesIndex = seriesIndex;
    _session.selectedCellColumn = columnIndex;
    _statsChanges.value += 1;
    _commitSession();
  }

  Future<void> _showStatsCellContextMenu(
    int seriesIndex,
    int columnIndex,
    String value,
    _ContextMenuRequest request,
  ) async {
    _selectStatsCell(seriesIndex, columnIndex);
    final action = await showTalContextMenu<String>(
      context: context,
      position: _statsMenuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _analysisPopupItem(
          value: 'copy',
          label: '复制',
          touchOptimized: request.touchOptimized,
        ),
        const PopupMenuDivider(),
        _analysisPopupItem(
          value: 'only',
          label: '仅绘制该栏',
          touchOptimized: request.touchOptimized,
        ),
        _analysisPopupItem(
          value: 'all',
          label: '全部绘制',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: value));
      case 'only':
        _setOnlySeriesVisible(seriesIndex);
      case 'all':
        _setAllSeriesVisible();
    }
  }

  void _setSeriesVisibility(int index, {required bool value}) {
    if (index < 0 || index >= _series.length) return;
    final visibility = List<bool>.generate(
      _series.length,
      (seriesIndex) => seriesIndex < _seriesVisibility.length
          ? _seriesVisibility[seriesIndex]
          : true,
    );
    if (visibility[index] == value) return;
    visibility[index] = value;
    _seriesVisibility = visibility;
    _chartChanges.value += 1;
    _statsChanges.value += 1;
    _commitSession();
  }

  void _setOnlySeriesVisible(int index) {
    if (index < 0 || index >= _series.length) return;
    _seriesVisibility = List<bool>.generate(
      _series.length,
      (seriesIndex) => seriesIndex == index,
    );
    _chartChanges.value += 1;
    _statsChanges.value += 1;
    _commitSession();
  }

  void _setAllSeriesVisible() {
    _seriesVisibility = List<bool>.filled(_series.length, true);
    _chartChanges.value += 1;
    _statsChanges.value += 1;
    _commitSession();
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    _lastPlotPointerKind = event.kind;
    if (_plotMenuController.isOpen &&
        event.buttons & kSecondaryMouseButton == 0) {
      _plotMenuController.close();
      return;
    }
    if (event.kind != PointerDeviceKind.mouse ||
        !_analysisPlotRect(size).contains(event.localPosition)) {
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) {
      final plot = _analysisPlotRect(size);
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
    final plot = _analysisPlotRect(size);
    if (plot.width <= 1 || plot.height <= 1) return;
    final bounds = _viewportBounds;
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
    final bounds = _viewportBounds;
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

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    final plot = _analysisPlotRect(size);
    if (!plot.contains(event.localPosition)) return;
    final bounds = _viewportBounds;
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
    _commitSession();
  }

  void _finishPointerInteraction(Size size, PointerUpEvent? event) {
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
    _commitSession();
    if (openMenu) _openPlotDesktopMenu(event.localPosition);
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
    _selectionDragTarget = _AnalysisSelectionDragTarget.newRange;
    _dragStartX = _xForPosition(position, size);
    _selectionStart = _dragStartX;
    _selectionEnd = _dragStartX;
    _notifyChartChanged();
  }

  void _updateSelection(double position, Size size) {
    if (size.width <= 0) return;
    final value = _xForPosition(position, size);
    switch (_selectionDragTarget) {
      case _AnalysisSelectionDragTarget.newRange:
        if (_dragStartX == null) return;
        _selectionEnd = value;
      case _AnalysisSelectionDragTarget.lowerBound:
        final upper = _selectionEnd;
        if (upper == null) return;
        _selectionStart = math.min(value, upper);
      case _AnalysisSelectionDragTarget.upperBound:
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
      _updateSelectionStats();
    }
    _notifyChartChanged();
    _statsChanges.value += 1;
  }

  _AnalysisSelectionDragTarget? _selectionTargetAt(
    double position,
    Size size,
    (double, double)? range,
  ) {
    if (range == null) return null;
    final viewport = _interactionViewport(_analysisPlotRect(size));
    final lowerDistance = (position - viewport.mapX(range.$1)).abs();
    final upperDistance = (position - viewport.mapX(range.$2)).abs();
    if (math.min(lowerDistance, upperDistance) >
        _analysisSelectionHandleHitSlop) {
      return null;
    }
    return lowerDistance <= upperDistance
        ? _AnalysisSelectionDragTarget.lowerBound
        : _AnalysisSelectionDragTarget.upperBound;
  }

  void _notifyChartChanged() => _chartChanges.value += 1;

  double _xForPosition(double position, Size size) {
    return _interactionViewport(_analysisPlotRect(size)).unmapX(position);
  }

  double _yForPosition(double position, Size size) {
    return _interactionViewport(_analysisPlotRect(size)).unmapY(position);
  }

  double _xFractionForPosition(double position, Rect plot) {
    return _interactionViewport(plot).xFractionAt(position);
  }

  double _yFractionForPosition(double position, Rect plot) {
    return _interactionViewport(plot).yFractionAt(position);
  }

  CartesianPlotViewport _interactionViewport(Rect plot) {
    final bounds = _viewportBounds;
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
    final plot = _analysisPlotRect(size);
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

  (double, double, double, double) get _viewportBounds {
    final data = _dataBounds;
    return (
      _viewXMin ?? data.$1,
      _viewXMax ?? data.$2,
      _viewYMin ?? data.$3,
      _viewYMax ?? data.$4,
    );
  }

  (double, double, double, double) get _dataBounds => _session.dataBounds;

  void _resetViewport() {
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

  Future<void> _handleImport(_AnalysisImportSource source) async {
    if (source == _AnalysisImportSource.realtime) {
      final series = [
        for (final watch in controller.watches)
          if (watch.samples.isNotEmpty)
            AnalysisSeries(
              name: watch.symbol.name,
              color: watch.color,
              points: [
                for (final point in watch.samples)
                  AnalysisPoint(point.dx, point.dy),
              ],
            ),
      ];
      if (series.isEmpty) {
        controller.report('当前没有可分析的实时采样数据。');
        return;
      }
      _setImported(series, '当前实时数据');
      return;
    }
    final picker = controller.csvImportContentsPicker;
    if (picker == null) {
      controller.report('当前窗口暂不支持本地 CSV 导入。');
      return;
    }
    final contents = await picker();
    if (!mounted || contents == null || contents.trim().isEmpty) return;
    final series = contents.length < 256 * 1024
        ? parseAnalysisCsv(contents, colors: seriesColors)
        : await parseAnalysisCsvInBackground(contents, colors: seriesColors);
    if (!mounted) return;
    if (series.isEmpty) {
      controller.report('CSV 中没有找到可分析的数值列。');
      return;
    }
    _setImported(series, '本地 CSV');
  }

  void _setImported(List<AnalysisSeries> series, String source) {
    setState(() => _session.replaceData(series, source));
    _commitSession(includeData: true);
  }

  void _updateSelectionStats() {
    _session.updateSelectionStats();
  }

  static String _formatNumber(double value) =>
      value.abs() >= 1000 ? value.toStringAsFixed(1) : value.toStringAsFixed(4);
}
