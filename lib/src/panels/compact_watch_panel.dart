part of 'panels.dart';

Future<void> showFullWatchTable(
  BuildContext context,
  TakeALookController controller,
) => showTalDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: SizedBox(
      width: 1180,
      height: math.min(680, MediaQuery.sizeOf(context).height - 100),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Text('完整变量表', style: talStrong),
                const Spacer(),
                TalIconButton(
                  tooltip: '关闭完整变量表',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Expanded(child: _WatchPanel(controller: controller)),
        ],
      ),
    ),
  ),
);

class _CompactWatchPanel extends StatefulWidget {
  const _CompactWatchPanel({required this.controller, this.onShowSymbols});
  final TakeALookController controller;
  final VoidCallback? onShowSymbols;
  @override
  State<_CompactWatchPanel> createState() => _CompactWatchPanelState();
}

class _CompactWatchPanelState extends State<_CompactWatchPanel> {
  int _plotSelectionRevision = -1;
  final FocusNode _panelFocus = FocusNode(debugLabel: 'compact-watch-list');
  TakeALookController get controller => widget.controller;

  @override
  void dispose() {
    _panelFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleShortcut(KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent == false ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return KeyEventResult.ignored;
    }
    if (WorkspaceShortcut.undoWatchDeletion.matches(event) &&
        controller.canUndoWatchDeletion) {
      controller.undoWatchDeletion();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        !event.synthesized &&
        event.logicalKey == LogicalKeyboardKey.delete &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        controller.compactWatchSelection != null) {
      controller.removeWatch(controller.compactWatchSelection!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(String key) {
    setState(() => controller.compactWatchSelection = key);
    controller.setPlotHighlightedWatch(key);
  }

  List<({WatchTreeNode node, int depth})> _visibleRows(
    List<WatchTreeNode> roots,
  ) {
    final result = <({WatchTreeNode node, int depth})>[];
    void visit(WatchTreeNode node, int depth) {
      result.add((node: node, depth: depth));
      if (controller.compactExpandedWatches.contains(node.watch.symbol.key)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return result;
  }

  void _syncSelection(List<WatchTreeNode> roots) {
    final keys = controller.watches.map((w) => w.symbol.key).toSet();
    if (!keys.contains(controller.compactWatchSelection)) {
      controller.compactWatchSelection =
          controller.watches.firstOrNull?.symbol.key;
    }
    if (_plotSelectionRevision == controller.plotWatchSelectionRevision) return;
    _plotSelectionRevision = controller.plotWatchSelectionRevision;
    final key = controller.plotHighlightedWatchKey;
    if (key == null || !keys.contains(key)) return;
    controller.compactWatchSelection = key;
    bool reveal(WatchTreeNode node) {
      if (node.watch.symbol.key == key) return true;
      for (final child in node.children) {
        if (reveal(child)) {
          controller.compactExpandedWatches.add(node.watch.symbol.key);
          return true;
        }
      }
      return false;
    }

    for (final root in roots) {
      if (reveal(root)) break;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.watchChanges,
      controller.samplingChanges,
      controller.connectionChanges,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 40) return const SizedBox.shrink();
        final roots = buildWatchTree(controller.watches);
        _syncSelection(roots);
        final rows = _visibleRows(roots);
        return PanelKeyboardListener(
          focusNode: _panelFocus,
          onKeyEvent: _handleShortcut,
          child: Material(
            color: WorkbenchColors.surface,
            child: Column(
              children: [
                _toolbar(context),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('从资源库加入变量', style: workbenchMuted),
                                const SizedBox(height: 10),
                                if (widget.onShowSymbols != null)
                                  TalButton(
                                    onPressed: widget.onShowSymbols,
                                    child: const Text('打开资源库'),
                                  ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('compact-watch-list'),
                          itemCount: rows.length,
                          itemBuilder: (context, index) {
                            final item = rows[index],
                                node = item.node,
                                watch = node.watch;
                            if (node.children.isNotEmpty) {
                              return InkWell(
                                onTap: () => setState(() {
                                  if (!controller.compactExpandedWatches.add(
                                    watch.symbol.key,
                                  )) {
                                    controller.compactExpandedWatches.remove(
                                      watch.symbol.key,
                                    );
                                  }
                                }),
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    8 + item.depth * 8,
                                    12,
                                    8,
                                    12,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        controller.compactExpandedWatches
                                                .contains(watch.symbol.key)
                                            ? Icons.expand_more
                                            : Icons.chevron_right,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          node.label,
                                          style: talMono,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        '${node.children.length}',
                                        style: workbenchMuted,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                            return WatchRowAnchor(
                              key: ValueKey(
                                'compact-watch-${watch.symbol.key}',
                              ),
                              controller: controller,
                              watchKey: watch.symbol.key,
                              child: _CompactWatchRow(
                                key: ValueKey(watch.symbol.key),
                                controller: controller,
                                watch: watch,
                                label: node.label,
                                depth: item.depth,
                                selected:
                                    watch.symbol.key ==
                                    controller.compactWatchSelection,
                                onSelect: () => _select(watch.symbol.key),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _toolbar(BuildContext context) {
    final ui = TalUiTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: const BoxDecoration(
        color: WorkbenchColors.input,
        border: Border(bottom: BorderSide(color: WorkbenchColors.border)),
      ),
      child: Row(
        children: [
          const Flexible(
            child: Text(
              '监视默认',
              style: workbenchMuted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: ui.touchOptimized ? 106 : 90,
            child: TalDropdown<double>(
              key: const ValueKey('watch-default-monitor-rate'),
              value: controller.monitorRateHz,
              values: const [0.5, 1, 2, 5, 10],
              label: formatReadRate,
              onChanged: controller.setMonitorRate,
            ),
          ),
          const Spacer(),
          TalIconButton(
            key: const ValueKey('compact-watch-undo'),
            tooltip: '撤回删除 (Ctrl+Z) · 采集中删除可在 10 秒内撤回',
            onPressed: controller.canUndoWatchDeletion
                ? controller.undoWatchDeletion
                : null,
            icon: const Icon(Icons.undo, size: 16),
          ),
        ],
      ),
    );
  }
}

class _CompactWatchRow extends StatefulWidget {
  const _CompactWatchRow({
    super.key,
    required this.controller,
    required this.watch,
    required this.label,
    required this.depth,
    required this.selected,
    required this.onSelect,
  });
  final TakeALookController controller;
  final WatchItem watch;
  final String label;
  final int depth;
  final bool selected;
  final VoidCallback onSelect;
  @override
  State<_CompactWatchRow> createState() => _CompactWatchRowState();
}

class _CompactWatchRowState extends State<_CompactWatchRow> {
  late final TextEditingController _editor;
  final _focus = FocusNode();
  bool _writing = false;
  bool _written = false;
  String? _writeError;
  int _editRevision = 0;
  String get _key => widget.watch.symbol.key;

  void _activate() {
    widget.onSelect();
    Focus.of(context).requestFocus();
  }

  Future<void> _adjustColor() async {
    _activate();
    final color = await showTalDialog<Color>(
      context: context,
      builder: (context) => WatchColorDialog(initialColor: widget.watch.color),
    );
    if (mounted && color != null) widget.controller.setWatchColor(_key, color);
  }

  Future<void> _showContextMenu(Offset position, {bool touch = false}) async {
    _activate();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    final controller = widget.controller;
    final watch = widget.watch;
    final action = await showTalContextMenu<String>(
      context: context,
      position: RelativeRect.fromSize(local & Size.zero, overlay.size),
      touchOptimized: touch,
      items: [
        _watchPopupItem(
          value: 'color',
          icon: Icons.palette_outlined,
          label: '颜色调整',
          touchOptimized: touch,
        ),
        _watchPopupItem(
          value: 'visibility',
          icon: watch.plotted
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          label: watch.plotted ? '隐藏曲线' : '显示曲线',
          enabled: watch.samplingEnabled,
          touchOptimized: touch,
        ),
        const PopupMenuDivider(),
        _watchPopupItem(
          value: 'delete',
          icon: Icons.delete_outline,
          label: '删除变量',
          touchOptimized: touch,
        ),
        _watchPopupItem(
          value: 'undo',
          icon: Icons.undo,
          label: '撤回删除',
          enabled: controller.canUndoWatchDeletion,
          touchOptimized: touch,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'color':
        await _adjustColor();
      case 'visibility':
        controller.toggleWatchPlot(_key, !watch.plotted);
      case 'delete':
        controller.removeWatch(_key);
      case 'undo':
        controller.undoWatchDeletion();
    }
  }

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(
      text: widget.controller.watchInputDrafts[_key] ?? '',
    );
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (_focus.hasFocus) widget.onSelect();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _CompactWatchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final draft = widget.controller.watchInputDrafts[_key] ?? '';
    if (!_focus.hasFocus && _editor.text != draft) {
      _editor.text = draft;
      _written = false;
      _writeError = null;
      _editRevision++;
    }
  }

  void _changeDraft(String value) {
    widget.controller.watchInputDrafts[_key] = value;
    setState(() {
      _written = false;
      _writeError = null;
      _editRevision++;
    });
  }

  void _clearDraft() {
    _editor.clear();
    _changeDraft('');
  }

  Future<void> _write() async {
    final controller = widget.controller;
    if (_writing ||
        _editor.text.trim().isEmpty ||
        controller.connectionStatus != ConnectionStatus.connected ||
        !controller.supportsMemoryWrite ||
        !widget.watch.symbol.writable) {
      return;
    }
    final revision = _editRevision;
    final text = _editor.text;
    setState(() {
      _writing = true;
      _written = false;
      _writeError = null;
    });
    final success = await controller.writeWatch(_key, text);
    if (!mounted) return;
    setState(() {
      _writing = false;
      // A completion belongs to the submitted draft, never a newer edit.
      if (_editRevision != revision) return;
      _written = success;
      _writeError = success
          ? null
          : controller.lastBackendError?['message'] as String? ?? '变量写入失败。';
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _editor.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    final watch = widget.watch;
    final controller = widget.controller;
    final canWrite =
        controller.connectionStatus == ConnectionStatus.connected &&
        controller.supportsMemoryWrite &&
        watch.symbol.writable;
    final hasDraft = _editor.text.trim().isNotEmpty;
    final borderColor = _writeError != null
        ? TalColors.error
        : _focus.hasFocus
        ? TalColors.accent
        : TalColors.controlBorder;
    final radius = ui.controlRadius;
    final writeWidth = ui.touchOptimized ? 60.0 : 54.0;
    final action = SizedBox.square(
      dimension: ui.iconButtonSize,
      child: TalIconButton(
        key: ValueKey('compact-watch-plot-$_key'),
        tooltip: watch.readMode == WatchReadMode.manual
            ? '立即读取'
            : watch.plotted
            ? '隐藏曲线'
            : '显示曲线',
        onPressed: watch.readMode == WatchReadMode.manual
            ? (controller.connectionStatus == ConnectionStatus.connected
                  ? () => controller.readWatch(_key)
                  : null)
            : watch.samplingEnabled
            ? () => controller.toggleWatchPlot(_key, !watch.plotted)
            : null,
        icon: Icon(
          watch.readMode == WatchReadMode.manual
              ? Icons.refresh
              : watch.plotted
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          size: 16,
        ),
      ),
    );
    final writeGroup = SizedBox(
      key: ValueKey('compact-watch-write-group-$_key'),
      width: 120 + writeWidth + 2,
      height: ui.controlHeight,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: radius,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: WorkbenchColors.input,
            child: Row(
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape):
                          _clearDraft,
                    },
                    child: TextField(
                      key: ValueKey('compact-watch-input-$_key'),
                      controller: _editor,
                      focusNode: _focus,
                      style: talMono,
                      textAlign: TextAlign.right,
                      textAlignVertical: TextAlignVertical.center,
                      enabled: watch.symbol.writable,
                      decoration: InputDecoration(
                        constraints: BoxConstraints.tightFor(
                          height: ui.controlHeight,
                        ),
                        isDense: false,
                        filled: false,
                        hintText: watch.symbol.writable ? '输入新值' : '只读',
                        hintStyle: workbenchMuted.copyWith(fontSize: 12),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 9,
                        ),
                        // Preserve outline-field baseline geometry inside the
                        // shared border, without painting a second outline.
                        border: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                        ),
                        disabledBorder: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: _changeDraft,
                      onSubmitted: canWrite ? (_) => _write() : null,
                    ),
                  ),
                ),
                Container(width: 1, color: TalColors.controlBorder),
                SizedBox(
                  width: writeWidth,
                  height: ui.controlHeight,
                  child: TalButton(
                    key: ValueKey('compact-watch-write-$_key'),
                    variant: hasDraft && !_written
                        ? TalButtonVariant.filled
                        : TalButtonVariant.text,
                    style: ButtonStyle(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4),
                      ),
                      shape: const WidgetStatePropertyAll(
                        RoundedRectangleBorder(),
                      ),
                      foregroundColor: _written
                          ? const WidgetStatePropertyAll(TalColors.success)
                          : null,
                    ),
                    onPressed: canWrite && hasDraft && !_writing
                        ? _write
                        : null,
                    child: Text(
                      _writing
                          ? '写入中'
                          : _written
                          ? '已写入'
                          : '写入',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return InkWell(
      onTap: _activate,
      onSecondaryTapUp: (details) => _showContextMenu(details.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject()! as RenderBox;
        _showContextMenu(
          box.localToGlobal(box.size.center(Offset.zero)),
          touch: true,
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: widget.selected
              ? WorkbenchColors.selection
              : WorkbenchColors.surface,
          border: Border(
            left: BorderSide(
              color: widget.selected ? TalColors.accent : Colors.transparent,
              width: 2,
            ),
            bottom: const BorderSide(color: WorkbenchColors.border),
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                21 + math.min(widget.depth, 3) * 8,
                7,
                11,
                7,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Keep the accepted 120px editor; only stack when the dock is too narrow.
                  final narrow =
                      constraints.maxWidth < (ui.touchOptimized ? 272 : 260);
                  final valueLabel = AnimatedBuilder(
                    animation: controller.telemetryChanges,
                    builder: (context, _) {
                      final value = watch.updatedAtMs == null
                          ? '—'
                          : watch.valueLabel;
                      return Tooltip(
                        message: value,
                        triggerMode: TooltipTriggerMode.manual,
                        child: Text(
                          value,
                          key: ValueKey('compact-watch-value-$_key'),
                          style: talMono.copyWith(fontSize: 14),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: watch.symbol.name,
                              triggerMode: TooltipTriggerMode.manual,
                              child: Text(
                                widget.label,
                                style: talMono,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: ui.touchOptimized ? 112 : 96,
                            child: TalDropdown<WatchReadMode>(
                              key: ValueKey('watch-read-mode-$_key'),
                              subtle: true,
                              value: watch.readMode,
                              values: WatchReadMode.values,
                              label: (mode) => mode.label,
                              onChanged: (mode) {
                                widget.onSelect();
                                controller.setWatchReadMode(_key, mode);
                              },
                            ),
                          ),
                          action,
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (narrow) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: valueLabel,
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth,
                            ),
                            child: writeGroup,
                          ),
                        ),
                      ] else
                        Row(
                          children: [
                            SizedBox(
                              width: ui.touchOptimized ? 82 : 76,
                              child: valueLabel,
                            ),
                            const SizedBox(width: 8),
                            const Spacer(),
                            writeGroup,
                          ],
                        ),
                      if (_writeError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            _writeError!,
                            key: ValueKey('compact-watch-write-error-$_key'),
                            style: workbenchMuted.copyWith(
                              color: TalColors.error,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (watch.samplingEnabled)
              Positioned(
                left: math.min(widget.depth, 3) * 8,
                top: 0,
                bottom: 0,
                width: 23,
                child: Tooltip(
                  message: '双击调整颜色',
                  triggerMode: TooltipTriggerMode.manual,
                  child: GestureDetector(
                    key: ValueKey('compact-watch-color-$_key'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _activate,
                    onDoubleTap: _adjustColor,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 14),
                      child: DecoratedBox(
                        key: ValueKey('compact-watch-color-bar-$_key'),
                        decoration: BoxDecoration(
                          color: watch.color,
                          borderRadius: BorderRadius.circular(2),
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
