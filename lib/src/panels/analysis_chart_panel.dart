part of '../panels.dart';

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

Rect _analysisPlotRect(Size size) => Rect.fromLTRB(
  54,
  12,
  math.max(55, size.width - 14),
  math.max(13, size.height - 32),
);

class _AnalysisPoint {
  const _AnalysisPoint(this.x, this.y);

  final double x;
  final double y;
}

class _AnalysisSeries {
  const _AnalysisSeries({
    required this.name,
    required this.color,
    required this.points,
  });

  final String name;
  final Color color;
  final List<_AnalysisPoint> points;
}

class _AnalysisStats {
  const _AnalysisStats({
    required this.count,
    required this.minimum,
    required this.maximum,
    required this.average,
  });

  final int count;
  final double minimum;
  final double maximum;
  final double average;
}

final Expando<_AnalysisChartSession> _analysisChartSessions =
    Expando<_AnalysisChartSession>('analysis-chart-session');

/// State that belongs to an analysis session rather than one mounted panel.
/// Workspace tab switches rebuild panel widgets, so keeping this data here
/// lets the analysis resume exactly where the user left it.
class _AnalysisChartSession {
  final ResizableTableLayout statsTableLayout = ResizableTableLayout(
    widths: const [180, 90, 110, 110, 110, 110, 92],
    minimumWidths: const [100, 70, 80, 80, 80, 80, 72],
    rowHeight: 32,
  );

  double statsHeight = 164;
  double statsHorizontalOffset = 0;
  List<_AnalysisSeries> series = const [];
  List<bool> seriesVisibility = const [];
  final Set<int> selectedColumns = <int>{};
  final Set<int> hiddenColumns = <int>{};
  int? selectedSeriesIndex;
  int? selectedCellColumn;
  String sourceLabel = '';
  double? selectionStart;
  double? selectionEnd;
  double? viewXMin;
  double? viewXMax;
  double? viewYMin;
  double? viewYMax;
  (double, double, double, double)? dataBounds;
  List<_AnalysisStats?> selectionStats = const [];
}

class _AnalysisChartPanel extends StatefulWidget {
  const _AnalysisChartPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_AnalysisChartPanel> createState() => _AnalysisChartPanelState();
}

class _AnalysisChartPanelState extends State<_AnalysisChartPanel> {
  late final _AnalysisChartSession _session;
  late final ScrollController _statsHorizontalScrollController;
  final ValueNotifier<int> _chartChanges = ValueNotifier<int>(0);
  final ValueNotifier<int> _statsChanges = ValueNotifier<int>(0);
  double? _dragStartX;
  Offset? _lastPanPosition;
  Offset? _lastRightZoomPosition;
  Offset? _rightZoomAnchorFraction;
  bool _selectionDragging = false;
  bool _middleDragging = false;
  bool _rightZoomDragging = false;

  TakeALookController get controller => widget.controller;
  ResizableTableLayout get _statsTableLayout => _session.statsTableLayout;
  double get _statsHeight => _session.statsHeight;
  set _statsHeight(double value) => _session.statsHeight = value;
  List<_AnalysisSeries> get _series => _session.series;
  set _series(List<_AnalysisSeries> value) => _session.series = value;
  List<bool> get _seriesVisibility => _session.seriesVisibility;
  set _seriesVisibility(List<bool> value) => _session.seriesVisibility = value;
  Set<int> get _selectedColumns => _session.selectedColumns;
  Set<int> get _hiddenColumns => _session.hiddenColumns;
  String get _sourceLabel => _session.sourceLabel;
  set _sourceLabel(String value) => _session.sourceLabel = value;
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

  @override
  void initState() {
    super.initState();
    _session = _analysisChartSessions[controller] ??= _AnalysisChartSession();
    _statsHorizontalScrollController = ScrollController(
      initialScrollOffset: _session.statsHorizontalOffset,
    )..addListener(_rememberStatsHorizontalOffset);
  }

  void _rememberStatsHorizontalOffset() {
    if (_statsHorizontalScrollController.hasClients) {
      _session.statsHorizontalOffset = _statsHorizontalScrollController.offset;
    }
  }

