part of '../panels.dart';

const _watchColumnLabels = <String>[
  '变量',
  '地址',
  '类型',
  '当前值',
  '写入值',
  '操作',
  '是否绘制',
  '绘制颜色',
];

typedef _WatchRowContextMenuCallback =
    void Function(String key, _ContextMenuRequest request);

class _WatchPanel extends StatefulWidget {
  const _WatchPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_WatchPanel> createState() => _WatchPanelState();
}

class _WatchPanelState extends State<_WatchPanel> {
  static const _minimumColumnWidths = <double>[72, 88, 72, 72, 72, 108, 72, 72];

  List<double> _columnWidths = <double>[180, 112, 96, 96, 96, 116, 84, 96];
  List<double> _resizeColumnWidths = const <double>[];
  double _rowHeight = 44;
  double _resizeRowHeight = 44;
  final FocusNode _tableFocus = FocusNode(debugLabel: 'watch-table');
  final Set<String> _selectedWatchKeys = <String>{};
  final Set<int> _selectedColumns = <int>{};
  final Set<int> _hiddenColumns = <int>{};
  String? _selectionAnchorKey;

  TakeALookController get controller => widget.controller;
  double get _tableWidth => _columnWidths.indexed
      .where((entry) => !_hiddenColumns.contains(entry.$1))
      .fold(0, (sum, entry) => sum + entry.$2);

  @override
  void dispose() {
    _tableFocus.dispose();
    super.dispose();
  }

  void _beginTableResize() {
    _resizeColumnWidths = List<double>.of(_columnWidths);
    _resizeRowHeight = _rowHeight;
  }

  void _resizeTable(Offset delta) {
    if (_resizeColumnWidths.length != _columnWidths.length) return;
    final columnDelta = delta.dx * 0.85;
    final rowDelta = delta.dy * 0.85;
    setState(() {
      _columnWidths = <double>[
        for (var index = 0; index < _resizeColumnWidths.length; index += 1)
          math.max(
            _minimumColumnWidths[index],
            _resizeColumnWidths[index] + columnDelta,
          ),
      ];
      _rowHeight = math.max(40, _resizeRowHeight + rowDelta);
    });
  }

  void _resizeColumn(int index, double delta) {
    if (index < 0 || index >= _columnWidths.length) return;
    setState(() {
      final next = List<double>.of(_columnWidths);
      next[index] = math.max(_minimumColumnWidths[index], next[index] + delta);
      _columnWidths = next;
    });
  }

  void _normalizeSelection() {
    final available = controller.watches
        .map((watch) => watch.symbol.key)
        .toSet();
    _selectedWatchKeys.removeWhere((key) => !available.contains(key));
    if (!available.contains(_selectionAnchorKey)) _selectionAnchorKey = null;
  }

  void _selectWatch(String key) {
    final keys = controller.watches.map((watch) => watch.symbol.key).toList();
    final index = keys.indexOf(key);
    if (index < 0) return;
    final keyboard = HardwareKeyboard.instance;
    final additive = keyboard.isControlPressed || keyboard.isMetaPressed;
    final ranged = keyboard.isShiftPressed && _selectionAnchorKey != null;
    setState(() {
      if (ranged) {
        final anchor = keys.indexOf(_selectionAnchorKey!);
        final start = math.min(anchor < 0 ? index : anchor, index);
        final end = math.max(anchor < 0 ? index : anchor, index);
        if (!additive) _selectedWatchKeys.clear();
        _selectedWatchKeys.addAll(keys.sublist(start, end + 1));
      } else if (additive) {
        if (!_selectedWatchKeys.add(key)) _selectedWatchKeys.remove(key);
        _selectionAnchorKey = key;
      } else {
        _selectedColumns.clear();
        _selectedWatchKeys
          ..clear()
          ..add(key);
        _selectionAnchorKey = key;
      }
    });
    _tableFocus.requestFocus();
  }

  void _selectAllWatches() {
    final watches = controller.watches;
    setState(() {
      _selectedWatchKeys
        ..clear()
        ..addAll(watches.map((watch) => watch.symbol.key));
      _selectedColumns
        ..clear()
        ..addAll(List<int>.generate(_columnWidths.length, (index) => index));
      _selectionAnchorKey = watches.isEmpty ? null : watches.first.symbol.key;
    });
  }

