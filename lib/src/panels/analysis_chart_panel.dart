part of '../panels.dart';

enum _AnalysisImportSource { csv, realtime }

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

class _AnalysisChartPanel extends StatefulWidget {
  const _AnalysisChartPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_AnalysisChartPanel> createState() => _AnalysisChartPanelState();
}

class _AnalysisChartPanelState extends State<_AnalysisChartPanel> {
  List<_AnalysisSeries> _series = const [];
  String _sourceLabel = '';
  double? _selectionStart;
  double? _selectionEnd;
  double? _dragStartX;
  bool _middleDragging = false;

  TakeALookController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.telemetryChanges,
        controller.watchChanges,
      ]),
      builder: (context, _) {
        return Column(
          children: [
            _buildToolbar(),
            Expanded(
              child: _series.isEmpty
                  ? _buildEmptyState()
                  : _buildAnalysisBody(),
            ),
          ],
        );
      },
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
                _sourceLabel = '';
                _selectionStart = null;
                _selectionEnd = null;
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
    final bounds = _bounds;
    final hasSelection = _selectionStart != null && _selectionEnd != null;
    final start = hasSelection
        ? math.min(_selectionStart!, _selectionEnd!)
        : null;
    final end = hasSelection
        ? math.max(_selectionStart!, _selectionEnd!)
        : null;
    return Column(
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          color: TalColors.surfaceAlt,
          child: Text(
            hasSelection
                ? '已选择 ${_formatNumber(start!)} s – ${_formatNumber(end!)} s · 拖动可重新选择'
                : '在图表中按住鼠标中键拖动，选择要统计的时间段',
            style: hasSelection ? talBody : talMuted,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (event.kind == PointerDeviceKind.mouse &&
                        event.buttons & kMiddleMouseButton != 0) {
                      _middleDragging = true;
                      _startSelection(
                        event.localPosition.dx,
                        constraints.biggest.width,
                      );
                    }
                  },
                  onPointerMove: (event) {
                    if (_middleDragging &&
                        event.buttons & kMiddleMouseButton != 0) {
                      _updateSelection(
                        event.localPosition.dx,
                        constraints.biggest.width,
                      );
                    }
                  },
                  onPointerUp: (_) {
                    if (_middleDragging) {
                      _middleDragging = false;
                      _finishSelection();
                    }
                  },
                  onPointerCancel: (_) {
                    if (_middleDragging) {
                      _middleDragging = false;
                      _finishSelection();
                    }
                  },
                  child: CustomPaint(
                    painter: _AnalysisChartPainter(
                      series: _series,
                      xMin: bounds.$1,
                      xMax: bounds.$2,
                      yMin: bounds.$3,
                      yMax: bounds.$4,
                      selectionStart: start,
                      selectionEnd: end,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
        _buildStats(start, end),
      ],
    );
  }

  Widget _buildStats(double? start, double? end) {
    final selected = start != null && end != null;
    return Container(
      height: 164,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: TalColors.surface,
        border: Border(top: BorderSide(color: TalColors.border)),
      ),
      child: selected
          ? ListView(
              children: [
                Row(
                  children: const [
                    SizedBox(width: 150, child: Text('曲线', style: talMuted)),
                    SizedBox(width: 70, child: Text('样本数', style: talMuted)),
                    SizedBox(width: 100, child: Text('最小值', style: talMuted)),
                    SizedBox(width: 100, child: Text('最大值', style: talMuted)),
                    SizedBox(width: 100, child: Text('平均值', style: talMuted)),
                    SizedBox(width: 100, child: Text('峰峰值', style: talMuted)),
                  ],
                ),
                const Divider(height: 8),
                for (final series in _series)
                  _buildStatsRow(series, start, end),
              ],
            )
          : const Align(
              alignment: Alignment.centerLeft,
              child: Text('选择时间段后显示最小值、最大值、平均值和峰峰值', style: talMuted),
            ),
    );
  }

  Widget _buildStatsRow(_AnalysisSeries series, double start, double end) {
    final points = series.points.where(
      (point) => point.x >= start && point.x <= end,
    );
    final values = [for (final point in points) point.y];
    final stats = _statsFor(values);
    final count = stats?.count.toString() ?? '—';
    final min = stats == null ? '—' : _formatNumber(stats.minimum);
    final max = stats == null ? '—' : _formatNumber(stats.maximum);
    final average = stats == null ? '—' : _formatNumber(stats.average);
    final range = stats == null
        ? '—'
        : _formatNumber(stats.maximum - stats.minimum);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Row(
              children: [
                Container(width: 10, height: 3, color: series.color),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(series.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          SizedBox(width: 70, child: Text(count, style: talMono)),
          SizedBox(width: 100, child: Text(min, style: talMono)),
          SizedBox(width: 100, child: Text(max, style: talMono)),
          SizedBox(width: 100, child: Text(average, style: talMono)),
          SizedBox(width: 100, child: Text(range, style: talMono)),
        ],
      ),
    );
  }

  void _startSelection(double position, double width) {
    if (_series.isEmpty || width <= 0) return;
    _dragStartX = _xForPosition(position, width);
    setState(() {
      _selectionStart = _dragStartX;
      _selectionEnd = _dragStartX;
    });
  }

  void _updateSelection(double position, double width) {
    final dragStart = _dragStartX;
    if (dragStart == null || width <= 0) return;
    setState(() => _selectionEnd = _xForPosition(position, width));
  }

  void _finishSelection() {
    _dragStartX = null;
    if (_selectionStart == null || _selectionEnd == null) return;
    if ((_selectionStart! - _selectionEnd!).abs() < 1e-9) {
      setState(() {
        _selectionStart = null;
        _selectionEnd = null;
      });
    }
  }

  double _xForPosition(double position, double width) {
    final xMin = _bounds.$1;
    final xMax = _bounds.$2;
    final fraction = ((position - 54) / math.max(1, width - 68)).clamp(
      0.0,
      1.0,
    );
    return xMin + (xMax - xMin) * fraction;
  }

  (double, double, double, double) get _bounds {
    final points = _series.expand((item) => item.points).toList();
    var xMin = points.map((point) => point.x).reduce(math.min);
    var xMax = points.map((point) => point.x).reduce(math.max);
    var yMin = points.map((point) => point.y).reduce(math.min);
    var yMax = points.map((point) => point.y).reduce(math.max);
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
    return (xMin, xMax, yMin, yMax);
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
    setState(() {
      _series = series;
      _sourceLabel = source;
      _selectionStart = null;
      _selectionEnd = null;
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

  static _AnalysisStats? _statsFor(List<double> values) {
    if (values.isEmpty) return null;
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final average = values.reduce((a, b) => a + b) / values.length;
    return _AnalysisStats(
      count: values.length,
      minimum: minimum,
      maximum: maximum,
      average: average,
    );
  }

  static String _formatNumber(double value) =>
      value.abs() >= 1000 ? value.toStringAsFixed(1) : value.toStringAsFixed(4);
}

class _AnalysisChartPainter extends CustomPainter {
  const _AnalysisChartPainter({
    required this.series,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.selectionStart,
    required this.selectionEnd,
  });

  final List<_AnalysisSeries> series;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final double? selectionStart;
  final double? selectionEnd;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TalColors.input);
    final plot = Rect.fromLTRB(
      54,
      12,
      math.max(55, size.width - 14),
      math.max(13, size.height - 32),
    );
    if (plot.width <= 2 || plot.height <= 2) return;
    final grid = Paint()..color = TalColors.gridMinor;
    for (var index = 1; index < 10; index += 1) {
      final x = plot.left + plot.width * index / 10;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
    }
    for (var index = 1; index < 5; index += 1) {
      final y = plot.top + plot.height * index / 5;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    canvas.drawRect(
      plot,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = TalColors.text,
    );
    canvas.save();
    canvas.clipRect(plot);
    for (final item in series) {
      _drawSeries(canvas, plot, item);
    }
    final start = selectionStart;
    final end = selectionEnd;
    if (start != null && end != null) {
      final left = _mapX(math.min(start, end), plot);
      final right = _mapX(math.max(start, end), plot);
      canvas.drawRect(
        Rect.fromLTRB(left, plot.top, right, plot.bottom),
        Paint()..color = TalColors.accent.withAlpha(38),
      );
      canvas.drawLine(
        Offset(left, plot.top),
        Offset(left, plot.bottom),
        Paint()
          ..color = TalColors.accent
          ..strokeWidth = 1.2,
      );
      canvas.drawLine(
        Offset(right, plot.top),
        Offset(right, plot.bottom),
        Paint()
          ..color = TalColors.accent
          ..strokeWidth = 1.2,
      );
    }
    canvas.restore();
    _text(
      canvas,
      _formatAxis(yMax),
      Offset(4, plot.top - 7),
      talMuted,
      45,
      TextAlign.right,
    );
    _text(
      canvas,
      _formatAxis(yMin),
      Offset(4, plot.bottom - 7),
      talMuted,
      45,
      TextAlign.right,
    );
    _text(
      canvas,
      _formatAxis(xMin),
      Offset(plot.left - 25, plot.bottom + 5),
      talMuted,
      55,
      TextAlign.center,
    );
    _text(
      canvas,
      _formatAxis(xMax),
      Offset(plot.right - 30, plot.bottom + 5),
      talMuted,
      60,
      TextAlign.center,
    );
    _text(
      canvas,
      '时间 (s)',
      Offset(plot.center.dx - 35, size.height - 17),
      talMuted,
      70,
      TextAlign.center,
    );
  }

  void _drawSeries(Canvas canvas, Rect plot, _AnalysisSeries item) {
    final path = Path();
    var started = false;
    for (final point in item.points) {
      if (point.x < xMin || point.x > xMax) continue;
      final position = Offset(_mapX(point.x, plot), _mapY(point.y, plot));
      if (started) {
        path.lineTo(position.dx, position.dy);
      } else {
        path.moveTo(position.dx, position.dy);
        started = true;
      }
    }
    if (started) {
      canvas.drawPath(
        path,
        Paint()
          ..color = item.color
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke,
      );
    }
  }

  double _mapX(double value, Rect plot) =>
      plot.left + (value - xMin) / (xMax - xMin) * plot.width;
  double _mapY(double value, Rect plot) =>
      plot.bottom - (value - yMin) / (yMax - yMin) * plot.height;

  void _text(
    Canvas canvas,
    String value,
    Offset offset,
    TextStyle style,
    double width,
    TextAlign align,
  ) {
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

  static String _formatAxis(double value) =>
      value.abs() >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

  @override
  bool shouldRepaint(covariant _AnalysisChartPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.yMin != yMin ||
      oldDelegate.yMax != yMax ||
      oldDelegate.selectionStart != selectionStart ||
      oldDelegate.selectionEnd != selectionEnd;
}