  @override
  void dispose() {
    _rememberStatsHorizontalOffset();
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
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: TalColors.surface,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.analytics_outlined, size: 17, color: TalColors.accent),
          const SizedBox(width: 8),
          Text('分析图表', style: talStrong),
          if (_sourceLabel.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text('· $_sourceLabel · ${_series.length} 条曲线', style: talMuted),
          ],
          const Spacer(),
          _importButton(),
          if (_series.isNotEmpty) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => setState(() {
                _series = const [];
                _seriesVisibility = const [];
                _selectedColumns.clear();
                _session.selectedSeriesIndex = null;
                _session.selectedCellColumn = null;
                _sourceLabel = '';
                _selectionStart = null;
                _selectionEnd = null;
                _session.dataBounds = null;
                _session.selectionStats = const [];
                _resetViewport();
              }),
              child: const Text('清除'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _importButton() {
    return PopupMenuButton<_AnalysisImportSource>(
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: TalColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.file_open_outlined, size: 16),
            const SizedBox(width: 7),
            Text(_series.isEmpty ? '导入数据' : '重新导入'),
          ],
        ),
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
            ValueListenableBuilder<int>(
              valueListenable: _chartChanges,
              builder: (context, _, _) => _buildInteractionHint(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = constraints.biggest;
                    return ValueListenableBuilder<int>(
                      valueListenable: _chartChanges,
                      builder: (context, _, _) {
                        final bounds = _viewportBounds;
                        final selection = _selectedRange;
                        return MouseRegion(
                          cursor: _rightZoomDragging
                              ? SystemMouseCursors.zoomIn
                              : _middleDragging
                              ? SystemMouseCursors.grabbing
                              : SystemMouseCursors.precise,
                          child: Listener(
                            key: const ValueKey('analysis-chart-interaction'),
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (event) =>
                                _handlePointerDown(event, size),
                            onPointerMove: (event) =>
                                _handlePointerMove(event, size),
                            onPointerUp: (_) => _finishPointerInteraction(),
                            onPointerCancel: (_) => _finishPointerInteraction(),
                            onPointerSignal: (event) =>
                                _handlePointerSignal(event, size),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                RepaintBoundary(
                                  child: CustomPaint(
                                    key: const ValueKey(
                                      'analysis-chart-series-layer',
                                    ),
                                    painter: _AnalysisChartPainter(
                                      series: _series,
                                      seriesVisibility: _seriesVisibility,
                                      xMin: bounds.$1,
                                      xMax: bounds.$2,
                                      yMin: bounds.$3,
                                      yMax: bounds.$4,
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
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
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

  (double, double)? get _selectedRange {
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) return null;
    return (math.min(start, end), math.max(start, end));
  }

  Widget _buildInteractionHint() {
    final selection = _selectedRange;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      color: TalColors.surfaceAlt,
      child: Text(
        selection == null
            ? '左键拖动选时间段 · 中键移动 · 右键拖动或滚轮缩放'
            : '已选择 ${_formatNumber(selection.$1)} s – ${_formatNumber(selection.$2)} s · 左键重新选择 · 中键移动 · 右键/滚轮缩放',
        style: selection == null ? talMuted : talBody,
      ),
    );
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
                      onLayoutChanged: () => setState(() {}),
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

  Widget _buildStatsHeader() {
    return Container(
      height: 36,
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
    if (_statsTableLayout.resizeColumn(index, delta)) setState(() {});
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
  }

  void _showAllStatsColumns() {
    _hiddenColumns.clear();
    _statsChanges.value += 1;
  }

  Widget _buildStatsRow(_AnalysisSeries series, int seriesIndex) {
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
  }

  void _setOnlySeriesVisible(int index) {
    if (index < 0 || index >= _series.length) return;
    _seriesVisibility = List<bool>.generate(
      _series.length,
      (seriesIndex) => seriesIndex == index,
    );
    _chartChanges.value += 1;
    _statsChanges.value += 1;
  }

  void _setAllSeriesVisible() {
    _seriesVisibility = List<bool>.filled(_series.length, true);
    _chartChanges.value += 1;
    _statsChanges.value += 1;
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    if (event.kind != PointerDeviceKind.mouse ||
        !_analysisPlotRect(size).contains(event.localPosition)) {
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) {
      final plot = _analysisPlotRect(size);
      _rightZoomDragging = true;
      _lastRightZoomPosition = event.localPosition;
      _rightZoomAnchorFraction = Offset(
        ((event.localPosition.dx - plot.left) / plot.width).clamp(0.0, 1.0),
        ((plot.bottom - event.localPosition.dy) / plot.height).clamp(0.0, 1.0),
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
      _selectionDragging = true;
      _startSelection(event.localPosition.dx, size);
    }
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) {
    if (_rightZoomDragging && event.buttons & kSecondaryMouseButton != 0) {
      _updateRightButtonZoom(event.localPosition);
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
    final xWindow = _clampWindow(
      bounds.$1 - delta.dx / plot.width * xSpan,
      bounds.$2 - delta.dx / plot.width * xSpan,
      data.$1,
      data.$2,
    );
    final yWindow = _clampWindow(
      bounds.$3 + delta.dy / plot.height * ySpan,
      bounds.$4 + delta.dy / plot.height * ySpan,
      data.$3,
      data.$4,
    );
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
    final xWindow = _zoomWindow(
      bounds.$1,
      bounds.$2,
      data.$1,
      data.$2,
      anchor.dx,
      xScale,
    );
    final yWindow = _zoomWindow(
      bounds.$3,
      bounds.$4,
      data.$3,
      data.$4,
      anchor.dy,
      yScale,
    );
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
    final xFraction = ((event.localPosition.dx - plot.left) / plot.width).clamp(
      0.0,
      1.0,
    );
    final yFraction = ((plot.bottom - event.localPosition.dy) / plot.height)
        .clamp(0.0, 1.0);
    final xWindow = _zoomWindow(
      bounds.$1,
      bounds.$2,
      data.$1,
      data.$2,
      xFraction,
      scale,
    );
    final yWindow = _zoomWindow(
      bounds.$3,
      bounds.$4,
      data.$3,
      data.$4,
      yFraction,
      scale,
    );
    _viewXMin = xWindow.$1;
    _viewXMax = xWindow.$2;
    _viewYMin = yWindow.$1;
    _viewYMax = yWindow.$2;
    _notifyChartChanged();
  }

  void _finishPointerInteraction() {
    final wasSelecting = _selectionDragging;
    _selectionDragging = false;
    _middleDragging = false;
    _rightZoomDragging = false;
    _lastPanPosition = null;
    _lastRightZoomPosition = null;
    _rightZoomAnchorFraction = null;
    if (wasSelecting) {
      _finishSelection();
    } else {
      _notifyChartChanged();
    }
  }

  void _startSelection(double position, Size size) {
    if (_series.isEmpty || size.width <= 0) return;
    _dragStartX = _xForPosition(position, size);
    _selectionStart = _dragStartX;
    _selectionEnd = _dragStartX;
    _notifyChartChanged();
  }

  void _updateSelection(double position, Size size) {
    final dragStart = _dragStartX;
    if (dragStart == null || size.width <= 0) return;
    _selectionEnd = _xForPosition(position, size);
    _notifyChartChanged();
  }

  void _finishSelection() {
    _dragStartX = null;
    if (_selectionStart == null || _selectionEnd == null) return;
    if ((_selectionStart! - _selectionEnd!).abs() < 1e-9) {
      _selectionStart = null;
      _selectionEnd = null;
      _session.selectionStats = const [];
    } else {
      _updateSelectionStats();
    }
    _notifyChartChanged();
    _statsChanges.value += 1;
  }

  void _notifyChartChanged() => _chartChanges.value += 1;

  double _xForPosition(double position, Size size) {
    final bounds = _viewportBounds;
    final xMin = bounds.$1;
    final xMax = bounds.$2;
    final plot = _analysisPlotRect(size);
    final fraction = ((position - plot.left) / math.max(1, plot.width)).clamp(
      0.0,
      1.0,
    );
    return xMin + (xMax - xMin) * fraction;
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

  (double, double, double, double) get _dataBounds {
    final cached = _session.dataBounds;
    if (cached != null) return cached;
    var xMin = double.infinity;
    var xMax = -double.infinity;
    var yMin = double.infinity;
    var yMax = -double.infinity;
    for (final series in _series) {
      for (final point in series.points) {
        xMin = math.min(xMin, point.x);
        xMax = math.max(xMax, point.x);
        yMin = math.min(yMin, point.y);
        yMax = math.max(yMax, point.y);
      }
    }
    if (xMax <= xMin) {
      xMin -= 0.5;
      xMax += 0.5;
    }
    if (yMax <= yMin) {
      final padding = math.max(1, yMax.abs() * 0.1);
      yMin -= padding;
      yMax += padding;
    } else {
      final padding = (yMax - yMin) * 0.08;
      yMin -= padding;
      yMax += padding;
    }
    return _session.dataBounds = (xMin, xMax, yMin, yMax);
  }

  (double, double) _zoomWindow(
    double minimum,
    double maximum,
    double dataMinimum,
    double dataMaximum,
    double anchorFraction,
    double scale,
  ) {
    final dataSpan = dataMaximum - dataMinimum;
    final span = ((maximum - minimum) * scale).clamp(
      math.max(dataSpan * 0.0001, 1e-9),
      dataSpan,
    );
    final anchor = minimum + (maximum - minimum) * anchorFraction;
    final nextMinimum = anchor - span * anchorFraction;
    return _clampWindow(
      nextMinimum,
      nextMinimum + span,
      dataMinimum,
      dataMaximum,
    );
  }

  (double, double) _clampWindow(
    double minimum,
    double maximum,
    double dataMinimum,
    double dataMaximum,
  ) {
    final span = maximum - minimum;
    if (span >= dataMaximum - dataMinimum) return (dataMinimum, dataMaximum);
    if (minimum < dataMinimum) return (dataMinimum, dataMinimum + span);
    if (maximum > dataMaximum) return (dataMaximum - span, dataMaximum);
    return (minimum, maximum);
  }

  void _resetViewport() {
    _viewXMin = null;
    _viewXMax = null;
    _viewYMin = null;
    _viewYMax = null;
    _dragStartX = null;
    _lastPanPosition = null;
    _lastRightZoomPosition = null;
    _rightZoomAnchorFraction = null;
    _selectionDragging = false;
    _middleDragging = false;
    _rightZoomDragging = false;
  }

  Future<void> _handleImport(_AnalysisImportSource source) async {
    if (source == _AnalysisImportSource.realtime) {
      final series = [
        for (final watch in controller.watches)
          if (watch.samples.isNotEmpty)
            _AnalysisSeries(
              name: watch.symbol.name,
              color: watch.color,
              points: [
                for (final point in watch.samples)
                  _AnalysisPoint(point.dx, point.dy),
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
    final series = _parseCsv(contents);
    if (series.isEmpty) {
      controller.report('CSV 中没有找到可分析的数值列。');
      return;
    }
    _setImported(series, '本地 CSV');
  }

  void _setImported(List<_AnalysisSeries> series, String source) {
    final sortedSeries = [
      for (final item in series)
        _AnalysisSeries(
          name: item.name,
          color: item.color,
          points: List<_AnalysisPoint>.of(item.points)
            ..sort((left, right) => left.x.compareTo(right.x)),
        ),
    ];
    setState(() {
      _series = sortedSeries;
      _seriesVisibility = List<bool>.filled(sortedSeries.length, true);
      _selectedColumns.clear();
      _session.selectedSeriesIndex = null;
      _session.selectedCellColumn = null;
      _sourceLabel = source;
      _selectionStart = null;
      _selectionEnd = null;
      _session.dataBounds = null;
      _session.selectionStats = const [];
      _resetViewport();
    });
  }

  static List<_AnalysisSeries> _parseCsv(String contents) {
    final rows = [
      for (final line
          in contents
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .split('\n'))
        if (line.trim().isNotEmpty) _parseCsvLine(line),
    ];
    if (rows.isEmpty || rows.first.length < 2) return const [];
    final first = rows.first;
    final hasHeader = double.tryParse(first.first.trim()) == null;
    final start = hasHeader ? 1 : 0;
    final columnCount = rows
        .skip(start)
        .fold<int>(first.length, (count, row) => math.max(count, row.length));
    if (columnCount < 2) return const [];
    final names = [
      for (var column = 1; column < columnCount; column += 1)
        hasHeader && first.length > column && first[column].trim().isNotEmpty
            ? first[column].trim()
            : '通道 $column',
    ];
    final points = [
      for (var i = 0; i < names.length; i += 1) <_AnalysisPoint>[],
    ];
    for (final row in rows.skip(start)) {
      final x = double.tryParse(row.isEmpty ? '' : row.first.trim());
      if (x == null || !x.isFinite) {
        continue;
      }
      for (var column = 1; column < columnCount; column += 1) {
        if (row.length <= column) continue;
        final y = double.tryParse(row[column].trim());
        if (y != null && y.isFinite) {
          points[column - 1].add(_AnalysisPoint(x, y));
        }
      }
    }
    return [
      for (var index = 0; index < points.length; index += 1)
        if (points[index].isNotEmpty)
          _AnalysisSeries(
            name: names[index],
            color: seriesColors[index % seriesColors.length],
            points: points[index],
          ),
    ];
  }

  static List<String> _parseCsvLine(String line) {
    final values = <String>[];
    var buffer = StringBuffer();
    var quoted = false;
    for (var index = 0; index < line.length; index += 1) {
      final char = line[index];
      if (char == '"') {
        if (quoted && index + 1 < line.length && line[index + 1] == '"') {
          buffer.write('"');
          index += 1;
        } else {
          quoted = !quoted;
        }
      } else if (char == ',' && !quoted) {
        values.add(buffer.toString());
        buffer = StringBuffer();
      } else {
        buffer.write(char);
      }
    }
    values.add(buffer.toString());
    return values;
  }

  void _updateSelectionStats() {
    final selection = _selectedRange;
    _session.selectionStats = selection == null
        ? const []
        : [
            for (final series in _series)
              _statsForRange(series.points, selection.$1, selection.$2),
          ];
  }

  static _AnalysisStats? _statsForRange(
    List<_AnalysisPoint> points,
    double start,
    double end,
  ) {
    final first = _lowerBound(points, start);
    final afterLast = _upperBound(points, end);
    if (first >= afterLast) return null;
    var minimum = double.infinity;
    var maximum = -double.infinity;
    var sum = 0.0;
    for (var index = first; index < afterLast; index += 1) {
      final value = points[index].y;
      minimum = math.min(minimum, value);
      maximum = math.max(maximum, value);
      sum += value;
    }
    final count = afterLast - first;
    return _AnalysisStats(
      count: count,
      minimum: minimum,
      maximum: maximum,
      average: sum / count,
    );
  }

  static int _lowerBound(List<_AnalysisPoint> points, double value) {
    var low = 0;
    var high = points.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (points[middle].x < value) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  static int _upperBound(List<_AnalysisPoint> points, double value) {
    var low = 0;
    var high = points.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (points[middle].x <= value) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  static String _formatNumber(double value) =>
      value.abs() >= 1000 ? value.toStringAsFixed(1) : value.toStringAsFixed(4);
}

class _AnalysisStatsHeaderCell extends StatefulWidget {
  const _AnalysisStatsHeaderCell({
    required this.label,
    required this.width,
    required this.columnIndex,
    required this.onResize,
    required this.selected,
    required this.onSelect,
    required this.hideLabel,
    required this.canHide,
    required this.onHide,
    required this.onShowAll,
    required this.onTouchContextMenu,
    super.key,
  });

  final String label;
  final double width;
  final int columnIndex;
  final _ColumnResizeCallback onResize;
  final bool selected;
  final ValueChanged<int> onSelect;
  final String hideLabel;
  final bool canHide;
  final VoidCallback onHide;
  final VoidCallback onShowAll;
  final ValueChanged<_ContextMenuRequest> onTouchContextMenu;

  @override
  State<_AnalysisStatsHeaderCell> createState() =>
      _AnalysisStatsHeaderCellState();
}

class _AnalysisStatsHeaderCellState extends State<_AnalysisStatsHeaderCell> {
  final MenuController _menuController = MenuController();
  TalMenuAnimationLease? _menuAnimationLease;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
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

  void _handleContextMenu(_ContextMenuRequest request) {
    if (request.touchOptimized) {
      if (_menuController.isOpen) _menuController.close();
      widget.onTouchContextMenu(request);
      return;
    }
    final box = context.findRenderObject()! as RenderBox;
    _openDesktopMenu(box.globalToLocal(request.globalPosition));
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: const ValueKey('analysis-header-menu-anchor'),
      controller: _menuController,
      style: talContextMenuStyle,
      consumeOutsideTap: true,
      animated: true,
      onAnimationStatusChanged: _handleMenuAnimationStatus,
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('analysis-header-menu-hide'),
          style: talContextMenuButtonStyle,
          onPressed: widget.canHide ? widget.onHide : null,
          child: Text(widget.hideLabel),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-header-menu-show-all'),
          style: talContextMenuButtonStyle,
          onPressed: widget.onShowAll,
          child: const Text('显示全列'),
        ),
      ],
      child: _ResizableTableHeaderCell(
        label: widget.label,
        width: widget.width,
        columnIndex: widget.columnIndex,
        keyPrefix: 'analysis-stats',
        onResize: widget.onResize,
        selected: widget.selected,
        onSelect: widget.onSelect,
        onContextMenu: (_, request) => _handleContextMenu(request),
      ),
    );
  }
}

class _AnalysisStatsCell extends StatefulWidget {
  const _AnalysisStatsCell({
    required this.width,
    required this.selected,
    required this.onTap,
    required this.onMenuOpen,
    required this.onCopy,
    required this.onOnly,
    required this.onAll,
    required this.onTouchContextMenu,
    required this.child,
    super.key,
  });

  final double width;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onMenuOpen;
  final VoidCallback onCopy;
  final VoidCallback onOnly;
  final VoidCallback onAll;
  final ValueChanged<_ContextMenuRequest> onTouchContextMenu;
  final Widget child;

  @override
  State<_AnalysisStatsCell> createState() => _AnalysisStatsCellState();
}

class _AnalysisStatsCellState extends State<_AnalysisStatsCell> {
  final MenuController _menuController = MenuController();
  TalMenuAnimationLease? _menuAnimationLease;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
  }

  void _openDesktopMenu(Offset position) {
    widget.onMenuOpen();
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

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      key: const ValueKey('analysis-cell-menu-anchor'),
      controller: _menuController,
      style: talContextMenuStyle,
      consumeOutsideTap: true,
      animated: true,
      onAnimationStatusChanged: _handleMenuAnimationStatus,
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-copy'),
          style: talContextMenuButtonStyle,
          onPressed: widget.onCopy,
          child: const Text('复制'),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-only'),
          style: talContextMenuButtonStyle,
          onPressed: widget.onOnly,
          child: const Text('仅绘制该栏'),
        ),
        MenuItemButton(
          key: const ValueKey('analysis-cell-menu-all'),
          style: talContextMenuButtonStyle,
          onPressed: widget.onAll,
          child: const Text('全部绘制'),
        ),
      ],
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: () {
          if (_menuController.isOpen) _menuController.close();
          final box = context.findRenderObject()! as RenderBox;
          widget.onTouchContextMenu(
            _ContextMenuRequest(
              globalPosition: box.localToGlobal(box.size.center(Offset.zero)),
              touchOptimized: true,
            ),
          );
        },
        onSecondaryTapUp: (details) => _openDesktopMenu(details.localPosition),
        child: Container(
          width: widget.width,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: widget.selected ? TalColors.selection : Colors.transparent,
            border: const Border(
              right: BorderSide(color: TalColors.borderSoft),
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

PopupMenuEntry<String> _analysisPopupItem({
  required String value,
  required String label,
  bool enabled = true,
  required bool touchOptimized,
}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: touchOptimized ? 48 : 32,
    child: Text(label),
  );
}

class _AnalysisChartPainter extends CustomPainter {
  const _AnalysisChartPainter({
    required this.series,
    required this.seriesVisibility,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });

  final List<_AnalysisSeries> series;
  final List<bool> seriesVisibility;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

  Iterable<_AnalysisSeries> get visibleSeries sync* {
    for (final (index, item) in series.indexed) {
      if (index >= seriesVisibility.length || seriesVisibility[index]) {
        yield item;
      }
    }
  }

  int get visibleSeriesCount => visibleSeries.length;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _analysisPlotRect(size);
    final viewport = CartesianPlotViewport(
      plot: plot,
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
    );
    final renderer = CartesianChartRenderer(
      canvas: canvas,
      size: size,
      viewport: viewport,
    );
    renderer.drawBackground();
    if (plot.width <= 2 || plot.height <= 2) return;
    renderer.drawGrid();
    canvas.save();
    canvas.clipRect(plot);
    for (final item in visibleSeries) {
      renderer.drawPolyline(
        _downsampleAnalysisPoints(
          item.points,
          xMin: xMin,
          xMax: xMax,
          pixelWidth: plot.width,
        ),
        item.color,
      );
    }
    canvas.restore();
    renderer.drawAxisLabels(
      yLabelOffset: 50,
      xTickOffset: 5,
      xAxisLabelOffset: 15,
    );
    renderer.drawLegend([
      for (final item in visibleSeries)
        CartesianLegendItem(label: item.name, color: item.color),
    ], wrap: true);
  }

  @override
  bool shouldRepaint(covariant _AnalysisChartPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.seriesVisibility != seriesVisibility ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.yMin != yMin ||
      oldDelegate.yMax != yMax;
}

class _AnalysisSelectionPainter extends CustomPainter {
  const _AnalysisSelectionPainter({
    required this.xMin,
    required this.xMax,
    required this.selectionStart,
    required this.selectionEnd,
  });

  final double xMin;
  final double xMax;
  final double? selectionStart;
  final double? selectionEnd;

  @override
  void paint(Canvas canvas, Size size) {
    final start = selectionStart;
    final end = selectionEnd;
    if (start == null || end == null) return;
    final plot = _analysisPlotRect(size);
    final span = math.max(1e-9, xMax - xMin);
    final left = plot.left + (math.min(start, end) - xMin) / span * plot.width;
    final right = plot.left + (math.max(start, end) - xMin) / span * plot.width;
    canvas.save();
    canvas.clipRect(plot);
    canvas.drawRect(
      Rect.fromLTRB(left, plot.top, right, plot.bottom),
      Paint()..color = TalColors.accent.withAlpha(38),
    );
    final border = Paint()
      ..color = TalColors.accent
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(left, plot.top), Offset(left, plot.bottom), border);
    canvas.drawLine(
      Offset(right, plot.top),
      Offset(right, plot.bottom),
      border,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AnalysisSelectionPainter oldDelegate) =>
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.selectionStart != selectionStart ||
      oldDelegate.selectionEnd != selectionEnd;
}

List<Offset> _downsampleAnalysisPoints(
  List<_AnalysisPoint> points, {
  required double xMin,
  required double xMax,
  required double pixelWidth,
}) {
  if (points.isEmpty || xMax <= xMin) return const [];
  final first = _AnalysisChartPanelState._lowerBound(points, xMin);
  final afterLast = _AnalysisChartPanelState._upperBound(points, xMax);
  if (first >= afterLast) return const [];
  final bucketCount = math.max(1, pixelWidth.floor());
  final visibleCount = afterLast - first;
  if (visibleCount <= bucketCount * 2) {
    return [
      for (var index = first; index < afterLast; index += 1)
        Offset(points[index].x, points[index].y),
    ];
  }

  final result = <Offset>[];
  var currentBucket = -1;
  _AnalysisPoint? minimum;
  _AnalysisPoint? maximum;
  var minimumIndex = 0;
  var maximumIndex = 0;

  void append(_AnalysisPoint point) {
    final offset = Offset(point.x, point.y);
    if (result.isEmpty || result.last != offset) result.add(offset);
  }

  void flushBucket() {
    final low = minimum;
    final high = maximum;
    if (low == null || high == null) return;
    if (minimumIndex <= maximumIndex) {
      append(low);
      append(high);
    } else {
      append(high);
      append(low);
    }
  }

  for (var index = first; index < afterLast; index += 1) {
    final point = points[index];
    final bucket = (((point.x - xMin) / (xMax - xMin)) * bucketCount)
        .floor()
        .clamp(0, bucketCount - 1);
    if (bucket != currentBucket) {
      flushBucket();
      currentBucket = bucket;
      minimum = point;
      maximum = point;
      minimumIndex = index;
      maximumIndex = index;
    } else {
      if (point.y < minimum!.y) {
        minimum = point;
        minimumIndex = index;
      }
      if (point.y > maximum!.y) {
        maximum = point;
        maximumIndex = index;
      }
    }
  }
  flushBucket();
  append(points[afterLast - 1]);
  return result;
}
