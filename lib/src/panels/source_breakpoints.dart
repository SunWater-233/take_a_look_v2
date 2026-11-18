part of 'source_debug_panel.dart';

extension _SourceBreakpoints on _SourceDebugPanelState {
  double get _breakpointDockWidth =>
      TalUiTheme.of(context).touchOptimized ? 380 : 320;

  Widget _buildSourceWorkspace(double width) {
    final ui = TalUiTheme.of(context);
    final showActions = !widget.readOnlyPreview;
    final stepWidth = showActions && _selectedPath != null
        ? math.min(ui.iconButtonSize * 3 + 15, width)
        : 0.0;
    final toolbarWidth = _breakpointDockOpen
        ? math.min(_breakpointDockWidth, width)
        : math.min(ui.touchOptimized ? 220.0 : 180.0, width);
    final search = _searchVisible ? _buildSearchField() : null;
    final minSearchWidth = ui.iconButtonSize * 3 + 180;
    final inlineSearch =
        search != null &&
        showActions &&
        width - stepWidth - toolbarWidth >= minSearchWidth;
    final steps = stepWidth == 0
        ? null
        : SizedBox(width: stepWidth, child: _buildSourceStepToolbar());
    final toolbar = showActions
        ? _buildBreakpointToolbar(
            toolbarWidth,
            sideBySide: _usesSideBreakpointDock(width),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (toolbar != null)
          if (inlineSearch ||
              (steps != null && stepWidth + toolbarWidth <= width))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?steps,
                Expanded(
                  child: inlineSearch ? search : const SizedBox.shrink(),
                ),
                toolbar,
              ],
            )
          else ...[
            if (steps != null)
              Align(alignment: AlignmentDirectional.centerStart, child: steps),
            Align(alignment: AlignmentDirectional.centerEnd, child: toolbar),
          ],
        Expanded(
          child: _buildSourceContent(
            width,
            searchField: inlineSearch ? null : search,
          ),
        ),
      ],
    );
  }

  Widget _buildBreakpointToolbar(double width, {required bool sideBySide}) {
    final settings = controller.debugState.breakpointSettings;
    final count = settings.requested.values.fold(
      0,
      (total, lines) => total + lines.length,
    );
    final ui = TalUiTheme.of(context);
    final reason = controller.breakpointEditDisabledReason;
    final pauseLabel = settings.paused ? '恢复所有断点' : '暂停所有断点';

    Widget action(
      String key,
      String label,
      IconData icon,
      VoidCallback? onPressed, {
      bool selected = false,
    }) => SizedBox.square(
      dimension: ui.iconButtonSize,
      child: TalIconButton(
        key: ValueKey(key),
        tooltip: reason == null ? label : '$label（$reason）',
        icon: Icon(
          icon,
          size: 18,
          color: selected && onPressed != null ? TalColors.amber : null,
        ),
        style: selected
            ? IconButton.styleFrom(
                backgroundColor: TalColors.amber.withValues(alpha: .12),
              )
            : null,
        onPressed: onPressed,
      ),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        action(
          'clear-all-breakpoints',
          '清除所有断点',
          Icons.layers_clear_outlined,
          reason == null && count > 0
              ? () => unawaited(_removeBreakpoints())
              : null,
        ),
        action(
          'pause-all-breakpoints',
          pauseLabel,
          settings.paused
              ? Icons.play_circle_outline
              : Icons.pause_circle_outline,
          reason == null && (count > 0 || settings.paused)
              ? () => unawaited(
                  controller.editBreakpoints(
                    BreakpointAction.setPaused,
                    value: !settings.paused,
                  ),
                )
              : null,
          selected: settings.paused,
        ),
        const SizedBox(width: 4),
        Semantics(
          expanded: _breakpointDockOpen,
          child: TalButton.icon(
            key: const ValueKey('breakpoint-manager'),
            icon:
                (settings.paused
                        ? BreakpointStatus.paused
                        : count == 0
                        ? BreakpointStatus.disabled
                        : BreakpointStatus.installed)
                    .marker(),
            label: Text('断点 $count'),
            style: _breakpointButtonStyle(ui, selected: _breakpointDockOpen),
            onPressed: () => _updateSourceView(
              () => _breakpointDockOpen = !_breakpointDockOpen,
            ),
          ),
        ),
      ],
    );
    final scope = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (currentFile, label) in const [
          (false, '全部文件'),
          (true, '当前文件'),
        ])
          Semantics(
            selected: currentFile == _breakpointsCurrentFile,
            child: TalButton(
              key: ValueKey('breakpoint-scope-${currentFile ? 'file' : 'all'}'),
              variant: currentFile == _breakpointsCurrentFile
                  ? TalButtonVariant.outlined
                  : TalButtonVariant.text,
              style: _breakpointButtonStyle(ui),
              onPressed: () => _updateSourceView(
                () => _breakpointsCurrentFile = currentFile,
              ),
              child: Text(
                label,
                style: talMuted.copyWith(
                  color: currentFile == _breakpointsCurrentFile
                      ? TalColors.text
                      : TalColors.muted,
                ),
              ),
            ),
          ),
      ],
    );
    return SizedBox(
      key: const ValueKey('source-breakpoint-toolbar'),
      width: _breakpointDockOpen ? width : null,
      child: WorkbenchToolbarOutline(
        attachment: _breakpointDockOpen && sideBySide
            ? WorkbenchToolbarAttachment.stretch
            : WorkbenchToolbarAttachment.end,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _breakpointDockOpen
              ? Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [scope, actions],
                )
              : actions,
        ),
      ),
    );
  }

  ButtonStyle _breakpointButtonStyle(TalUiTheme ui, {bool selected = false}) =>
      OutlinedButton.styleFrom(
        minimumSize: Size(0, ui.targetExtent(28)),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        backgroundColor: selected ? TalColors.selection : null,
        side: selected ? const BorderSide(color: TalColors.accent) : null,
      );

  bool _usesSideBreakpointDock(double width) =>
      width >= _breakpointDockWidth + 300;

  Widget _buildSourceContent(double width, {required Widget? searchField}) {
    final editor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?searchField,
        if (_searchVisible && _searchResults.isNotEmpty) _buildSearchResults(),
        Expanded(child: _buildBody()),
      ],
    );
    if (!_breakpointDockOpen || widget.readOnlyPreview) return editor;

    final dock = _buildBreakpointDock();
    if (!_usesSideBreakpointDock(width)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: editor),
          const Divider(height: 1, color: TalColors.border),
          Expanded(child: dock),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: editor),
        SizedBox(
          width: _breakpointDockWidth,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: TalColors.border)),
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 1),
              child: dock,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBreakpointDock() {
    final settings = controller.debugState.breakpointSettings;
    final visiblePaths =
        settings.requested.keys
            .where(
              (path) =>
                  !_breakpointsCurrentFile ||
                  (_selectedPath != null &&
                      controller.sourcePathsMatch(path, _selectedPath!)),
            )
            .toList()
          ..sort();
    final resolved = <({String path, int line}), DebugBreakpoint>{
      for (final item in controller.debugState.resolvedBreakpoints)
        (path: item.path, line: item.requestedLine): item,
    };
    final entries = <Widget>[];
    Widget? detail;
    final ui = TalUiTheme.of(context);
    for (final path in visiblePaths) {
      final lines = settings.requested[path]!.toList()..sort();
      final name = path.replaceAll('\\', '/').split('/');
      final collapsed = _collapsedBreakpointFiles.contains(path);
      if (entries.isNotEmpty) {
        entries.add(const Divider(height: 1, color: TalColors.borderSoft));
      }
      entries.add(
        Tooltip(
          message: path,
          child: InkWell(
            onTap: () => _updateSourceView(() {
              if (!_collapsedBreakpointFiles.add(path)) {
                _collapsedBreakpointFiles.remove(path);
              }
            }),
            child: SizedBox(
              height: ui.targetExtent(34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(
                      collapsed ? Icons.arrow_right : Icons.arrow_drop_down,
                      size: 16,
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        name.last,
                        style: talMono,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (name.length > 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 86),
                          child: Text(
                            name[name.length - 2],
                            style: talMuted,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    Text('${lines.length}', style: talMuted),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      if (collapsed) continue;
      for (final line in lines) {
        final key = (path: path, line: line);
        final breakpoint =
            resolved[key] ??
            controller.debugState.resolvedBreakpoints
                .where(
                  (item) =>
                      item.requestedLine == line &&
                      controller.sourcePathsMatch(item.path, path),
                )
                .firstOrNull;
        final actual = breakpoint?.actualLine ?? line;
        final enabled = settings.disabled[path]?.contains(line) != true;
        final selected = _selectedBreakpoint == key;
        final status = _breakpointStatus(breakpoint, enabled: enabled);
        entries.add(
          _buildBreakpointRow(
            key,
            name.last,
            actual,
            status,
            selected: selected,
            enabled: enabled,
          ),
        );
        if (selected) {
          detail = _buildBreakpointDetail(key, name.last, breakpoint, status);
        }
      }
    }
    if (entries.isEmpty) {
      entries.add(
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _breakpointsCurrentFile
                ? '当前文件没有断点。点击可执行行旁的行号添加。'
                : '尚无断点。点击可执行行旁的行号添加。',
            style: talMuted,
          ),
        ),
      );
    }
    final selectedDetail = detail;
    return Material(
      key: const ValueKey('source-breakpoint-dock'),
      color: TalColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final list = ListView(
            padding: EdgeInsets.zero,
            children: [
              ...entries,
              if (constraints.maxHeight < 220 && selectedDetail != null)
                selectedDetail,
            ],
          );
          if (constraints.maxHeight < 220 || selectedDetail == null) {
            return list;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              selectedDetail,
            ],
          );
        },
      ),
    );
  }

  Widget _buildBreakpointRow(
    ({String path, int line}) key,
    String name,
    int actual,
    BreakpointStatus status, {
    required bool selected,
    required bool enabled,
  }) {
    final ui = TalUiTheme.of(context);
    final targetHeight = ui.targetExtent(36);
    final position = actual == key.line
        ? '${key.line}'
        : '${key.line} → $actual';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? TalColors.selection : null,
        border: Border(
          left: BorderSide(
            width: 2,
            color: selected ? TalColors.accent : Colors.transparent,
          ),
        ),
      ),
      child: SizedBox(
        height: targetHeight,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                selected: selected,
                button: true,
                label: '定位 $name 第 ${key.line} 行',
                child: InkWell(
                  key: ValueKey(('locate-breakpoint', key)),
                  onTap: () => unawaited(_revealBreakpoint(key, actual)),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Row(
                      children: [
                        status.marker(),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            position,
                            style: talMono,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _breakpointStatusLabel(status),
                          style: talMuted.copyWith(color: status.color),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: ui.targetExtent(46),
              child: Semantics(
                label: '启用 $name:${key.line}',
                child: Center(
                  child: Transform.scale(
                    scale: ui.touchOptimized ? .82 : .64,
                    transformHitTests: false,
                    child: Switch(
                      key: ValueKey(('enable-breakpoint', key)),
                      value: enabled,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      activeThumbColor: TalColors.heading,
                      inactiveThumbColor: TalColors.muted,
                      activeTrackColor: TalColors.error.withValues(alpha: .50),
                      onChanged: controller.breakpointEditDisabledReason == null
                          ? (value) => unawaited(
                              controller.editBreakpoints(
                                BreakpointAction.setEnabled,
                                path: key.path,
                                line: key.line,
                                value: value,
                              ),
                            )
                          : null,
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

  Widget _buildBreakpointDetail(
    ({String path, int line}) key,
    String name,
    DebugBreakpoint? breakpoint,
    BreakpointStatus status,
  ) {
    final actual = breakpoint?.actualLine ?? key.line;
    final address = breakpoint?.address;
    final description =
        breakpoint?.message ??
        switch (status) {
          BreakpointStatus.disabled => '重新启用后将尝试装载此断点。',
          BreakpointStatus.paused => '恢复所有断点后将尝试装载此断点。',
          BreakpointStatus.installed =>
            actual == key.line ? '已装载到目标' : '实际落在第 $actual 行',
          _ => status.label,
        };
    final ui = TalUiTheme.of(context);
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: TalColors.background,
        border: Border.all(color: TalColors.borderSoft),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$name:${key.line}',
            style: talMono,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            address == null
                ? description
                : '$description  0x${address.toRadixString(16).padLeft(8, '0').toUpperCase()}',
            style: talMuted,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (actual != key.line)
                TalButton(
                  key: const ValueKey('locate-requested-breakpoint-line'),
                  style: _breakpointButtonStyle(ui),
                  onPressed: () => unawaited(_revealBreakpoint(key, key.line)),
                  child: const Text('定位请求行'),
                )
              else
                const SizedBox.shrink(),
              TalButton(
                style: _breakpointButtonStyle(ui),
                onPressed: controller.breakpointEditDisabledReason == null
                    ? () => unawaited(
                        _removeBreakpoints(path: key.path, line: key.line),
                      )
                    : null,
                child: const Text('删除断点'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  BreakpointStatus _breakpointStatus(
    DebugBreakpoint? breakpoint, {
    required bool enabled,
  }) {
    if (!enabled) return BreakpointStatus.disabled;
    if (controller.debugState.breakpointSettings.paused) {
      return BreakpointStatus.paused;
    }
    return breakpoint?.status ??
        (breakpoint?.verified == true
            ? BreakpointStatus.installed
            : BreakpointStatus.pending);
  }

  String _breakpointStatusLabel(BreakpointStatus status) {
    if (status != BreakpointStatus.pending) return status.label;
    if (controller.firmwareRequiresDownload) return '待重新下载';
    if (controller.connectionStatus == ConnectionStatus.disconnected) {
      return '等待连接';
    }
    if (!controller.supportsTargetControl) return '当前连接不支持';
    return status.label;
  }

  Future<void> _revealBreakpoint(
    ({String path, int line}) key,
    int line,
  ) async {
    _updateSourceView(() {
      _selectedBreakpoint = key;
      _breakpointLocation = (path: key.path, line: line);
    });
    await _navigateToCodeLocation(
      SourceCodeLocation(path: key.path, line: line),
    );
  }

  Future<bool> _removeBreakpoints({String? path, int? line}) =>
      controller.editBreakpoints(
        path == null ? BreakpointAction.clear : BreakpointAction.remove,
        path: path,
        line: line,
      );
}

extension _BreakpointPresentation on BreakpointStatus {
  String get label => switch (this) {
    BreakpointStatus.installed => '已装载',
    BreakpointStatus.pending => '待应用',
    BreakpointStatus.failed => '设置失败',
    BreakpointStatus.disabled => '已停用',
    BreakpointStatus.paused => '已暂停',
  };

  Color get color => switch (this) {
    BreakpointStatus.failed => TalColors.error,
    BreakpointStatus.pending || BreakpointStatus.paused => TalColors.amber,
    _ => TalColors.muted,
  };

  Widget marker() => Icon(
    switch (this) {
      BreakpointStatus.installed => Icons.circle,
      BreakpointStatus.failed => Icons.close,
      BreakpointStatus.pending => Icons.circle,
      _ => Icons.circle_outlined,
    },
    size: 11,
    color: this == BreakpointStatus.installed ? TalColors.error : color,
  );
}
