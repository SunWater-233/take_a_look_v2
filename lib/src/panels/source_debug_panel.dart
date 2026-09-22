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
  final ScrollController _tabController = ScrollController();
  final List<String> _openPaths = <String>[];
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};
  final Set<String> _externalPathKeys = <String>{};
  final Map<String, String> _sourceTextCache = <String, String>{};
  final FocusNode _panelFocusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  String? _selectedPath;
  List<_HighlightedSourceLine> _lines = const [];
  String? _loadError;
  int _loadGeneration = 0;
  int _searchGeneration = 0;
  bool _canScrollTabsRight = false;
  bool _draggingFiles = false;
  bool _searchVisible = false;
  bool _searching = false;
  int _activeSearchIndex = -1;
  int? _revealedSearchLine;
  Timer? _searchDebounce;
  List<_SourceSearchResult> _searchResults = const [];
  final Map<String, String> _sourceOverrides = <String, String>{};
  final Map<String, String> _resolvedSourcePaths = <String, String>{};
  Future<Map<String, List<String>>>? _sourceRootIndexFuture;
  String _observedSourceRoot = '';
  String? _observedCurrentSource;
  int? _observedCurrentLine;

  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_updateTabOverflow);
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
    _openPaths.clear();
    _tabKeys.clear();
    _externalPathKeys.clear();
    _sourceTextCache.clear();
    _sourceRootIndexFuture = null;
    _searchDebounce?.cancel();
    _searchGeneration += 1;
    _searchController.clear();
    _searchResults = const [];
    _searchVisible = false;
    _searching = false;
    _activeSearchIndex = -1;
    _observedCurrentSource = null;
    _observedCurrentLine = null;
    _handleDebugChange();
  }

  @override
  void dispose() {
    controller.debugChanges.removeListener(_handleDebugChange);
    controller.symbolChanges.removeListener(_handleDebugChange);
    _verticalController.dispose();
    _horizontalController.dispose();
    _panelFocusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _tabController
      ..removeListener(_updateTabOverflow)
      ..dispose();
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
    final sourceRootChanged =
        _observedSourceRoot != controller.debugState.sourceRoot;
    if (sourceRootChanged) {
      _observedSourceRoot = controller.debugState.sourceRoot;
      _resolvedSourcePaths.clear();
      _sourceTextCache.clear();
      _sourceRootIndexFuture = null;
    }
    final currentSource = controller.debugState.currentSource;
    final currentLine = controller.debugState.currentLine;
    final locationChanged =
        currentSource != _observedCurrentSource ||
        currentLine != _observedCurrentLine;
    _observedCurrentSource = currentSource;
    _observedCurrentLine = currentLine;
    final files = _sourceFiles;
    String? nextPath = _selectedPath;
    if (locationChanged && currentSource != null && currentSource.isNotEmpty) {
      nextPath = _matchingPath(currentSource, files) ?? currentSource;
    } else if (nextPath == null ||
        (!_externalPathKeys.contains(_pathKey(nextPath)) &&
            _matchingPath(nextPath, files) == null)) {
      nextPath = _openPaths.firstOrNull ?? files.firstOrNull;
    }
    if (nextPath != null &&
        !_openPaths.any(
          (path) => controller.sourcePathsMatch(path, nextPath!),
        )) {
      _openPaths.add(nextPath);
    }
    if (nextPath != _selectedPath || sourceRootChanged) {
      unawaited(_loadSource(nextPath));
    } else {
      setState(() {});
      _scrollToCurrentLine();
    }
  }

  Future<void> _loadSource(String? path, {int? revealLine}) async {
    final generation = ++_loadGeneration;
    setState(() {
      _selectedPath = path;
      _revealedSearchLine = revealLine;
      if (path != null &&
          !_openPaths.any(
            (openPath) => controller.sourcePathsMatch(openPath, path),
          )) {
        _openPaths.add(path);
      }
      _lines = const [];
      _loadError = null;
    });
    _ensureSelectedTabVisible();
    if (path == null) return;
    try {
      final source = await _readSourceText(path);
      final highlighted = _CppSyntaxHighlighter().highlight(source);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _lines = highlighted);
      if (revealLine != null) {
        _scrollToLine(revealLine, immediate: true);
      } else {
        _scrollToCurrentLine(immediate: true);
      }
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadError = error.toString());
    }
  }

  Future<String> _readSourceText(String path) async {
    final key = _pathKey(path);
    final cached = _sourceTextCache[key];
    if (cached != null) return cached;
    final sourcePath = _sourceOverrides[key] ?? await _resolveSourcePath(path);
    final source = await File(sourcePath).readAsString();
    _sourceTextCache[key] = source;
    return source;
  }

  void _openSource(String path) {
    final existing = _openPaths
        .where((openPath) => controller.sourcePathsMatch(openPath, path))
        .firstOrNull;
    unawaited(_loadSource(existing ?? path));
    _restorePanelFocus();
  }

  void _restorePanelFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _searchVisible) return;
      _panelFocusNode.requestFocus();
    });
  }

  void _closeSource(String path) {
    var index = _openPaths.indexOf(path);
    if (index < 0) {
      index = _openPaths.indexWhere(
        (openPath) => controller.sourcePathsMatch(openPath, path),
      );
    }
    if (index < 0) return;
    final openPath = _openPaths[index];
    final wasSelected =
        _selectedPath != null &&
        controller.sourcePathsMatch(_selectedPath!, openPath);
    setState(() {
      _openPaths.removeAt(index);
      _tabKeys.remove(_pathKey(openPath));
      if (_matchingPath(openPath, _sourceFiles) == null) {
        _externalPathKeys.remove(_pathKey(openPath));
      }
    });
    if (_searchVisible && _searchController.text.isNotEmpty) {
      _queueSearch(_searchController.text, immediate: true);
    }
    if (!wasSelected) {
      _scheduleTabOverflowUpdate();
      return;
    }
    final nextPath = _openPaths.isEmpty
        ? null
        : _openPaths[math.min(index, _openPaths.length - 1)];
    unawaited(_loadSource(nextPath));
  }

  void _closeSelectedSource() {
    final selectedPath = _selectedPath;
    if (selectedPath != null) _closeSource(selectedPath);
  }

  KeyEventResult _handlePanelKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if ((!keyboard.isControlPressed && !keyboard.isMetaPressed) ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event.physicalKey == PhysicalKeyboardKey.keyW) {
      _closeSelectedSource();
      return KeyEventResult.handled;
    }
    if (event.physicalKey == PhysicalKeyboardKey.keyF) {
      _showSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openDroppedFiles(Iterable<String> paths) async {
    final accepted = <String>[];
    for (final path in paths) {
      if (path.isEmpty || !await File(path).exists()) continue;
      final key = _pathKey(path);
      _externalPathKeys.add(key);
      _sourceTextCache.remove(key);
      if (!_openPaths.any((item) => _pathKey(item) == key)) {
        _openPaths.add(path);
      }
      accepted.add(path);
    }
    if (!mounted) return;
    setState(() => _draggingFiles = false);
    if (accepted.isNotEmpty) {
      await _loadSource(accepted.first);
      if (_searchVisible && _searchController.text.isNotEmpty) {
        _queueSearch(_searchController.text, immediate: true);
      }
    }
  }

  GlobalKey _tabKeyFor(String path) =>
      _tabKeys.putIfAbsent(_pathKey(path), GlobalKey.new);

  void _ensureSelectedTabVisible() {
    final selectedPath = _selectedPath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || selectedPath == null) return;
      final tabContext = _tabKeys[_pathKey(selectedPath)]?.currentContext;
      if (tabContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            tabContext,
            alignment: 0.5,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      _updateTabOverflow();
    });
  }

  void _scheduleTabOverflowUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTabOverflow());
  }

  void _updateTabOverflow() {
    if (!mounted || !_tabController.hasClients) return;
    final canScrollRight = _tabController.position.extentAfter > 1;
    if (canScrollRight == _canScrollTabsRight) return;
    setState(() => _canScrollTabsRight = canScrollRight);
  }

  void _handleTabPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !_tabController.hasClients ||
        event.scrollDelta.dy == 0) {
      return;
    }
    final position = _tabController.position;
    final target = (_tabController.offset + event.scrollDelta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _tabController.jumpTo(target);
  }

  void _showSearch() {
    final wasVisible = _searchVisible;
    if (!wasVisible) setState(() => _searchVisible = true);
    if (!wasVisible && _searchController.text.isNotEmpty) {
      _queueSearch(_searchController.text, immediate: true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchGeneration += 1;
    setState(() {
      _searchVisible = false;
      _searching = false;
      _searchResults = const [];
      _activeSearchIndex = -1;
      _revealedSearchLine = null;
    });
    _panelFocusNode.requestFocus();
  }

  void _queueSearch(String query, {bool immediate = false}) {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    if (query.isEmpty) {
      setState(() {
        _searching = false;
        _searchResults = const [];
        _activeSearchIndex = -1;
        _revealedSearchLine = null;
      });
      return;
    }
    setState(() => _searching = true);
    void run() => unawaited(_searchAcrossFiles(query, generation));
    if (immediate) {
      run();
    } else {
      _searchDebounce = Timer(const Duration(milliseconds: 180), run);
    }
  }

  Future<void> _searchAcrossFiles(String query, int generation) async {
    final pathsByKey = <String, String>{};
    for (final path in [..._sourceFiles, ..._openPaths]) {
      pathsByKey.putIfAbsent(_pathKey(path), () => path);
    }
    final lowerQuery = query.toLowerCase();
    final results = <_SourceSearchResult>[];
    for (final path in pathsByKey.values) {
      if (generation != _searchGeneration) return;
      try {
        final source = await _readSourceText(path);
        final lines = source
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .split('\n');
        for (var index = 0; index < lines.length; index += 1) {
          final column = lines[index].toLowerCase().indexOf(lowerQuery);
          if (column < 0) continue;
          results.add(
            _SourceSearchResult(
              path: path,
              line: index + 1,
              column: column + 1,
              preview: lines[index].trim(),
            ),
          );
          if (results.length >= 1000) break;
        }
      } on Object {
        // Missing build-machine paths and non-text dropped files are skipped.
      }
      if (results.length >= 1000) break;
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _searching = false;
      _searchResults = results;
      _activeSearchIndex = results.isEmpty ? -1 : 0;
    });
  }

  void _moveSearchResult(int delta) {
    if (_searchResults.isEmpty) return;
    final next = (_activeSearchIndex + delta) % _searchResults.length;
    _activateSearchResult(next < 0 ? next + _searchResults.length : next);
  }

  void _activateSearchResult(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    final result = _searchResults[index];
    setState(() => _activeSearchIndex = index);
    unawaited(_loadSource(result.path, revealLine: result.line));
  }

  Future<String> _resolveSourcePath(String debugPath) async {
    if (await File(debugPath).exists()) return debugPath;
    final sourceRoot = controller.debugState.sourceRoot;
    if (sourceRoot.isEmpty) return debugPath;

    final cacheKey = _pathKey(debugPath);
    final cached = _resolvedSourcePaths[cacheKey];
    if (cached != null && await File(cached).exists()) return cached;

    final normalized = debugPath.replaceAll('\\', '/');
    final isAbsolute =
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
    if (!isAbsolute) {
      final direct = File(
        '$sourceRoot${Platform.pathSeparator}${normalized.replaceAll('/', Platform.pathSeparator)}',
      );
      if (await direct.exists()) {
        _resolvedSourcePaths[cacheKey] = direct.path;
        return direct.path;
      }
    }

    final targetName = _basename(debugPath).toLowerCase();
    File? bestMatch;
    var bestScore = -1;
    final index = await (_sourceRootIndexFuture ??= _indexSourceRoot(
      sourceRoot,
    ));
    for (final path in index[targetName] ?? const <String>[]) {
      final score = _matchingPathSuffixLength(debugPath, path);
      if (score > bestScore) {
        bestMatch = File(path);
        bestScore = score;
      }
    }
    if (bestMatch != null) {
      _resolvedSourcePaths[cacheKey] = bestMatch.path;
      return bestMatch.path;
    }
    return debugPath;
  }

  Future<Map<String, List<String>>> _indexSourceRoot(String sourceRoot) async {
    final index = <String, List<String>>{};
    try {
      await for (final entity in Directory(
        sourceRoot,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        index
            .putIfAbsent(_basename(entity.path).toLowerCase(), () => <String>[])
            .add(entity.path);
      }
    } on FileSystemException {
      return const <String, List<String>>{};
    }
    return index;
  }

  Future<void> _locateSourceFile() async {
    final selectedPath = _selectedPath;
    if (selectedPath == null) return;
    final localPath = await pickSourceFile();
    if (localPath == null || localPath.isEmpty) return;
    _sourceOverrides[_pathKey(selectedPath)] = localPath;
    _sourceTextCache.remove(_pathKey(selectedPath));
    await _loadSource(selectedPath);
  }

  void _scrollToCurrentLine({bool immediate = false}) {
    final currentPath = controller.debugState.currentSource;
    final currentLine = controller.debugState.currentLine;
    if (currentPath == null ||
        currentLine == null ||
        _selectedPath == null ||
        !controller.sourcePathsMatch(currentPath, _selectedPath!)) {
      return;
    }
    _scrollToLine(currentLine, immediate: immediate);
  }

  void _scrollToLine(int line, {bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_verticalController.hasClients) return;
      final viewport = _verticalController.position.viewportDimension;
      final target = ((line - 1) * _lineHeight - viewport * 0.38).clamp(
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            _closeSelectedSource,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            _closeSelectedSource,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _showSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchVisible) _closeSearch();
        },
      },
      child: Focus(
        focusNode: _panelFocusNode,
        autofocus: true,
        onKeyEvent: _handlePanelKeyEvent,
        child: Listener(
          onPointerDown: (_) => _panelFocusNode.requestFocus(),
          child: DropTarget(
            key: const ValueKey('source-file-drop-target'),
            onDragEntered: (_) {
              if (mounted) setState(() => _draggingFiles = true);
            },
            onDragExited: (_) {
              if (mounted) setState(() => _draggingFiles = false);
            },
            onDragDone: (details) => unawaited(
              _openDroppedFiles(details.files.map((file) => file.path)),
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildToolbar(),
                    if (_searchVisible) _buildSearchArea(),
                    const Divider(height: 1, color: TalColors.borderSoft),
                    Expanded(child: _buildBody()),
                    _buildRegisterStrip(),
                  ],
                ),
                if (_draggingFiles)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('source-file-drop-overlay'),
                        decoration: BoxDecoration(
                          color: TalColors.accent.withValues(alpha: 0.08),
                          border: Border.all(color: TalColors.accent, width: 2),
                        ),
                        child: const Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: TalColors.surfaceAlt,
                              borderRadius: BorderRadius.all(
                                Radius.circular(6),
                              ),
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              child: Text(
                                '释放以打开文件',
                                style: TextStyle(color: TalColors.text),
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
        ),
      ),
    );
  }

  Widget _buildSearchArea() {
    final query = _searchController.text;
    final status = _searching
        ? '搜索中…'
        : query.isEmpty
        ? '输入文本'
        : _searchResults.isEmpty
        ? '无结果'
        : '${_activeSearchIndex + 1} / ${_searchResults.length}';
    final resultHeight = math.min(168.0, _searchResults.length * 30.0);
    return Container(
      key: const ValueKey('source-search-area'),
      color: TalColors.surfaceAlt,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 10),
                const Icon(Icons.search, size: 16, color: TalColors.muted),
                const SizedBox(width: 7),
                Expanded(
                  child: TextField(
                    key: const ValueKey('source-search-field'),
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    autofocus: true,
                    maxLines: 1,
                    onChanged: _queueSearch,
                    onSubmitted: (_) {
                      if (_activeSearchIndex >= 0) {
                        _activateSearchResult(_activeSearchIndex);
                      }
                    },
                    style: const TextStyle(
                      color: TalColors.text,
                      fontSize: 12,
                      fontFamily: talFontFamily,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '在所有源码文件中搜索',
                      hintStyle: talMuted.copyWith(fontSize: 12),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    style: talMuted.copyWith(fontSize: 11),
                  ),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-previous'),
                  tooltip: '上一个结果',
                  icon: Icons.keyboard_arrow_up,
                  onPressed: _searchResults.isEmpty
                      ? null
                      : () => _moveSearchResult(-1),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-next'),
                  tooltip: '下一个结果',
                  icon: Icons.keyboard_arrow_down,
                  onPressed: _searchResults.isEmpty
                      ? null
                      : () => _moveSearchResult(1),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-close'),
                  tooltip: '关闭搜索',
                  icon: Icons.close,
                  onPressed: _closeSearch,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          if (_searchResults.isNotEmpty)
            Container(
              height: resultHeight,
              decoration: const BoxDecoration(
                color: TalColors.surface,
                border: Border(top: BorderSide(color: TalColors.borderSoft)),
              ),
              child: ListView.builder(
                key: const ValueKey('source-search-results'),
                itemExtent: 30,
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final result = _searchResults[index];
                  final selected = index == _activeSearchIndex;
                  return InkWell(
                    key: ValueKey('source-search-result-$index'),
                    onTap: () => _activateSearchResult(index),
                    child: ColoredBox(
                      color: selected
                          ? TalColors.selection.withValues(alpha: 0.55)
                          : Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 220,
                              child: Text(
                                '${_basename(result.path)}:${result.line}:${result.column}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: TalColors.text,
                                  fontSize: 11,
                                  fontFamily: talFontFamily,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                result.preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: talMuted.copyWith(
                                  fontSize: 11,
                                  fontFamily: talFontFamily,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
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
          Expanded(child: _buildSourceTabs()),
          _DebugToolbarButton(
            key: const ValueKey('source-root-picker'),
            tooltip: controller.debugState.sourceRoot.isEmpty
                ? '设置工程源码根目录'
                : '工程源码根目录：${controller.debugState.sourceRoot}',
            icon: controller.debugState.sourceRoot.isEmpty
                ? Icons.folder_open_outlined
                : Icons.folder_special_outlined,
            onPressed: controller.chooseSourceRoot,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildSourceTabs() {
    final files = _sourceFiles;
    _scheduleTabOverflowUpdate();
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    key: const ValueKey('source-tabs-scroll-area'),
                    onPointerSignal: _handleTabPointerSignal,
                    child: SingleChildScrollView(
                      controller: _tabController,
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (_openPaths.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Center(
                                child: Text(
                                  files.isEmpty
                                      ? 'ELF 中没有源码调试信息'
                                      : '从右侧列表打开源码文件',
                                  style: talMuted.copyWith(fontSize: 12),
                                ),
                              ),
                            )
                          else
                            for (final path in _openPaths)
                              _buildSourceTab(path),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      key: const ValueKey('source-tabs-right-fade'),
                      opacity: _canScrollTabsRight ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: Container(
                        width: 54,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, TalColors.surface],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            key: const ValueKey('source-file-menu'),
            tooltip: '打开源码标签',
            enabled: files.isNotEmpty,
            onSelected: _openSource,
            itemBuilder: (context) => [
              for (final path in files)
                PopupMenuItem<String>(
                  key: ValueKey('source-file-option-$path'),
                  value: path,
                  child: Tooltip(
                    message: path,
                    child: Row(
                      children: [
                        Icon(
                          _openPaths.any(
                                (openPath) =>
                                    controller.sourcePathsMatch(openPath, path),
                              )
                              ? Icons.check
                              : Icons.description_outlined,
                          size: 15,
                          color: TalColors.muted,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _basename(path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            child: const SizedBox(
              width: 28,
              height: 28,
              child: Icon(Icons.add, size: 17, color: TalColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceTab(String path) {
    final selected =
        _selectedPath != null &&
        controller.sourcePathsMatch(_selectedPath!, path);
    return Tooltip(
      message: path,
      child: Material(
        key: _tabKeyFor(path),
        color: selected ? TalColors.surfaceAlt : Colors.transparent,
        child: InkWell(
          key: ValueKey('source-tab-$path'),
          onTap: () => _openSource(path),
          child: Container(
            key: selected ? ValueKey('source-tab-active-$path') : null,
            constraints: const BoxConstraints(minWidth: 92, maxWidth: 230),
            height: 29,
            padding: const EdgeInsets.only(left: 9, right: 3),
            decoration: BoxDecoration(
              border: Border(
                right: const BorderSide(color: TalColors.borderSoft),
                bottom: BorderSide(
                  color: selected ? TalColors.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 14,
                  color: selected ? TalColors.text : TalColors.muted,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _basename(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? TalColors.text : TalColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                IconButton(
                  key: ValueKey('source-tab-close-$path'),
                  tooltip: '关闭 ${_basename(path)}',
                  onPressed: () => _closeSource(path),
                  icon: const Icon(Icons.close, size: 13),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 22,
                    height: 22,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
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
    final requested = controller.debugState.requestedBreakpoints.entries
        .where((entry) => controller.sourcePathsMatch(entry.key, path))
        .expand((entry) => entry.value)
        .toSet();
    final breakpoint = controller.debugState.resolvedBreakpoints
        .where(
          (item) =>
              controller.sourcePathsMatch(item.path, path) &&
              item.requestedLine == lineNumber,
        )
        .firstOrNull;
    final hasBreakpoint = requested.contains(lineNumber);
    final executableLines = controller.executableLinesFor(path);
    final canSetBreakpoint = executableLines.contains(lineNumber);
    final isCurrent =
        controller.debugState.currentLine == lineNumber &&
        controller.debugState.currentSource != null &&
        controller.sourcePathsMatch(controller.debugState.currentSource!, path);
    final isSearchResult = _revealedSearchLine == lineNumber;
    return ColoredBox(
      color: isCurrent
          ? const Color(0x333B82F6)
          : isSearchResult
          ? TalColors.amber.withValues(alpha: 0.16)
          : Colors.transparent,
      child: Row(
        children: [
          InkWell(
            key: ValueKey('breakpoint-$lineNumber'),
            onTap: canSetBreakpoint
                ? () => controller.toggleBreakpoint(path, lineNumber)
                : null,
            child: SizedBox(
              width: 76,
              height: _lineHeight,
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
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
                                  (breakpoint?.verified == true
                                      ? '断点已设置'
                                      : '等待设置断点'),
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
                  Container(
                    key: ValueKey('executable-line-$lineNumber'),
                    width: 46,
                    height: _lineHeight,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 4),
                    color: canSetBreakpoint
                        ? const Color(0xFF353236)
                        : Colors.transparent,
                    child: Text(
                      '$lineNumber',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: canSetBreakpoint
                            ? const Color(0xFFC8C4C9)
                            : const Color(0xFF625E63),
                        fontSize: 12,
                        height: 1.45,
                        fontFamily: talFontFamily,
                      ),
                    ),
                  ),
                ],
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

class _SourceSearchResult {
  const _SourceSearchResult({
    required this.path,
    required this.line,
    required this.column,
    required this.preview,
  });

  final String path;
  final int line;
  final int column;
  final String preview;
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

int _matchingPathSuffixLength(String left, String right) {
  final leftParts = left
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .map((part) => part.toLowerCase())
      .toList();
  final rightParts = right
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .map((part) => part.toLowerCase())
      .toList();
  var score = 0;
  while (score < leftParts.length && score < rightParts.length) {
    if (leftParts[leftParts.length - 1 - score] !=
        rightParts[rightParts.length - 1 - score]) {
      break;
    }
    score += 1;
  }
  return score;
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
