part of 'panels.dart';

enum _AnalysisImportSource { csv, realtime }

const _analysisStatsColumnLabels = <String>[
  '曲线',
  '样本数',
  '最小值',
  '最大值',
  '平均值',
  '峰峰值',
  '是否绘制',
];

Rect _analysisPlotRect(Size size) => AnalysisPlotInteraction.plotRect(size);

class _AnalysisChartPanel extends StatefulWidget {
  const _AnalysisChartPanel({
    required this.controller,
    this.horizontal = false,
  });

  final TakeALookController controller;
  final bool horizontal;

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
  late final AnalysisPlotInteraction _plotInteraction = AnalysisPlotInteraction(
    session: () => _session,
    onChanged: _notifyChartChanged,
    onSelectionChanged: () => _statsChanges.value += 1,
    onCommit: _commitSession,
  );
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
  set _selectionStart(double? value) => _session.selectionStart = value;
  set _selectionEnd(double? value) => _session.selectionEnd = value;
  double? get _viewXMin => _session.viewXMin;
  set _viewXMin(double? value) => _session.viewXMin = value;
  set _viewXMax(double? value) => _session.viewXMax = value;
  double? get _viewYMin => _session.viewYMin;
  set _viewYMin(double? value) => _session.viewYMin = value;
  set _viewYMax(double? value) => _session.viewYMax = value;
  AnalysisMouseMode get _mouseMode => _session.mouseMode;
  set _mouseMode(AnalysisMouseMode value) => _session.mouseMode = value;
  bool get _mouseXEnabled => _session.mouseXEnabled;
  bool get _mouseYEnabled => _session.mouseYEnabled;
  bool get _invertX => _session.invertX;
  bool get _invertY => _session.invertY;
  bool get _resizingSelectionBoundary =>
      _plotInteraction.resizingSelectionBoundary;

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
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(420, constraints.maxWidth),
            child: Row(
              children: [
                if (!widget.horizontal) Text('分析图表', style: talStrong),
                if (_sourceLabel.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$_sourceLabel · ${_series.length} 条曲线',
                      style: talMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (_sourceLabel.isEmpty) const Spacer(),
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
          ),
        ),
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
      child: SingleChildScrollView(
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
      ),
    );
  }

  Widget _buildAnalysisBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.horizontal && constraints.maxWidth >= 760) {
          return Row(
            key: const ValueKey('analysis-horizontal-workbench'),
            children: [
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      color: WorkbenchColors.surface,
                      child: const Row(
                        children: [
                          Text('时域', style: workbenchBody),
                          Spacer(),
                          Text('拖动选择区间', style: workbenchMuted),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                        child: _buildTimeDomainChart(),
                      ),
                    ),
                    if (_session.fftVisible) ...[
                      const Divider(height: 1, color: WorkbenchColors.border),
                      SizedBox(
                        height: TalUiTheme.of(context).targetExtent(34),
                        child: _buildFftToolbar(),
                      ),
                      Expanded(flex: 2, child: _buildFftPanel()),
                    ],
                  ],
                ),
              ),
              Container(width: 1, color: WorkbenchColors.border),
              SizedBox(
                width: (constraints.maxWidth * .28).clamp(280.0, 350.0),
                child: _buildStatisticsSidebar(),
              ),
            ],
          );
        }
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

  Widget _buildStatisticsSidebar() => ValueListenableBuilder<int>(
    valueListenable: _statsChanges,
    builder: (context, _, _) {
      final index = (_session.selectedSeriesIndex ?? 0).clamp(
        0,
        _series.length - 1,
      );
      final stats = index < _session.selectionStats.length
          ? _session.selectionStats[index]
          : null;
      final range = _selectedRange;
      Widget metric(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Text(label, style: workbenchMuted),
            const Spacer(),
            Text(value, style: talMono),
          ],
        ),
      );
      return ColoredBox(
        color: WorkbenchColors.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
              child: Row(
                children: [
                  const Text('区间统计', style: workbenchBody),
                  const Spacer(),
                  TalButton(
                    onPressed: _showFullStatistics,
                    child: const Text('完整统计表'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  for (final (seriesIndex, series) in _series.indexed)
                    InkWell(
                      onTap: () => _selectStatsCell(seriesIndex, 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 3,
                          horizontal: 4,
                        ),
                        color: index == seriesIndex
                            ? WorkbenchColors.raised
                            : Colors.transparent,
                        child: Row(
                          children: [
                            Container(
                              width: 3,
                              height: 20,
                              color: series.color,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                series.name,
                                style: workbenchBody,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            TalIconButton(
                              tooltip: _seriesVisibility[seriesIndex]
                                  ? '隐藏曲线'
                                  : '显示曲线',
                              onPressed: () => _setSeriesVisibility(
                                seriesIndex,
                                value: !_seriesVisibility[seriesIndex],
                              ),
                              icon: Icon(
                                _seriesVisibility[seriesIndex]
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 17,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Divider(color: WorkbenchColors.border),
                  Row(
                    children: [
                      const Text('选择区间', style: workbenchBody),
                      const Spacer(),
                      TextButton(
                        onPressed: _selectAllAnalysisRange,
                        child: const Text('全段'),
                      ),
                      TextButton(
                        onPressed: range == null
                            ? null
                            : _clearAnalysisSelection,
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                  Text(
                    range == null
                        ? '在时域图中拖动选择，或选择全段。'
                        : '${_formatNumber(range.$1)} s  —  ${_formatNumber(range.$2)} s',
                    style: workbenchMuted,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _series[index].name,
                    style: workbenchBody,
                    overflow: TextOverflow.ellipsis,
                  ),
                  metric('样本数', stats?.count.toString() ?? '—'),
                  metric(
                    '最小值',
                    stats == null ? '—' : _formatNumber(stats.minimum),
                  ),
                  metric(
                    '最大值',
                    stats == null ? '—' : _formatNumber(stats.maximum),
                  ),
                  metric(
                    '平均值',
                    stats == null ? '—' : _formatNumber(stats.average),
                  ),
                  metric(
                    '峰峰值',
                    stats == null
                        ? '—'
                        : _formatNumber(stats.maximum - stats.minimum),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _showFullStatistics() => showTalDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 1050,
        height: math.min(540, MediaQuery.sizeOf(context).height - 100),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Text('完整统计表', style: talStrong),
                  const Spacer(),
                  TalIconButton(
                    tooltip: '关闭统计表',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => ValueListenableBuilder<int>(
                  valueListenable: _statsChanges,
                  builder: (context, _, _) => _buildStats(
                    _selectedRange?.$1,
                    _selectedRange?.$2,
                    height: constraints.maxHeight,
                    minimumHeight: constraints.maxHeight,
                    maximumHeight: constraints.maxHeight,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

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
                      : _plotInteraction.rightZoomDragging
                      ? SystemMouseCursors.zoomIn
                      : _plotInteraction.middleDragging
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
                        if (_plotInteraction.rectangleZoom case final rect?)
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
    _plotInteraction.cancelRectangleZoom();
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
    _plotInteraction.handlePointerDown(event, size);
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) =>
      _plotInteraction.handlePointerMove(event, size);
  void _handlePointerSignal(PointerSignalEvent event, Size size) =>
      _plotInteraction.handlePointerSignal(event, size);
  void _finishPointerInteraction(Size size, PointerUpEvent? event) {
    if (_plotInteraction.finishPointerInteraction(size, event)) {
      _openPlotDesktopMenu(event!.localPosition);
    }
  }

  void _notifyChartChanged() => _chartChanges.value += 1;
  (double, double, double, double) get _viewportBounds =>
      _plotInteraction.viewportBounds;
  (double, double, double, double) get _dataBounds => _session.dataBounds;
  void _resetViewport() => _plotInteraction.resetViewport();

  Future<void> _handleImport(_AnalysisImportSource source) async {
    if (source == _AnalysisImportSource.realtime) {
      final series = [
        for (final watch in controller.watches)
          if (watch.samples.isNotEmpty)
            AnalysisSeries.fromSamples(
              name: watch.symbol.name,
              color: watch.color,
              samples: watch.samples,
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
    final pathPicker = controller.csvImportPathPicker;
    if (picker == null && pathPicker == null) {
      controller.report('当前窗口暂不支持本地 CSV 导入。');
      return;
    }
    final List<AnalysisSeries> series;
    if (pathPicker != null) {
      final path = await pathPicker();
      if (!mounted || path == null) return;
      series = await parseAnalysisCsvFileInBackground(
        path,
        colors: seriesColors,
      );
    } else {
      final contents = await picker!();
      if (!mounted || contents == null || contents.trim().isEmpty) return;
      series = contents.length < 256 * 1024
          ? parseAnalysisCsv(contents, colors: seriesColors)
          : await parseAnalysisCsvInBackground(contents, colors: seriesColors);
    }
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
