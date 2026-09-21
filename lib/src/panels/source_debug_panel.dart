part of '../panels.dart';

class _SourceDebugPanel extends StatefulWidget {
  const _SourceDebugPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_SourceDebugPanel> createState() => _SourceDebugPanelState();
}

class _SourceDebugPanelState extends State<_SourceDebugPanel> {
  static const _lineHeight = 22.0;
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  String? _selectedPath;
  List<_HighlightedSourceLine> _lines = const [];
  String? _loadError;
  int _loadGeneration = 0;
  final Map<String, String> _sourceOverrides = <String, String>{};

  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.debugChanges.addListener(_handleDebugChange);
    controller.symbolChanges.addListener(_handleDebugChange);
    _handleDebugChange();
  }

  @override
  void didUpdateWidget(covariant _SourceDebugPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == controller) return;
    oldWidget.controller.debugChanges.removeListener(_handleDebugChange);
    oldWidget.controller.symbolChanges.removeListener(_handleDebugChange);
    controller.debugChanges.addListener(_handleDebugChange);
    controller.symbolChanges.addListener(_handleDebugChange);
    _selectedPath = null;
    _handleDebugChange();
  }

  @override
  void dispose() {
    controller.debugChanges.removeListener(_handleDebugChange);
    controller.symbolChanges.removeListener(_handleDebugChange);
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  List<String> get _sourceFiles {
    final files = <String>{...controller.debugState.sourceFiles};
    for (final symbol in controller.symbols) {
      if (symbol.source.isNotEmpty && symbol.source != '未知来源') {
        files.add(symbol.source);
      }
    }
    return files.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  void _handleDebugChange() {
    if (!mounted) return;
    final currentSource = controller.debugState.currentSource;
    final files = _sourceFiles;
    String? nextPath = _selectedPath;
    if (currentSource != null && currentSource.isNotEmpty) {
      nextPath = _matchingPath(currentSource, files) ?? currentSource;
    } else if (nextPath == null || !files.contains(nextPath)) {
      nextPath = files.firstOrNull;
    }
    if (nextPath != _selectedPath) {
      unawaited(_loadSource(nextPath));
    } else {
      setState(() {});
      _scrollToCurrentLine();
    }
  }

  Future<void> _loadSource(String? path) async {
    final generation = ++_loadGeneration;
    setState(() {
      _selectedPath = path;
      _lines = const [];
      _loadError = null;
    });
    if (path == null) return;
    try {
      final sourcePath = _sourceOverrides[_pathKey(path)] ?? path;
      final source = await File(sourcePath).readAsString();
      final highlighted = _CppSyntaxHighlighter().highlight(source);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _lines = highlighted);
      _scrollToCurrentLine(immediate: true);
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadError = error.toString());
    }
  }

  Future<void> _locateSourceFile() async {
    final selectedPath = _selectedPath;
    if (selectedPath == null) return;
    final localPath = await pickSourceFile();
    if (localPath == null || localPath.isEmpty) return;
    _sourceOverrides[_pathKey(selectedPath)] = localPath;
    await _loadSource(selectedPath);
  }

  void _scrollToCurrentLine({bool immediate = false}) {
    final currentPath = controller.debugState.currentSource;
    final currentLine = controller.debugState.currentLine;
    if (currentPath == null ||
        currentLine == null ||
        _selectedPath == null ||
        _pathKey(currentPath) != _pathKey(_selectedPath!)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalController.hasClients) return;
      final viewport = _verticalController.position.viewportDimension;
      final target = ((currentLine - 1) * _lineHeight - viewport * 0.38).clamp(
        0.0,
        _verticalController.position.maxScrollExtent,
      );
      if (immediate) {
        _verticalController.jumpTo(target);
      } else {
        unawaited(
          _verticalController.animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(),
        const Divider(height: 1, color: TalColors.borderSoft),
        Expanded(child: _buildBody()),
        _buildRegisterStrip(),
      ],
    );
  }

  Widget _buildToolbar() {
    final state = controller.debugState.executionState;
    final connected = controller.connectionStatus == ConnectionStatus.connected;
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 8),
          _DebugToolbarButton(
            key: const ValueKey('debug-halt'),
            tooltip: '暂停目标',
            icon: Icons.pause,
            onPressed: connected && state == DebugExecutionState.running
                ? controller.haltTarget
                : null,
          ),
          _DebugToolbarButton(
            key: const ValueKey('debug-resume'),
            tooltip: '继续运行',
            icon: Icons.play_arrow,
            onPressed: connected && state == DebugExecutionState.halted
                ? controller.resumeTarget
                : null,
          ),
          _DebugToolbarButton(
            key: const ValueKey('debug-step'),
            tooltip: '单条指令步进',
            icon: Icons.skip_next,
            onPressed: connected && state == DebugExecutionState.halted
                ? controller.stepTarget
                : null,
          ),
          const SizedBox(width: 8),
          _DebugStateBadge(state: state),
          const SizedBox(width: 12),
          Expanded(child: _buildFileSelector()),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildFileSelector() {
    final files = _sourceFiles;
    return PopupMenuButton<String>(
      tooltip: '选择源码文件',
      enabled: files.isNotEmpty,
      onSelected: (path) => unawaited(_loadSource(path)),
      itemBuilder: (context) => [
        for (final path in files)
          PopupMenuItem<String>(
            value: path,
            child: Tooltip(
              message: path,
              child: Text(
                _basename(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: TalColors.input,
          border: Border.all(color: TalColors.border),
          borderRadius: talControlRadius,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.description_outlined,
              size: 15,
              color: TalColors.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _selectedPath ?? (files.isEmpty ? 'ELF 中没有源码调试信息' : '选择源码文件'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: talMuted.copyWith(fontSize: 12),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18, color: TalColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_selectedPath == null) {
      return const _SourceDebugEmptyState(
        icon: Icons.code_off,
        title: '没有可显示的源码',
        detail: '请加载带 DWARF 调试信息的 ELF / AXF 文件。',
      );
    }
    if (_loadError != null) {
      return _SourceDebugEmptyState(
        icon: Icons.link_off,
        title: '找不到本地源码文件',
        detail: '$_selectedPath\n$_loadError',
        actionLabel: '定位本地源码',
        onAction: _locateSourceFile,
      );
    }
    if (_lines.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final longest = _lines.fold<int>(
          0,
          (value, line) => math.max(value, line.textLength),
        );
        final contentWidth = math.max(constraints.maxWidth, 82 + longest * 8.2);
        return Scrollbar(
          controller: _horizontalController,
          thumbVisibility: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentWidth,
              child: Scrollbar(
                controller: _verticalController,
                thumbVisibility: true,
                child: ListView.builder(
                  key: ValueKey('source-view-$_selectedPath'),
                  controller: _verticalController,
                  itemExtent: _lineHeight,
                  itemCount: _lines.length,
                  itemBuilder: (context, index) => _buildSourceLine(index),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSourceLine(int index) {
    final lineNumber = index + 1;
    final path = _selectedPath!;
    final requested =
        controller.debugState.requestedBreakpoints[path] ??
        controller.debugState.requestedBreakpoints.entries
            .where((entry) => _pathKey(entry.key) == _pathKey(path))
            .map((entry) => entry.value)
            .firstOrNull ??
        const <int>{};
    final breakpoint = controller.debugState.resolvedBreakpoints
        .where(
          (item) =>
              _pathKey(item.path) == _pathKey(path) &&
              item.requestedLine == lineNumber,
        )
        .firstOrNull;
    final hasBreakpoint = requested.contains(lineNumber);
    final isCurrent =
        controller.debugState.currentLine == lineNumber &&
        controller.debugState.currentSource != null &&
        _pathKey(controller.debugState.currentSource!) == _pathKey(path);
    return ColoredBox(
      color: isCurrent ? const Color(0x333B82F6) : Colors.transparent,
      child: Row(
        children: [
          InkWell(
            key: ValueKey('breakpoint-$lineNumber'),
            onTap: () => controller.toggleBreakpoint(path, lineNumber),
            child: SizedBox(
              width: 30,
              height: _lineHeight,
              child: Center(
                child: isCurrent
                    ? const Icon(
                        Icons.arrow_right,
                        size: 18,
                        color: Color(0xFF65A7FF),
                      )
                    : hasBreakpoint
                    ? Tooltip(
                        message:
                            breakpoint?.message ??
                            (breakpoint?.verified == true ? '断点已设置' : '等待设置断点'),
                        child: Icon(
                          Icons.circle,
                          size: 11,
                          color: breakpoint?.verified == true
                              ? const Color(0xFFE25858)
                              : TalColors.amber,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF777277),
                fontSize: 12,
                height: 1.45,
                fontFamily: talFontFamily,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text.rich(
              TextSpan(children: _lines[index].spans),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: const TextStyle(
                color: TalColors.text,
                fontSize: 13,
                height: 1.45,
                fontFamily: talFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterStrip() {
    final registers = controller.debugState.registers;
    if (registers.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        color: TalColors.input,
        border: Border(top: BorderSide(color: TalColors.borderSoft)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          for (final entry in registers.entries)
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Center(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${entry.key.toUpperCase()}  ',
                        style: talMuted.copyWith(fontSize: 11),
                      ),
                      TextSpan(
                        text:
                            '0x${entry.value.toRadixString(16).padLeft(8, '0').toUpperCase()}',
                        style: talStrong.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DebugToolbarButton extends StatelessWidget {
  const _DebugToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _DebugStateBadge extends StatelessWidget {
  const _DebugStateBadge({required this.state});

  final DebugExecutionState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      DebugExecutionState.running => ('运行中', TalColors.success),
      DebugExecutionState.halted => ('已暂停', TalColors.amber),
      DebugExecutionState.unavailable => ('未连接', TalColors.muted),
      DebugExecutionState.unknown => ('状态未知', TalColors.muted),
    };
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 11)),
        ],
      ),
    );
  }
}

class _SourceDebugEmptyState extends StatelessWidget {
  const _SourceDebugEmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: TalColors.muted, size: 34),
            const SizedBox(height: 12),
            Text(title, style: talStrong),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: talMuted.copyWith(fontSize: 12),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.folder_open, size: 16),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _SourceTokenKind {
  plain,
  keyword,
  type,
  number,
  string,
  comment,
  preprocessor,
}

class _HighlightedSourceLine {
  const _HighlightedSourceLine(this.spans, this.textLength);

  final List<TextSpan> spans;
  final int textLength;
}

class _CppSyntaxHighlighter {
  static const _keywords = <String>{
    'alignas',
    'alignof',
    'asm',
    'auto',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'constexpr',
    'continue',
    'default',
    'delete',
    'do',
    'else',
    'enum',
    'explicit',
    'export',
    'extern',
    'for',
    'friend',
    'goto',
    'if',
    'inline',
    'namespace',
    'new',
    'noexcept',
    'operator',
    'private',
    'protected',
    'public',
    'register',
    'return',
    'sizeof',
    'static',
    'struct',
    'switch',
    'template',
    'this',
    'throw',
    'try',
    'typedef',
    'typename',
    'union',
    'using',
    'virtual',
    'volatile',
    'while',
  };
  static const _types = <String>{
    'bool',
    'char',
    'double',
    'float',
    'int',
    'long',
    'short',
    'signed',
    'unsigned',
    'void',
    'wchar_t',
    'size_t',
    'int8_t',
    'int16_t',
    'int32_t',
    'int64_t',
    'uint8_t',
    'uint16_t',
    'uint32_t',
    'uint64_t',
    'true',
    'false',
    'nullptr',
    'NULL',
  };

  List<_HighlightedSourceLine> highlight(String source) {
    final rawLines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    var inBlockComment = false;
    return [
      for (final line in rawLines)
        _highlightLine(
          line,
          () => inBlockComment,
          (value) => inBlockComment = value,
        ),
    ];
  }

  _HighlightedSourceLine _highlightLine(
    String line,
    bool Function() isInBlockComment,
    void Function(bool) setBlockComment,
  ) {
    final spans = <TextSpan>[];
    var index = 0;
    final firstNonSpace = line.length - line.trimLeft().length;
    if (!isInBlockComment() &&
        firstNonSpace < line.length &&
        line[firstNonSpace] == '#') {
      spans.add(
        TextSpan(text: line, style: _style(_SourceTokenKind.preprocessor)),
      );
      return _HighlightedSourceLine(spans, line.length);
    }
    while (index < line.length) {
      if (isInBlockComment()) {
        final end = line.indexOf('*/', index);
        if (end < 0) {
          _add(spans, line.substring(index), _SourceTokenKind.comment);
          index = line.length;
        } else {
          _add(spans, line.substring(index, end + 2), _SourceTokenKind.comment);
          index = end + 2;
          setBlockComment(false);
        }
        continue;
      }
      if (line.startsWith('//', index)) {
        _add(spans, line.substring(index), _SourceTokenKind.comment);
        break;
      }
      if (line.startsWith('/*', index)) {
        final end = line.indexOf('*/', index + 2);
        if (end < 0) {
          _add(spans, line.substring(index), _SourceTokenKind.comment);
          setBlockComment(true);
          break;
        }
        _add(spans, line.substring(index, end + 2), _SourceTokenKind.comment);
        index = end + 2;
        continue;
      }
      final char = line[index];
      if (char == '"' || char == "'") {
        final quote = char;
        var end = index + 1;
        while (end < line.length) {
          if (line[end] == '\\') {
            end += 2;
            continue;
          }
          if (line[end++] == quote) break;
        }
        end = math.min(end, line.length);
        _add(spans, line.substring(index, end), _SourceTokenKind.string);
        index = end;
        continue;
      }
      if (_isIdentifierStart(char)) {
        var end = index + 1;
        while (end < line.length && _isIdentifierPart(line[end])) {
          end += 1;
        }
        final word = line.substring(index, end);
        final kind = _keywords.contains(word)
            ? _SourceTokenKind.keyword
            : _types.contains(word)
            ? _SourceTokenKind.type
            : _SourceTokenKind.plain;
        _add(spans, word, kind);
        index = end;
        continue;
      }
      if (_isDigit(char)) {
        var end = index + 1;
        while (end < line.length &&
            RegExp(r'[A-Za-z0-9_.]').hasMatch(line[end])) {
          end += 1;
        }
        _add(spans, line.substring(index, end), _SourceTokenKind.number);
        index = end;
        continue;
      }
      _add(spans, char, _SourceTokenKind.plain);
      index += 1;
    }
    if (line.isEmpty) spans.add(const TextSpan(text: ''));
    return _HighlightedSourceLine(spans, line.length);
  }

  static void _add(List<TextSpan> spans, String text, _SourceTokenKind kind) {
    spans.add(TextSpan(text: text, style: _style(kind)));
  }

  static TextStyle _style(_SourceTokenKind kind) => TextStyle(
    color: switch (kind) {
      _SourceTokenKind.plain => TalColors.text,
      _SourceTokenKind.keyword => const Color(0xFFC586C0),
      _SourceTokenKind.type => const Color(0xFF4EC9B0),
      _SourceTokenKind.number => const Color(0xFFB5CEA8),
      _SourceTokenKind.string => const Color(0xFFCE9178),
      _SourceTokenKind.comment => const Color(0xFF6A9955),
      _SourceTokenKind.preprocessor => const Color(0xFFC8C8C8),
    },
  );

  static bool _isIdentifierStart(String value) =>
      RegExp(r'[A-Za-z_]').hasMatch(value);
  static bool _isIdentifierPart(String value) =>
      RegExp(r'[A-Za-z0-9_]').hasMatch(value);
  static bool _isDigit(String value) => RegExp(r'[0-9]').hasMatch(value);
}

String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String? _matchingPath(String candidate, List<String> paths) {
  final key = _pathKey(candidate);
  for (final path in paths) {
    if (_pathKey(path) == key) return path;
  }
  final basename = _basename(candidate).toLowerCase();
  final matches = paths
      .where((path) => _basename(path).toLowerCase() == basename)
      .toList();
  return matches.length == 1 ? matches.single : null;
}