  List<String> _contextWatchKeys(String clickedKey) {
    if (!_selectedWatchKeys.contains(clickedKey)) {
      setState(() {
        _selectedWatchKeys
          ..clear()
          ..add(clickedKey);
        _selectionAnchorKey = clickedKey;
      });
    }
    _tableFocus.requestFocus();
    return [
      for (final watch in controller.watches)
        if (_selectedWatchKeys.contains(watch.symbol.key)) watch.symbol.key,
    ];
  }

  void _selectColumn(int index) {
    final additive = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (additive) {
        if (!_selectedColumns.add(index)) _selectedColumns.remove(index);
      } else {
        _selectedWatchKeys.clear();
        _selectedColumns
          ..clear()
          ..add(index);
      }
    });
    _tableFocus.requestFocus();
  }

  int? _columnAt(double x) {
    var left = 0.0;
    for (var index = 0; index < _columnWidths.length; index += 1) {
      if (_hiddenColumns.contains(index)) continue;
      final right = left + _columnWidths[index];
      if (x >= left && x < right) return index;
      left = right;
    }
    return null;
  }

  bool _canStartTableResize(Offset position) {
    final column = _columnAt(position.dx);
    return column != 0 && column != 6;
  }

  RelativeRect _menuPosition(Offset globalPosition) {
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

  Future<void> _showHeaderContextMenu(
    int clickedColumn,
    _ContextMenuRequest request,
  ) async {
    final targetColumns = _selectedColumns.length > 1
        ? (_selectedColumns.toList()..sort())
        : <int>[clickedColumn];
    final visibleCount = _columnWidths.length - _hiddenColumns.length;
    final canHide =
        visibleCount > 1 &&
        targetColumns.any((column) => !_hiddenColumns.contains(column));
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'hide',
          icon: Icons.visibility_off_outlined,
          label: targetColumns.length == 1
              ? '隐藏该列'
              : '隐藏所选列（${targetColumns.length}）',
          enabled: canHide,
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'showAll',
          icon: Icons.view_column_outlined,
          label: '显示全列',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    setState(() {
      if (action == 'showAll') {
        _hiddenColumns.clear();
        return;
      }
      for (final column in targetColumns) {
        if (_columnWidths.length - _hiddenColumns.length <= 1) break;
        _hiddenColumns.add(column);
      }
    });
  }

  Future<void> _showNameContextMenu(
    String clickedKey,
    _ContextMenuRequest request,
  ) async {
    final keys = _contextWatchKeys(clickedKey);
    if (keys.isEmpty) return;
    final count = keys.length;
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'remove',
          icon: Icons.close,
          label: count == 1 ? '移除该变量' : '移除所选变量（$count）',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'copy',
          icon: Icons.copy_outlined,
          label: count == 1 ? '复制命令名' : '复制所选命令名（$count）',
          touchOptimized: request.touchOptimized,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          value: 'only',
          icon: Icons.filter_alt_outlined,
          label: count == 1 ? '仅绘制该栏' : '仅绘制所选变量（$count）',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'all',
          icon: Icons.check_box_outlined,
          label: '全部绘制',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'none',
          icon: Icons.check_box_outline_blank,
          label: '全部不绘制',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'invert',
          icon: Icons.swap_vert,
          label: '反转所选变量绘制状态',
          touchOptimized: request.touchOptimized,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          value: 'color',
          icon: Icons.palette_outlined,
          label: count == 1 ? '设置绘制颜色' : '为所选变量设置绘制颜色（$count）',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'remove':
        _selectedWatchKeys.removeAll(keys);
        controller.removeWatches(keys);
      case 'copy':
        final names = [
          for (final watch in controller.watches)
            if (keys.contains(watch.symbol.key)) watch.symbol.name,
        ];
        await Clipboard.setData(ClipboardData(text: names.join('\n')));
      case 'only':
        controller.setOnlyWatchesPlotted(keys);
      case 'all':
        controller.setAllWatchesPlotted(true);
      case 'none':
        controller.setAllWatchesPlotted(false);
      case 'invert':
        controller.invertWatchPlots(keys);
      case 'color':
        final initial = controller.watches
            .firstWhere((watch) => keys.contains(watch.symbol.key))
            .color;
        final color = await showDialog<Color>(
          context: context,
          builder: (context) => _WatchColorDialog(initialColor: initial),
        );
        if (mounted && color != null) controller.setWatchColors(keys, color);
    }
  }

  Future<void> _showPlotContextMenu(
    String clickedKey,
    _ContextMenuRequest request,
  ) async {
    final keys = _contextWatchKeys(clickedKey);
    if (keys.isEmpty) return;
    final action = await showTalContextMenu<String>(
      context: context,
      position: _menuPosition(request.globalPosition),
      touchOptimized: request.touchOptimized,
      items: [
        _watchPopupItem(
          value: 'only',
          icon: Icons.filter_alt_outlined,
          label: '仅绘制该栏',
          touchOptimized: request.touchOptimized,
        ),
        _watchPopupItem(
          value: 'all',
          icon: Icons.check_box_outlined,
          label: '全部绘制',
          touchOptimized: request.touchOptimized,
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'only') controller.setOnlyWatchesPlotted(keys);
    if (action == 'all') controller.setAllWatchesPlotted(true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.watchChanges,
      builder: (context, _) {
        _normalizeSelection();
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(
                      LogicalKeyboardKey.keyA,
                      control: true,
                    ): _selectAllWatches,
                    const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                        _selectAllWatches,
                  },
                  child: Focus(
                    focusNode: _tableFocus,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = math.max(
                          _tableWidth,
                          constraints.maxWidth,
                        );
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            key: const ValueKey('watch-table-content'),
                            width: width,
                            height: constraints.maxHeight,
                            child: Column(
                              children: [
                                _WatchTableHeader(
                                  columnWidths: _columnWidths,
                                  hiddenColumns: _hiddenColumns,
                                  selectedColumns: _selectedColumns,
                                  onResizeColumn: _resizeColumn,
                                  onSelectColumn: _selectColumn,
                                  onContextMenu: _showHeaderContextMenu,
                                ),
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      color: TalColors.input,
                                      border: Border(
                                        left: BorderSide(
                                          color: TalColors.border,
                                        ),
                                        right: BorderSide(
                                          color: TalColors.border,
                                        ),
                                        bottom: BorderSide(
                                          color: TalColors.border,
                                        ),
                                      ),
                                    ),
                                    child: _RightDragResizeRegion(
                                      key: const ValueKey(
                                        'watch-table-resize-region',
                                      ),
                                      onResizeStart: _beginTableResize,
                                      onResize: _resizeTable,
                                      canStartAt: _canStartTableResize,
                                      child: controller.watches.isEmpty
                                          ? const SizedBox.expand()
                                          : ListView.builder(
                                              itemCount:
                                                  controller.watches.length,
                                              itemBuilder: (context, index) =>
                                                  _WatchRow(
                                                    controller: controller,
                                                    watch: controller
                                                        .watches[index],
                                                    columnWidths: _columnWidths,
                                                    hiddenColumns:
                                                        _hiddenColumns,
                                                    selectedColumns:
                                                        _selectedColumns,
                                                    rowHeight: _rowHeight,
                                                    selected: _selectedWatchKeys
                                                        .contains(
                                                          controller
                                                              .watches[index]
                                                              .symbol
                                                              .key,
                                                        ),
                                                    onSelect: _selectWatch,
                                                    onNameContextMenu:
                                                        _showNameContextMenu,
                                                    onPlotContextMenu:
                                                        _showPlotContextMenu,
                                                    key: ValueKey<String>(
                                                      controller
                                                          .watches[index]
                                                          .symbol
                                                          .key,
                                                    ),
                                                  ),
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '从左侧符号层级中选择变量，然后加入实时调参。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: talMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: controller.watches.isEmpty
                        ? null
                        : controller.clearWatches,
                    child: const Text('清空监视'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WatchTableHeader extends StatelessWidget {
  const _WatchTableHeader({
    required this.columnWidths,
    required this.hiddenColumns,
    required this.selectedColumns,
    required this.onResizeColumn,
    required this.onSelectColumn,
    required this.onContextMenu,
  });

  final List<double> columnWidths;
  final Set<int> hiddenColumns;
  final Set<int> selectedColumns;
  final _ColumnResizeCallback onResizeColumn;
  final ValueChanged<int> onSelectColumn;
  final _ColumnContextMenuCallback onContextMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border.symmetric(
          horizontal: BorderSide(color: TalColors.border),
        ),
      ),
      child: Row(
        children: [
          for (final (index, label) in _watchColumnLabels.indexed)
            if (!hiddenColumns.contains(index))
              _ResizableTableHeaderCell(
                label: label,
                width: columnWidths[index],
                columnIndex: index,
                keyPrefix: 'watch',
                onResize: onResizeColumn,
                selected: selectedColumns.contains(index),
                onSelect: onSelectColumn,
                onContextMenu: onContextMenu,
              ),
        ],
      ),
    );
  }
}

class _WatchRow extends StatefulWidget {
  const _WatchRow({
    required this.controller,
    required this.watch,
    required this.columnWidths,
    required this.hiddenColumns,
    required this.selectedColumns,
    required this.rowHeight,
    required this.selected,
    required this.onSelect,
    required this.onNameContextMenu,
    required this.onPlotContextMenu,
    super.key,
  });

  final TakeALookController controller;
  final WatchItem watch;
  final List<double> columnWidths;
  final Set<int> hiddenColumns;
  final Set<int> selectedColumns;
  final double rowHeight;
  final bool selected;
  final ValueChanged<String> onSelect;
  final _WatchRowContextMenuCallback onNameContextMenu;
  final _WatchRowContextMenuCallback onPlotContextMenu;

  @override
  State<_WatchRow> createState() => _WatchRowState();
}

class _WatchRowState extends State<_WatchRow> {
  late final TextEditingController editor;

  @override
  void initState() {
    super.initState();
    editor = TextEditingController(text: widget.watch.valueLabel);
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> _chooseColor() async {
    final color = await showDialog<Color>(
      context: context,
      builder: (context) => _WatchColorDialog(initialColor: widget.watch.color),
    );
    if (!mounted || color == null) return;
    widget.controller.setWatchColor(widget.watch.symbol.key, color);
  }

  @override
  Widget build(BuildContext context) {
    final watch = widget.watch;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kPrimaryMouseButton != 0) {
          widget.onSelect(watch.symbol.key);
        }
      },
      child: Container(
        height: widget.rowHeight,
        decoration: BoxDecoration(
          color: widget.selected ? TalColors.selection : TalColors.input,
          border: const Border(bottom: BorderSide(color: TalColors.borderSoft)),
        ),
        child: Row(
          children: [
            if (!widget.hiddenColumns.contains(0))
              _WatchCell(
                width: widget.columnWidths[0],
                selected: widget.selectedColumns.contains(0),
                onContextMenu: (request) =>
                    widget.onNameContextMenu(watch.symbol.key, request),
                child: Text(
                  watch.symbol.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: talBody,
                ),
              ),
            if (!widget.hiddenColumns.contains(1))
              _WatchCell(
                width: widget.columnWidths[1],
                selected: widget.selectedColumns.contains(1),
                child: Text(watch.symbol.addressLabel, style: talMono),
              ),
            if (!widget.hiddenColumns.contains(2))
              _WatchCell(
                width: widget.columnWidths[2],
                selected: widget.selectedColumns.contains(2),
                child: Text(watch.symbol.type, style: talMuted),
              ),
            if (!widget.hiddenColumns.contains(3))
              _WatchCell(
                width: widget.columnWidths[3],
                selected: widget.selectedColumns.contains(3),
                child: AnimatedBuilder(
                  animation: widget.controller.telemetryChanges,
                  builder: (context, _) =>
                      Text(widget.watch.valueLabel, style: talMono),
                ),
              ),
            if (!widget.hiddenColumns.contains(4))
              _WatchCell(
                width: widget.columnWidths[4],
                selected: widget.selectedColumns.contains(4),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: SizedBox(
                  height: 30,
                  child: TextField(
                    controller: editor,
                    enabled: watch.symbol.writable,
                    style: talMono,
                  ),
                ),
              ),
            if (!widget.hiddenColumns.contains(5))
              _WatchCell(
                width: widget.columnWidths[5],
                selected: widget.selectedColumns.contains(5),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '写入',
                      onPressed: watch.symbol.writable
                          ? () => widget.controller.writeWatch(
                              watch.symbol.key,
                              editor.text,
                            )
                          : null,
                      icon: const Icon(Icons.save_outlined, size: 16),
                    ),
                    IconButton(
                      tooltip: '移除',
                      onPressed: () =>
                          widget.controller.removeWatch(watch.symbol.key),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ],
                ),
              ),
            if (!widget.hiddenColumns.contains(6))
              _WatchCell(
                width: widget.columnWidths[6],
                selected: widget.selectedColumns.contains(6),
                padding: EdgeInsets.zero,
                onContextMenu: (request) =>
                    widget.onPlotContextMenu(watch.symbol.key, request),
                child: Center(
                  child: Checkbox(
                    value: watch.plotted,
                    onChanged: (value) => widget.controller.toggleWatchPlot(
                      watch.symbol.key,
                      value ?? false,
                    ),
                  ),
                ),
              ),
            if (!widget.hiddenColumns.contains(7))
              _WatchCell(
                width: widget.columnWidths[7],
                selected: widget.selectedColumns.contains(7),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: _colorHex(watch.color),
                    child: Material(
                      color: watch.color,
                      borderRadius: BorderRadius.circular(3),
                      child: InkWell(
                        key: ValueKey('watch-color-${watch.symbol.key}'),
                        onTap: _chooseColor,
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          width: 36,
                          height: 18,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: TalColors.border),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WatchColorDialog extends StatefulWidget {
  const _WatchColorDialog({required this.initialColor});

  final Color initialColor;

  @override
  State<_WatchColorDialog> createState() => _WatchColorDialogState();
}

class _WatchColorDialogState extends State<_WatchColorDialog> {
  static const _presets = <Color>[
    ...seriesColors,
    Color(0xFFE25858),
    Color(0xFF22C55E),
    Color(0xFF06B6D4),
    Color(0xFFEAB308),
    Color(0xFFF8FAFC),
  ];

  late HSVColor _hsv;
  late final TextEditingController _hexController;

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(
      text: _colorHex(widget.initialColor),
    );
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _setColor(Color color) {
    setState(() => _hsv = HSVColor.fromColor(color));
    _hexController.text = _colorHex(color);
  }

  void _setHsv(HSVColor color) {
    setState(() => _hsv = color);
    _hexController.text = _colorHex(color.toColor());
  }

  void _applyHex(String value) {
    if (value.length != 6) return;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed)));
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          SizedBox(width: 48, child: Text(label, style: talMuted)),
          Expanded(
            child: Slider(
              value: value.clamp(0, max),
              max: max,
              activeColor: _color,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              max == 360
                  ? value.round().toString()
                  : '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: talMono,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.palette_outlined, size: 19),
          SizedBox(width: 8),
          Text('选择绘制颜色'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey('watch-color-preview'),
              height: 34,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: TalColors.border),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in _presets)
                  Material(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                    child: InkWell(
                      key: ValueKey('watch-color-preset-${color.toARGB32()}'),
                      onTap: () => _setColor(color),
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        width: 26,
                        height: 22,
                        child: color == _color
                            ? Icon(
                                Icons.check,
                                size: 15,
                                color: color.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _slider(
              label: '色相',
              value: _hsv.hue,
              max: 360,
              onChanged: (value) => _setHsv(_hsv.withHue(value)),
            ),
            _slider(
              label: '饱和度',
              value: _hsv.saturation,
              max: 1,
              onChanged: (value) => _setHsv(_hsv.withSaturation(value)),
            ),
            _slider(
              label: '亮度',
              value: _hsv.value,
              max: 1,
              onChanged: (value) => _setHsv(_hsv.withValue(value)),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('watch-color-hex'),
              controller: _hexController,
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              ],
              textCapitalization: TextCapitalization.characters,
              style: talMono,
              decoration: const InputDecoration(
                labelText: 'HEX',
                prefixText: '#',
                counterText: '',
              ),
              onChanged: _applyHex,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('watch-color-confirm'),
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

String _colorHex(Color color) => (color.toARGB32() & 0xFFFFFF)
    .toRadixString(16)
    .padLeft(6, '0')
    .toUpperCase();

PopupMenuEntry<String> _watchPopupItem({
  required String value,
  required IconData icon,
  required String label,
  bool enabled = true,
  required bool touchOptimized,
}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: touchOptimized ? 48 : 32,
    child: Row(
      children: [Icon(icon, size: 17), const SizedBox(width: 9), Text(label)],
    ),
  );
}

class _WatchCell extends StatelessWidget {
  const _WatchCell({
    required this.width,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.onContextMenu,
    this.selected = false,
  });

  final double width;
  final Widget child;
  final EdgeInsets padding;
  final ValueChanged<_ContextMenuRequest>? onContextMenu;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cell = Container(
      width: width,
      padding: padding,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: selected ? TalColors.selection : Colors.transparent,
        border: const Border(right: BorderSide(color: TalColors.borderSoft)),
      ),
      child: child,
    );
    final callback = onContextMenu;
    if (callback == null) return cell;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => callback(
        _ContextMenuRequest(
          globalPosition: details.globalPosition,
          touchOptimized: false,
        ),
      ),
      onLongPressStart: (details) => callback(
        _ContextMenuRequest(
          globalPosition: details.globalPosition,
          touchOptimized: true,
        ),
      ),
      child: cell,
    );
  }
}
