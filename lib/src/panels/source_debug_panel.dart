part of 'panels.dart';

class _SourceDebugPanel extends StatefulWidget {
  const _SourceDebugPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_SourceDebugPanel> createState() => _SourceDebugPanelState();
}

class _SourceDebugPanelState extends State<_SourceDebugPanel> {
  static const _lineHeight = 22.0;
  static const _searchResultHeight = 30.0;
  static const _maxSearchResults = 1000;
  static const _searchReadBatchSize = 8;
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _tabController = ScrollController();
  final ScrollController _searchResultsController = ScrollController(
    keepScrollOffset: false,
  );
  final List<String> _openPaths = <String>[];
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};
  final Set<String> _externalPathKeys = <String>{};
  final Map<String, Future<SourceSearchText>> _sourceTextCache = {};
  List<String> _sourceFiles = const [];
  List<String> _searchIndexPaths = const [];
  Future<List<SourceSearchFile>>? _searchFileIndexFuture;
  int _searchIndexGeneration = 0;
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
  bool _searchSelectionChanged = false;
  int _activeSearchIndex = -1;
  int? _revealedSearchLine;
  _SourceTokenSelection? _sourceSelection;
  Timer? _searchDebounce;
  List<_SourceSearchResult> _searchResults = const [];
  final Map<String, String> _resolvedSourcePaths = <String, String>{};
  Future<Map<String, List<String>>>? _sourceRootIndexFuture;
  String _observedSourceRoot = '';
  String? _observedCurrentSource;
  int? _observedCurrentLine;

  TakeALookController get controller => widget.controller;

  double get _lineNumberWidth =>
      math.max(46.0, 22 + _lines.length.toString().length * 8.0);

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
    _sourceFiles = const [];
    _resolvedSourcePaths.clear();
    _invalidateSearchFileIndex();
    _sourceRootIndexFuture = null;
    _searchDebounce?.cancel();
    _searchGeneration += 1;
    _searchController.clear();
    _searchResults = const [];
    _sourceSelection = null;
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
    _searchResultsController.dispose();
    _panelFocusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _tabController
      ..removeListener(_updateTabOverflow)
      ..dispose();
    super.dispose();
  }

  List<String> _collectSourceFiles() {
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
      _invalidateSearchFileIndex();
    }
    final currentSource = controller.debugState.currentSource;
    final currentLine = controller.debugState.currentLine;
    final locationChanged =
        currentSource != _observedCurrentSource ||
        currentLine != _observedCurrentLine;
    _observedCurrentSource = currentSource;
    _observedCurrentLine = currentLine;
    final files = _collectSourceFiles();
    final sourceFilesChanged = !listEquals(files, _sourceFiles);
    _sourceFiles = files;
    String? nextPath = _selectedPath;
    if (locationChanged && currentSource != null && currentSource.isNotEmpty) {
      nextPath = _matchingPath(currentSource, files) ?? currentSource;
    } else if (nextPath == null ||
        (!_externalPathKeys.contains(_pathKey(nextPath)) &&
            _matchingPath(nextPath, files) == null)) {
      nextPath = _openPaths.firstOrNull;
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
    if ((sourceRootChanged || sourceFilesChanged) &&
        _searchVisible &&
        _searchController.text.isNotEmpty) {
      _queueSearch(_searchController.text, immediate: true);
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

  Future<String> _readSourceText(String path) async =>
      (await _readSourceDocument(path)).text;

  Future<SourceSearchText> _readSourceDocument(
    String path, {
    String? localPath,
  }) {
    final key = _pathKey(path);
    // Cache in-flight reads and failures as well as successful reads. Typing a
    // new query must not re-read the same file or retry unavailable debug paths.
    return _sourceTextCache.putIfAbsent(key, () async {
      final sourcePath = localPath ?? await _resolveSourcePath(path);
      return SourceSearchText(await File(sourcePath).readAsString());
    });
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

  KeyEventResult _handlePanelKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (_searchVisible &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _moveSearchResult(
          event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1,
        );
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (event is KeyDownEvent) _confirmSearchResult();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _closeSearch();
        return KeyEventResult.handled;
      }
    }
    return _handleSourceCommand(event);
  }

  KeyEventResult _handleSourceCommand(KeyEvent event) {
    if (WorkspaceShortcut.closeSource.matches(event)) {
      _closeSelectedSource();
      return KeyEventResult.handled;
    }
    if (WorkspaceShortcut.findSource.matches(event)) {
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
    unawaited(_getSearchFiles());
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
    if (query.trim().isEmpty) {
      setState(() {
        _searching = false;
        _searchResults = const [];
        _activeSearchIndex = -1;
        _revealedSearchLine = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchResults = const [];
      _activeSearchIndex = -1;
      _searchSelectionChanged = false;
    });
    void run() => unawaited(_searchAcrossFiles(query, generation));
    if (immediate) {
      run();
    } else {
      _searchDebounce = Timer(const Duration(milliseconds: 100), run);
    }
  }

  void _invalidateSearchFileIndex() {
    _searchFileIndexFuture = null;
    _searchIndexGeneration += 1;
  }

  Future<List<SourceSearchFile>> _getSearchFiles() {
    final pathsByKey = <String, String>{};
    for (final path in [..._sourceFiles, ..._openPaths]) {
      pathsByKey.putIfAbsent(_pathKey(path), () => path);
    }
    final paths = pathsByKey.values.toList();
    if (_searchFileIndexFuture != null &&
        listEquals(paths, _searchIndexPaths)) {
      return _searchFileIndexFuture!;
    }
    _searchIndexPaths = paths;
    final indexGeneration = ++_searchIndexGeneration;
    final root = controller.debugState.sourceRoot;
    final rootIndex = root.isEmpty
        ? Future.value(const <String, List<String>>{})
        : (_sourceRootIndexFuture ??= _indexSourceRoot(root));
    return _searchFileIndexFuture = _buildSearchFileIndex(
      paths,
      root,
      rootIndex,
      Map.of(_resolvedSourcePaths),
      indexGeneration,
    );
  }

  Future<List<SourceSearchFile>> _buildSearchFileIndex(
    List<String> paths,
    String root,
    Future<Map<String, List<String>>> rootIndexFuture,
    Map<String, String> resolvedPaths,
    int generation,
  ) async {
    final rootIndex = await rootIndexFuture;
    if (!mounted || generation != _searchIndexGeneration) return const [];
    final filesByKey = <String, SourceSearchFile>{};
    for (final path in rootIndex.values.expand((paths) => paths)) {
      final file = SourceSearchFile(path: path, sourceRoot: root);
      filesByKey[file.key] = file;
    }
    for (var start = 0; start < paths.length; start += _searchReadBatchSize) {
      if (!mounted || generation != _searchIndexGeneration) return const [];
      final batch = await Future.wait(
        paths.skip(start).take(_searchReadBatchSize).map((path) async {
          final key = _pathKey(path);
          var localPath = resolvedPaths[key] ?? filesByKey[key]?.localPath;
          if (localPath == null && root.isNotEmpty) {
            localPath = filesByKey[_pathKey('$root/$path')]?.localPath;
            final candidates = rootIndex[_basename(path).toLowerCase()];
            if (localPath == null && candidates != null) {
              // Only ambiguous build-machine aliases need a filesystem probe,
              // and only when constructing the index, never for each query.
              if (!await File(path).exists()) {
                var bestScore = -1;
                for (final candidate in candidates) {
                  final score = _matchingPathSuffixLength(path, candidate);
                  if (score > bestScore) {
                    bestScore = score;
                    localPath = candidate;
                  }
                }
              }
            }
          }
          return SourceSearchFile(
            path: path,
            localPath: localPath,
            sourceRoot: root,
            searchContents: true,
          );
        }),
      );
      for (final file in batch) {
        // Keep a single result for a local file and its DWARF alias, retaining
        // the debug path for opening the source and setting breakpoints.
        if (filesByKey[file.key]?.searchContents != true) {
          filesByKey[file.key] = file;
        }
      }
    }
    return filesByKey.values.toList()..sort((left, right) {
      final priority = left.priority.compareTo(right.priority);
      return priority != 0 ? priority : left.key.compareTo(right.key);
    });
  }

  Future<SourceSearchText?> _readSearchDocument(SourceSearchFile file) async {
    try {
      return await _readSourceDocument(file.path, localPath: file.localPath);
    } on Object {
      return null;
    }
  }

  Future<void> _searchAcrossFiles(String query, int generation) async {
    final files = await _getSearchFiles();
    if (!mounted || generation != _searchGeneration) return;
    final fileResults = List.generate(3, (_) => <_SourceSearchResult>[]);
    for (final file in searchSourceFiles(
      files,
      query,
      limit: _maxSearchResults,
    )) {
      fileResults[file.priority].add(
        _SourceSearchResult.file(path: file.path, preview: file.localPath),
      );
    }
    _publishSearchResults(
      fileResults.expand((group) => group).toList(),
      generation,
    );
    // Render filename matches before reading and searching file contents.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _searchGeneration) return;
    final results = <_SourceSearchResult>[];
    for (var priority = 0; priority < fileResults.length; priority += 1) {
      results.addAll(
        fileResults[priority].take(_maxSearchResults - results.length),
      );
      if (results.length >= _maxSearchResults) break;
      final contentFiles = files
          .where(
            (file) =>
                file.priority == priority &&
                file.searchContents &&
                !file.isBinaryArtifact,
          )
          .toList();
      for (
        var start = 0;
        start < contentFiles.length;
        start += _searchReadBatchSize
      ) {
        if (!mounted || generation != _searchGeneration) return;
        final batch = contentFiles
            .skip(start)
            .take(_searchReadBatchSize)
            .toList();
        final documents = await Future.wait(batch.map(_readSearchDocument));
        if (!mounted || generation != _searchGeneration) return;
        for (var index = 0; index < batch.length; index += 1) {
          final document = documents[index];
          if (document == null) continue;
          for (final match in document.search(
            query,
            limit: _maxSearchResults - results.length,
          )) {
            results.add(
              _SourceSearchResult(
                path: batch[index].path,
                line: match.line,
                column: match.column,
                preview: match.preview,
              ),
            );
          }
          if (results.length >= _maxSearchResults) break;
        }
        _publishSearchResults(
          [
            ...results,
            ...fileResults.skip(priority + 1).expand((group) => group),
          ].take(_maxSearchResults).toList(),
          generation,
        );
        if (results.length >= _maxSearchResults) break;
        // Let new keystrokes cancel an obsolete content scan between batches.
        if (start + batch.length < contentFiles.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (results.length >= _maxSearchResults) break;
    }
    _publishSearchResults(results, generation, searching: false);
  }

  void _publishSearchResults(
    List<_SourceSearchResult> results,
    int generation, {
    bool searching = true,
  }) {
    if (!mounted || generation != _searchGeneration) return;
    final active = _searchSelectionChanged && _activeSearchIndex >= 0
        ? _searchResults[_activeSearchIndex]
        : null;
    final activeIndex = active == null ? 0 : results.indexOf(active);
    setState(() {
      _searching = searching;
      _searchResults = results;
      _activeSearchIndex = results.isEmpty ? -1 : math.max(0, activeIndex);
    });
    if (_searchSelectionChanged) _ensureSearchResultVisible();
  }

  void _moveSearchResult(int delta) {
    if (_searchResults.isEmpty) return;
    final next = (_activeSearchIndex + delta) % _searchResults.length;
    setState(() {
      _activeSearchIndex = next < 0 ? next + _searchResults.length : next;
      _searchSelectionChanged = true;
    });
    _searchFocusNode.requestFocus();
    _ensureSearchResultVisible();
  }

  void _ensureSearchResultVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_searchVisible ||
          !_searchResultsController.hasClients ||
          _activeSearchIndex < 0) {
        return;
      }
      final position = _searchResultsController.position;
      final top = _activeSearchIndex * _searchResultHeight;
      final bottom = top + _searchResultHeight;
      final target = top < position.pixels
          ? top
          : bottom > position.pixels + position.viewportDimension
          ? bottom - position.viewportDimension
          : position.pixels;
      if (target != position.pixels) {
        _searchResultsController.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
    });
  }

  void _confirmSearchResult() {
    _activateSearchResult(_activeSearchIndex);
  }

  void _activateSearchResult(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    final result = _searchResults[index];
    _closeSearch();
    if (_matchingPath(result.path, _sourceFiles) == null) {
      _externalPathKeys.add(_pathKey(result.path));
    }
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

  List<SymbolItem> _symbolsForToken(String token, String sourcePath) {
    final candidates = controller.symbols
        .where((symbol) => _symbolNameMatchesToken(symbol.name, token))
        .where(
          (symbol) =>
              controller.sourcePathsMatch(symbol.source, sourcePath) ||
              symbol.source == '未知来源',
        )
        .toList();
    if (candidates.isNotEmpty) return candidates;

    final globalCandidates = controller.symbols
        .where((symbol) => _symbolNameMatchesToken(symbol.name, token))
        .toList();
    return globalCandidates;
  }

  _SourceTokenSelection? _tokenAtOffset(
    String path,
    int lineIndex,
    _HighlightedSourceLine line,
    Offset offset,
  ) {
    if (line.rawText.isEmpty || offset.dx < 0) return null;
    final painter = TextPainter(
      text: TextSpan(
        children: line.spans,
        style: const TextStyle(
          color: TalColors.text,
          fontSize: 13,
          height: 1.45,
          fontFamily: talFontFamily,
          fontFamilyFallback: talFontFamilyFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final position = painter.getPositionForOffset(
      Offset(offset.dx, _lineHeight / 2),
    );
    if (offset.dx > painter.width) return null;
    var index = position.offset.clamp(0, line.rawText.length);
    if (index == line.rawText.length && index > 0) index -= 1;
    if (index >= line.rawText.length ||
        !_isIdentifierPart(line.rawText[index])) {
      return null;
    }
    var start = index;
    var end = index + 1;
    while (start > 0 && _isIdentifierPart(line.rawText[start - 1])) {
      start -= 1;
    }
    while (end < line.rawText.length && _isIdentifierPart(line.rawText[end])) {
      end += 1;
    }
    if (!_isIdentifierStart(line.rawText[start])) return null;
    return _SourceTokenSelection(
      path: path,
      lineIndex: lineIndex,
      start: start,
      end: end,
      token: line.rawText.substring(start, end),
    );
  }

  void _selectSourceToken(String path, int lineIndex, Offset localPosition) {
    final selection = _tokenAtOffset(
      path,
      lineIndex,
      _lines[lineIndex],
      localPosition,
    );
    if (selection == null) return;
    setState(() => _sourceSelection = selection);
  }

  List<TextSpan> _spansForSourceLine(String path, int lineIndex) {
    final line = _lines[lineIndex];
    final selection = _sourceSelection;
    if (selection == null ||
        selection.lineIndex != lineIndex ||
        !controller.sourcePathsMatch(selection.path, path)) {
      return line.spans;
    }
    final result = <TextSpan>[];
    var offset = 0;
    for (final span in line.spans) {
      final text = span.text ?? '';
      final spanStart = offset;
      final spanEnd = offset + text.length;
      final selectedStart = math.max(spanStart, selection.start);
      final selectedEnd = math.min(spanEnd, selection.end);
      if (selectedStart >= selectedEnd) {
        result.add(span);
      } else {
        if (spanStart < selectedStart) {
          result.add(
            TextSpan(
              text: text.substring(0, selectedStart - spanStart),
              style: span.style,
            ),
          );
        }
        result.add(
          TextSpan(
            text: text.substring(
              selectedStart - spanStart,
              selectedEnd - spanStart,
            ),
            style: span.style?.copyWith(backgroundColor: TalColors.selection),
          ),
        );
        if (selectedEnd < spanEnd) {
          result.add(
            TextSpan(
              text: text.substring(selectedEnd - spanStart),
              style: span.style,
            ),
          );
        }
      }
      offset = spanEnd;
    }
    return result;
  }

  Future<String?> _resolveIncludedSource(String sourcePath, String line) async {
    final includeName = _includeNameFromLine(line);
    if (includeName == null) return null;
    final sourceFile = await _resolveSourcePath(sourcePath);
    final candidates = <String>[];
    if (await File(sourceFile).exists()) {
      final parent = File(sourceFile).parent.path;
      candidates.add(
        '$parent${Platform.pathSeparator}${includeName.replaceAll('/', Platform.pathSeparator)}',
      );
    }
    final root = controller.debugState.sourceRoot;
    if (root.isNotEmpty) {
      candidates.add(
        '$root${Platform.pathSeparator}${includeName.replaceAll('/', Platform.pathSeparator)}',
      );
    }
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }

    final rootIndex = root.isEmpty
        ? const <String, List<String>>{}
        : await (_sourceRootIndexFuture ??= _indexSourceRoot(root));
    final indexedMatches =
        rootIndex[_basename(includeName).toLowerCase()] ?? const <String>[];
    if (indexedMatches.isNotEmpty) {
      final ranked =
          indexedMatches
              .map(
                (path) => (path, _matchingPathSuffixLength(includeName, path)),
              )
              .toList()
            ..sort((left, right) => right.$2.compareTo(left.$2));
      if (ranked.length == 1 || ranked[0].$2 > ranked[1].$2) {
        return ranked.first.$1;
      }
    }

    final sourceCandidates = _sourceFiles
        .where((path) => _pathKey(path).endsWith('/${_pathKey(includeName)}'))
        .toList();
    if (sourceCandidates.length == 1) return sourceCandidates.single;
    final basenameMatches = _sourceFiles
        .where(
          (path) =>
              _basename(path).toLowerCase() ==
              _basename(includeName).toLowerCase(),
        )
        .toList();
    return basenameMatches.length == 1 ? basenameMatches.single : null;
  }

  RelativeRect _contextMenuPosition(
    BuildContext context,
    Offset globalPosition,
  ) {
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

  Future<void> _showSourceContextMenu(
    BuildContext context,
    String sourcePath,
    int lineIndex,
    Offset globalPosition,
    Offset localPosition,
  ) async {
    final line = _lines[lineIndex];
    final selected = _sourceSelection;
    final hit =
        selected != null &&
            selected.lineIndex == lineIndex &&
            controller.sourcePathsMatch(selected.path, sourcePath)
        ? selected
        : _tokenAtOffset(sourcePath, lineIndex, line, localPosition);
    final token = hit?.token;
    final symbols = token == null
        ? const <SymbolItem>[]
        : _symbolsForToken(token, sourcePath);
    final includeName = _includeNameFromLine(line.rawText);
    final includePath = await _resolveIncludedSource(sourcePath, line.rawText);
    if (!context.mounted) return;

    final items = <PopupMenuEntry<String>>[];
    for (final symbol in symbols) {
      final symbolLabel = symbol.name == token ? token : symbol.name;
      final suffix = symbols.length > 1 ? '  ${symbol.addressLabel}' : '';
      final watched = controller.watches.any(
        (watch) => watch.symbol.key == symbol.key,
      );
      items.add(
        PopupMenuItem<String>(
          key: ValueKey('source-menu-watch-${symbol.key}'),
          value: 'watch:${symbol.key}',
          enabled: !watched,
          child: Text(
            watched
                ? '已在实时调试中  $symbolLabel$suffix'
                : '加入实时调试  $symbolLabel$suffix',
          ),
        ),
      );
    }
    if (includePath != null) {
      items.add(
        PopupMenuItem<String>(
          key: ValueKey('source-menu-include-$includePath'),
          value: 'include:$includePath',
          child: Text('打开头文件  ${_basename(includePath)}'),
        ),
      );
    } else if (includeName != null) {
      items.add(
        PopupMenuItem<String>(
          enabled: false,
          child: Text('无法定位头文件  ${_basename(includeName)}'),
        ),
      );
    }
    if (items.isEmpty) return;
    final menuContext = context;
    final action = await showTalContextMenu<String>(
      context: menuContext,
      position: _contextMenuPosition(menuContext, globalPosition),
      items: items,
    );
    if (!context.mounted || action == null) return;
    if (action.startsWith('watch:')) {
      controller.activateSymbol(action.substring('watch:'.length));
    } else if (action.startsWith('include:')) {
      final includePath = action.substring('include:'.length);
      if (_matchingPath(includePath, _sourceFiles) == null) {
        _externalPathKeys.add(_pathKey(includePath));
      }
      _openSource(includePath);
    }
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
    return PanelKeyboardListener(
      focusNode: _panelFocusNode,
      autofocus: true,
      onKeyEvent: _handlePanelKeyEvent,
      onWindowKeyEvent: _handleSourceCommand,
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
                            borderRadius: BorderRadius.all(Radius.circular(6)),
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
    );
  }

  Widget _buildSearchArea() {
    final query = _searchController.text;
    final status = _searching
        ? '搜索中…'
        : query.isEmpty
        ? '输入文件名或文本'
        : _searchResults.isEmpty
        ? '无结果'
        : '${_activeSearchIndex + 1} / ${_searchResults.length}';
    final resultHeight = math.min(
      168.0,
      _searchResults.length * _searchResultHeight,
    );
    return Container(
      key: const ValueKey('source-search-area'),
      color: TalColors.surfaceAlt,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: TalUiTheme.of(context).targetExtent(36),
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
                    onSubmitted: (_) => _confirmSearchResult(),
                    style: const TextStyle(
                      color: TalColors.text,
                      fontSize: 12,
                      fontFamily: talFontFamily,
                      fontFamilyFallback: talFontFamilyFallback,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '模糊查找文件名/路径，或搜索源码内容',
                      hintStyle: talMuted.copyWith(fontSize: 12),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                SizedBox(
                  width: 106,
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    style: talMuted.copyWith(fontSize: 11),
                  ),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-previous'),
                  tooltip: '上一个结果（↑）',
                  icon: Icons.keyboard_arrow_up,
                  onPressed: _searchResults.isEmpty
                      ? null
                      : () => _moveSearchResult(-1),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-next'),
                  tooltip: '下一个结果（↓）',
                  icon: Icons.keyboard_arrow_down,
                  onPressed: _searchResults.isEmpty
                      ? null
                      : () => _moveSearchResult(1),
                ),
                _DebugToolbarButton(
                  key: const ValueKey('source-search-close'),
                  tooltip: '关闭搜索（Esc）',
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
                controller: _searchResultsController,
                itemExtent: _searchResultHeight,
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final result = _searchResults[index];
                  final selected = index == _activeSearchIndex;
                  return Tooltip(
                    message: result.isFile ? result.preview : result.path,
                    child: InkWell(
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
                              Icon(
                                result.isFile
                                    ? Icons.insert_drive_file_outlined
                                    : Icons.find_in_page_outlined,
                                size: 14,
                                color: TalColors.muted,
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 220,
                                child: Text(
                                  result.isFile
                                      ? _basename(result.path)
                                      : '${_basename(result.path)}:${result.line}:${result.column}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: TalColors.text,
                                    fontSize: 11,
                                    fontFamily: talFontFamily,
                                    fontFamilyFallback: talFontFamilyFallback,
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
                                    fontFamilyFallback: talFontFamilyFallback,
                                  ),
                                ),
                              ),
                            ],
                          ),
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
      height: TalUiTheme.of(context).targetExtent(42),
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
      height: TalUiTheme.of(context).targetExtent(32),
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
            child: SizedBox(
              width: TalUiTheme.of(context).targetExtent(28),
              height: TalUiTheme.of(context).targetExtent(28),
              child: const Icon(Icons.add, size: 17, color: TalColors.muted),
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
            height: TalUiTheme.of(context).panelTabHeight,
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
                TalIconButton(
                  key: ValueKey('source-tab-close-$path'),
                  tooltip: '关闭 ${_basename(path)}',
                  onPressed: () => _closeSource(path),
                  icon: const Icon(Icons.close, size: 13),
                  style: ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(
                      Size.square(TalUiTheme.of(context).compactIconButtonSize),
                    ),
                    maximumSize: WidgetStatePropertyAll(
                      Size.square(TalUiTheme.of(context).compactIconButtonSize),
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

  List<Widget> _buildSourceSetupActions() {
    final symbolFile = controller.symbolFile;
    final sourceRoot = controller.debugState.sourceRoot;
    final hasSymbolFile = symbolFile.isNotEmpty;
    final hasSourceRoot = sourceRoot.isNotEmpty;
    return [
      Tooltip(
        message: hasSymbolFile ? '$symbolFile\n点击更换符号文件' : '打开 ELF / AXF 符号文件',
        child: TalButton.icon(
          key: const ValueKey('source-symbol-file-button'),
          onPressed: controller.chooseSymbolFile,
          style: hasSymbolFile ? talSuccessOutlinedButtonStyle : null,
          icon: Icon(
            hasSymbolFile
                ? Icons.check_circle_outline
                : Icons.file_open_outlined,
            size: 16,
            color: hasSymbolFile ? TalColors.success : null,
          ),
          label: Text(hasSymbolFile ? '符号文件已打开' : '打开符号文件'),
        ),
      ),
      Tooltip(
        message: hasSourceRoot ? '$sourceRoot\n点击更换文件根目录' : '选择工程源码所在的根目录',
        child: TalButton.icon(
          key: const ValueKey('source-root-directory-button'),
          onPressed: controller.chooseSourceRoot,
          style: hasSourceRoot ? talSuccessOutlinedButtonStyle : null,
          icon: Icon(
            hasSourceRoot ? Icons.check_circle_outline : Icons.folder_open,
            size: 16,
            color: hasSourceRoot ? TalColors.success : null,
          ),
          label: Text(hasSourceRoot ? '文件根目录已选择' : '选择文件根目录'),
        ),
      ),
    ];
  }

  Widget _buildBody() {
    if (_selectedPath == null) {
      final hasSourceFiles = _sourceFiles.isNotEmpty;
      return _SourceDebugEmptyState(
        icon: hasSourceFiles ? Icons.code : Icons.code_off,
        title: hasSourceFiles ? '选择要查看的源码' : '没有可显示的源码',
        detail: hasSourceFiles
            ? '点击右上角 + 或按 Ctrl+F 查找并打开源码文件。'
            : '请加载带 DWARF 调试信息的 ELF / AXF 文件。',
        actions: _buildSourceSetupActions(),
      );
    }
    if (_loadError != null) {
      return _SourceDebugEmptyState(
        icon: Icons.link_off,
        title: '找不到本地源码文件',
        detail: '$_selectedPath\n$_loadError',
        actions: _buildSourceSetupActions(),
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
        final contentWidth = math.max(
          constraints.maxWidth,
          30 + _lineNumberWidth + 14 + longest * 8.2,
        );
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
          SizedBox(
            width: 30,
            child: Center(
              child: isCurrent
                  ? const Icon(
                      Icons.arrow_right,
                      size: 18,
                      color: Color(0xFF65A7FF),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          InkWell(
            key: ValueKey('breakpoint-$lineNumber'),
            onTap: canSetBreakpoint
                ? () => controller.toggleBreakpoint(path, lineNumber)
                : null,
            child: Container(
              key: ValueKey('executable-line-$lineNumber'),
              width: _lineNumberWidth,
              height: _lineHeight,
              color: canSetBreakpoint
                  ? const Color(0xFF353236)
                  : Colors.transparent,
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: Center(
                      child: hasBreakpoint
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
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
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
                          fontFamilyFallback: talFontFamilyFallback,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: GestureDetector(
              key: ValueKey('source-line-$lineNumber'),
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (details) =>
                  _selectSourceToken(path, index, details.localPosition),
              onHorizontalDragStart: (details) =>
                  _selectSourceToken(path, index, details.localPosition),
              onHorizontalDragUpdate: (details) =>
                  _selectSourceToken(path, index, details.localPosition),
              onSecondaryTapUp: (details) => unawaited(
                _showSourceContextMenu(
                  context,
                  path,
                  index,
                  details.globalPosition,
                  details.localPosition,
                ),
              ),
              child: Text.rich(
                TextSpan(children: _spansForSourceLine(path, index)),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: const TextStyle(
                  color: TalColors.text,
                  fontSize: 13,
                  height: 1.45,
                  fontFamily: talFontFamily,
                  fontFamilyFallback: talFontFamilyFallback,
                ),
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
    return TalIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
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
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String detail;
  final List<Widget> actions;

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
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: actions,
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
  const _HighlightedSourceLine(this.spans, this.textLength, this.rawText);

  final List<TextSpan> spans;
  final int textLength;
  final String rawText;
}

class _SourceTokenSelection {
  const _SourceTokenSelection({
    required this.path,
    required this.lineIndex,
    required this.start,
    required this.end,
    required this.token,
  });

  final String path;
  final int lineIndex;
  final int start;
  final int end;
  final String token;
}

class _SourceSearchResult {
  const _SourceSearchResult({
    required this.path,
    required this.line,
    required this.column,
    required this.preview,
  });

  const _SourceSearchResult.file({required this.path, required this.preview})
    : line = null,
      column = null;

  final String path;
  final int? line;
  final int? column;
  final String preview;

  bool get isFile => line == null;
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
      return _HighlightedSourceLine(spans, line.length, line);
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
    return _HighlightedSourceLine(spans, line.length, line);
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

bool _isIdentifierStart(String value) => RegExp(r'[A-Za-z_]').hasMatch(value);

bool _isIdentifierPart(String value) => RegExp(r'[A-Za-z0-9_]').hasMatch(value);

bool _symbolNameMatchesToken(String symbolName, String token) =>
    symbolName == token || symbolName.endsWith('.$token');

String? _includeNameFromLine(String line) =>
    RegExp(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]').firstMatch(line)?.group(1);

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
