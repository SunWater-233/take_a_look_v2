import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'source_documents.dart';
import 'source_highlighter.dart';
import 'source_references.dart';

enum SourcePeekKind { definitions, references }

/// An inline, read-only preview. Selecting a result never changes source tabs.
class SourcePeekPanel extends StatefulWidget {
  const SourcePeekPanel({
    super.key,
    required this.kind,
    required this.token,
    required this.locations,
    required this.documents,
    required this.highlighter,
    required this.sourceRoot,
    required this.onClose,
    required this.onOpen,
    required this.onResize,
    this.searching = false,
    this.truncated = false,
    this.unreadableFiles = 0,
    this.interactive = true,
  });
  final SourcePeekKind kind;
  final String token;
  final List<SourceCodeLocation> locations;
  final SourceDocuments documents;
  final SourceHighlighter highlighter;
  final String sourceRoot;
  final VoidCallback onClose;
  final ValueChanged<SourceCodeLocation> onOpen;
  final ValueChanged<double> onResize;
  final bool searching;
  final bool truncated;
  final int unreadableFiles;
  final bool interactive;

  @override
  State<SourcePeekPanel> createState() => _SourcePeekPanelState();
}

class _SourcePeekPanelState extends State<SourcePeekPanel>
    with AutomaticKeepAliveClientMixin {
  static const _lineHeight = 20.0;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _results = ScrollController();
  final _focus = FocusNode();
  final _collapsedPaths = <String>{};
  int _selected = 0;
  int _generation = 0;
  PreparedSourceText? _source;
  Object? _error;

  @override
  bool get wantKeepAlive => true;
  SourceCodeLocation? get _location =>
      _selected < widget.locations.length ? widget.locations[_selected] : null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  @override
  void didUpdateWidget(covariant SourcePeekPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLocation = _selected < oldWidget.locations.length
        ? oldWidget.locations[_selected]
        : null;
    if (_selected >= widget.locations.length) _selected = 0;
    if (oldLocation?.key != _location?.key ||
        oldWidget.sourceRoot != widget.sourceRoot) {
      unawaited(_loadPreview());
    }
  }

  @override
  void dispose() {
    _generation++;
    _vertical.dispose();
    _horizontal.dispose();
    _results.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    final generation = ++_generation;
    final location = _location;
    setState(() {
      _source = null;
      _error = null;
    });
    if (location == null) return;
    try {
      final document = await widget.documents.read(
        location.path,
        sourceRoot: widget.sourceRoot,
      );
      final source = await widget.highlighter.prepare(
        document,
        path: location.path,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _source = source);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation || !_vertical.hasClients) {
          return;
        }
        _vertical.jumpTo(
          ((location.line - 1) * _lineHeight -
                  _vertical.position.viewportDimension * .38)
              .clamp(0.0, _vertical.position.maxScrollExtent),
        );
        if (_horizontal.hasClients) _horizontal.jumpTo(0);
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  void _select(int index) {
    if (index < 0 || index >= widget.locations.length) return;
    _focus.requestFocus();
    if (index == _selected && _source != null) return;
    setState(() {
      _selected = index;
      _collapsedPaths.remove(widget.locations[index].path);
    });
    unawaited(_loadPreview());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_results.hasClients) return;
      final row = _resultRows().indexWhere((item) => item.index == index);
      _results.jumpTo(
        (row * 28.0 - _results.position.viewportDimension * .4).clamp(
          0.0,
          _results.position.maxScrollExtent,
        ),
      );
    });
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _select(
        _selected + (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1),
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && _location != null) {
      widget.onOpen(_location!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<({String path, int? index, int count})> _resultRows() {
    final groups = <String, List<int>>{};
    for (var index = 0; index < widget.locations.length; index++) {
      groups.putIfAbsent(widget.locations[index].path, () => []).add(index);
    }
    return [
      for (final group in groups.entries) ...[
        (path: group.key, index: null, count: group.value.length),
        if (!_collapsedPaths.contains(group.key))
          for (final index in group.value)
            (path: group.key, index: index, count: 0),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Focus(
      focusNode: _focus,
      canRequestFocus: widget.interactive,
      onKeyEvent: widget.interactive ? _handleKey : null,
      child: Listener(
        onPointerDown: (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.interactive) _focus.requestFocus();
        }),
        child: Container(
          key: const ValueKey('source-peek-panel'),
          decoration: const BoxDecoration(
            color: TalColors.surface,
            border: Border(
              top: BorderSide(color: TalColors.info),
              bottom: BorderSide(color: TalColors.info),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 560;
              final label = widget.kind == SourcePeekKind.references
                  ? '引用'
                  : '定义';
              final count = widget.locations.length;
              final more = widget.truncated ? '+' : '';
              return Column(
                children: [
                  SizedBox(
                    height: TalUiTheme.of(context).targetExtent(32),
                    child: ColoredBox(
                      color: TalColors.surfaceAlt,
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          Icon(
                            widget.kind == SourcePeekKind.references
                                ? Icons.find_in_page_outlined
                                : Icons.code,
                            size: 16,
                            color: TalColors.info,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '${widget.token} 的$label ($count$more)',
                              style: talStrong.copyWith(fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (wide) ...[
                            TalIconButton(
                              tooltip: '上一处 (↑)',
                              onPressed: _selected > 0
                                  ? () => _select(_selected - 1)
                                  : null,
                              icon: const Icon(
                                Icons.keyboard_arrow_up,
                                size: 18,
                              ),
                            ),
                            TalIconButton(
                              tooltip: '下一处 (↓)',
                              onPressed: _selected + 1 < count
                                  ? () => _select(_selected + 1)
                                  : null,
                              icon: const Icon(
                                Icons.keyboard_arrow_down,
                                size: 18,
                              ),
                            ),
                          ],
                          TalIconButton(
                            key: const ValueKey('source-peek-open'),
                            tooltip: '打开所选位置 (Enter)',
                            onPressed: _location == null
                                ? null
                                : () => widget.onOpen(_location!),
                            icon: const Icon(Icons.open_in_new, size: 15),
                          ),
                          TalIconButton(
                            key: const ValueKey('source-peek-close'),
                            tooltip: '关闭预览 (Esc)',
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 2,
                    child: widget.searching
                        ? const LinearProgressIndicator(minHeight: 2)
                        : const ColoredBox(
                            color: TalColors.borderSoft,
                            child: SizedBox.expand(),
                          ),
                  ),
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              Expanded(flex: 7, child: _buildPreview()),
                              const VerticalDivider(
                                width: 1,
                                color: TalColors.border,
                              ),
                              Expanded(flex: 3, child: _buildLocations()),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(flex: 3, child: _buildPreview()),
                              const Divider(height: 1, color: TalColors.border),
                              Expanded(flex: 2, child: _buildLocations()),
                            ],
                          ),
                  ),
                  if (widget.kind == SourcePeekKind.references)
                    SizedBox(
                      height: 18,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '按名称匹配，包含声明与定义${widget.unreadableFiles > 0 ? '；有 ${widget.unreadableFiles} 个文件无法读取' : ''}',
                            style: talMuted.copyWith(fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeRow,
                    child: GestureDetector(
                      key: const ValueKey('source-peek-resize'),
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (event) =>
                          widget.onResize(event.delta.dy),
                      child: const SizedBox(height: 5, width: double.infinity),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLocations() {
    if (widget.locations.isEmpty) {
      return Center(
        child: Text(widget.searching ? '正在查找引用…' : '没有找到匹配位置', style: talMuted),
      );
    }
    final rows = _resultRows();
    return Scrollbar(
      controller: _results,
      child: ListView.builder(
        key: const ValueKey('source-peek-locations'),
        controller: _results,
        itemExtent: 28,
        itemCount: rows.length,
        itemBuilder: (context, rowIndex) {
          final row = rows[rowIndex];
          final index = row.index;
          if (index == null) {
            return Tooltip(
              message: row.path,
              child: InkWell(
                key: ValueKey('source-peek-file-${row.path}'),
                onTap: () => setState(() {
                  if (!_collapsedPaths.add(row.path)) {
                    _collapsedPaths.remove(row.path);
                  }
                }),
                child: Row(
                  children: [
                    Icon(
                      _collapsedPaths.contains(row.path)
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 16,
                      color: TalColors.muted,
                    ),
                    Expanded(
                      child: Text(
                        _basename(row.path),
                        style: talStrong.copyWith(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      row.count.toString(),
                      style: talMuted.copyWith(fontSize: 10),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            );
          }
          final location = widget.locations[index];
          return GestureDetector(
            key: ValueKey('source-peek-location-$index'),
            onTap: () => _select(index),
            onDoubleTap: () => widget.onOpen(location),
            child: ColoredBox(
              color: index == _selected
                  ? TalColors.selection
                  : Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      '${location.line}  ',
                      style: talMuted.copyWith(fontSize: 10),
                    ),
                    Expanded(
                      child: Text(
                        location.label.isNotEmpty
                            ? location.label
                            : location.preview.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: talBody.copyWith(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreview() {
    final location = _location;
    if (location == null) return const SizedBox.shrink();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text('无法读取源码文件\n$_error', style: talMuted, maxLines: 3),
        ),
      );
    }
    final source = _source;
    if (source == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Column(
      children: [
        SizedBox(
          height: 23,
          child: Tooltip(
            message: location.path,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${location.path}:${location.line}',
                  style: talMuted.copyWith(fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: _horizontal,
              notificationPredicate: (event) =>
                  event.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(
                    constraints.maxWidth,
                    62 + source.maximumLineLength * 8.0,
                  ),
                  child: Scrollbar(
                    controller: _vertical,
                    child: ListView.builder(
                      key: const ValueKey('source-peek-code'),
                      controller: _vertical,
                      itemExtent: _lineHeight,
                      itemCount: source.lines.length,
                      itemBuilder: (context, index) {
                        final line = source.lines[index];
                        final selected = index + 1 == location.line;
                        final match = line.identifiers
                            .where(
                              (range) =>
                                  line.rawText.substring(
                                        range.start,
                                        range.end,
                                      ) ==
                                      widget.token &&
                                  (location.length == 0 ||
                                      range.start == location.column - 1),
                            )
                            .firstOrNull;
                        return GestureDetector(
                          key: ValueKey('source-peek-code-line-${index + 1}'),
                          onDoubleTap: () => widget.onOpen(
                            SourceCodeLocation(
                              path: location.path,
                              line: index + 1,
                            ),
                          ),
                          child: ColoredBox(
                            color: selected
                                ? TalColors.info.withValues(alpha: .12)
                                : Colors.transparent,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 46,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: Text(
                                      (index + 1).toString(),
                                      textAlign: TextAlign.right,
                                      style: talMuted.copyWith(fontSize: 11),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      children:
                                          decorateSourceSpans(line.spans, [
                                            if (selected && match != null)
                                              (
                                                start: match.start,
                                                end: match.end,
                                                style: TextStyle(
                                                  backgroundColor: TalColors
                                                      .info
                                                      .withValues(alpha: .3),
                                                ),
                                              ),
                                          ]),
                                    ),
                                    style: talBody.copyWith(
                                      fontSize: 12,
                                      height: 1.4,
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.visible,
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
            ),
          ),
        ),
      ],
    );
  }
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;
