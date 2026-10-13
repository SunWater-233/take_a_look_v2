part of 'panels.dart';

class _SourceDebugPanel extends StatefulWidget {
  const _SourceDebugPanel({
    required this.controller,
    this.readOnlyPreview = false,
  });

  final TakeALookController controller;
  final bool readOnlyPreview;

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
  List<String> get _openPaths => controller.sourceWorkspace.openPaths;
  String get _sourceViewId => identityHashCode(this).toString();
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};
  final Set<String> _externalPathKeys = <String>{};
  final SourceDocuments _sourceDocuments = SourceDocuments();
  List<String> _sourceFiles = const [];
  List<String> _searchIndexPaths = const [];
  Future<List<SourceSearchFile>>? _searchFileIndexFuture;
  int _searchIndexGeneration = 0;
  final FocusNode _panelFocusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  String? _selectedPath;
  List<HighlightedSourceLine> _lines = const [];
  final SourceHighlighter _highlighter = SourceHighlighter();
  int _maximumLineLength = 0;
  Set<int> _requestedLines = const {};
  Set<int> _executableLines = const {};
  Map<int, DebugBreakpoint> _lineBreakpoints = const {};
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
  Map<String, String> get _resolvedSourcePaths =>
      _sourceDocuments.resolvedPaths;
  String _observedSourceRoot = '';
  String? _observedCurrentSource;
  int? _observedCurrentLine;
  int _observedStopRevision = -1;
  String _refreshedFirmwareTask = '';

  TakeALookController get controller => widget.controller;

  double get _lineNumberWidth =>
      math.max(46.0, 22 + _lines.length.toString().length * 8.0);

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_updateTabOverflow);
    controller.debugChanges.addListener(_handleDebugChange);
    controller.symbolChanges.addListener(_handleDebugChange);
    controller.sourceWorkspaceChanges.addListener(_handleSourceWorkspaceChange);
    controller.sourceToolsChanges.addListener(_handleFirmwareTask);
    if (!widget.readOnlyPreview) {
      controller.setSourceViewVisible(_sourceViewId, true);
    }
    _restoreSourceWorkspace();
    _handleDebugChange();
  }

  @override
  void didUpdateWidget(covariant _SourceDebugPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == controller &&
        oldWidget.readOnlyPreview == widget.readOnlyPreview) {
      return;
    }
    oldWidget.controller.debugChanges.removeListener(_handleDebugChange);
    oldWidget.controller.symbolChanges.removeListener(_handleDebugChange);
    oldWidget.controller.sourceToolsChanges.removeListener(_handleFirmwareTask);
    oldWidget.controller.sourceWorkspaceChanges.removeListener(
      _handleSourceWorkspaceChange,
    );
    oldWidget.controller.setSourceViewVisible(_sourceViewId, false);
    controller.debugChanges.addListener(_handleDebugChange);
    controller.symbolChanges.addListener(_handleDebugChange);
    controller.sourceToolsChanges.addListener(_handleFirmwareTask);
    controller.sourceWorkspaceChanges.addListener(_handleSourceWorkspaceChange);
    if (!widget.readOnlyPreview) {
      controller.setSourceViewVisible(_sourceViewId, true);
    }
    _selectedPath = null;
    _tabKeys.clear();
    _externalPathKeys.clear();
    _sourceDocuments.clear();
    _sourceFiles = const [];
    _resolvedSourcePaths.clear();
    _invalidateSearchFileIndex();
    _sourceDocuments.clearIndex();
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
    _observedStopRevision = -1;
    _restoreSourceWorkspace();
    _handleDebugChange();
  }

  @override
  void dispose() {
    controller.debugChanges.removeListener(_handleDebugChange);
    controller.symbolChanges.removeListener(_handleDebugChange);
    controller.sourceToolsChanges.removeListener(_handleFirmwareTask);
    controller.sourceWorkspaceChanges.removeListener(
      _handleSourceWorkspaceChange,
    );
    controller.setSourceViewVisible(_sourceViewId, false);
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

  void _restoreSourceWorkspace() {
    // Reopening the panel must retain a user's file choice instead of treating
    // the same stopped PC as a new debugger stop.
    if (controller.sourceWorkspace.selectedPath != null &&
        controller.sourceWorkspace.viewedStopRevision ==
            controller.debugState.stopRevision) {
      _observedCurrentSource = controller.debugState.currentSource;
      _observedCurrentLine = controller.debugState.currentLine;
      _observedStopRevision = controller.debugState.stopRevision;
    }
    for (final path in _openPaths) {
      _externalPathKeys.add(_pathKey(path));
    }
    if (!widget.readOnlyPreview) controller.dismissSourceAttention();
  }

  void _handleSourceWorkspaceChange() {
    if (!mounted) return;
    final nextPath =
        controller.sourceWorkspace.selectedPath ??
        (widget.readOnlyPreview ? _openPaths.firstOrNull : null);
    if (nextPath != _selectedPath) {
      unawaited(_loadSource(nextPath));
      _restorePanelFocus();
    } else {
      setState(() {});
      _scheduleTabOverflowUpdate();
    }
  }

  void _handleDebugChange() {
    if (!mounted) return;
    final sourceRootChanged =
        _observedSourceRoot != controller.debugState.sourceRoot;
    if (sourceRootChanged) {
      _observedSourceRoot = controller.debugState.sourceRoot;
      _resolvedSourcePaths.clear();
      _sourceDocuments.clear();
      _sourceDocuments.clearIndex();
      _invalidateSearchFileIndex();
    }
    final currentSource = controller.debugState.currentSource;
    final currentLine = controller.debugState.currentLine;
    final locationChanged =
        _observedStopRevision != controller.debugState.stopRevision ||
        currentSource != _observedCurrentSource ||
        currentLine != _observedCurrentLine;
    _observedCurrentSource = currentSource;
    _observedCurrentLine = currentLine;
    _observedStopRevision = controller.debugState.stopRevision;
    final files = _collectSourceFiles();
    final sourceFilesChanged = !listEquals(files, _sourceFiles);
    _sourceFiles = files;
    String? nextPath = controller.sourceWorkspace.selectedPath;
    if (locationChanged && currentSource != null && currentSource.isNotEmpty) {
      nextPath = _matchingPath(currentSource, files) ?? currentSource;
    } else if (nextPath == null ||
        (!_externalPathKeys.contains(_pathKey(nextPath)) &&
            _matchingPath(nextPath, files) == null)) {
      nextPath = _openPaths.firstOrNull;
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

  void _handleFirmwareTask() {
    final task = controller.sourceTask;
    if (!mounted ||
        task.status != 'succeeded' ||
        task.details['kind'] == 'build' ||
        task.id == _refreshedFirmwareTask) {
      return;
    }
    _refreshedFirmwareTask = task.id;
    _sourceDocuments.clear();
    _invalidateSearchFileIndex();
    if (_selectedPath != null) unawaited(_loadSource(_selectedPath));
    if (_searchVisible && _searchController.text.isNotEmpty) {
      _queueSearch(_searchController.text, immediate: true);
    }
  }

  Future<void> _loadSource(String? path, {int? revealLine}) async {
    if (path != null && !widget.readOnlyPreview) {
      controller.openSourceFile(path);
      path = controller.openSourcePathFor(path) ?? path;
    }
    final generation = ++_loadGeneration;
    setState(() {
      _selectedPath = path;
      _revealedSearchLine = revealLine;
      _lines = const [];
      _loadError = null;
    });
    _ensureSelectedTabVisible();
    if (path == null) return;
    try {
      final source = await _readSourceDocument(path);
      final highlighted = await _highlighter.prepare(source);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _lines = highlighted.lines;
        _maximumLineLength = highlighted.maximumLineLength;
      });
      if (!widget.readOnlyPreview) controller.markSourceFileRead(path);
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

  Future<SourceSearchText> _readSourceDocument(
    String path, {
    String? localPath,
  }) {
    return _sourceDocuments.read(
      path,
      sourceRoot: controller.debugState.sourceRoot,
      localPath: localPath,
    );
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
      _tabKeys.remove(_pathKey(openPath));
      if (_matchingPath(openPath, _sourceFiles) == null) {
        _externalPathKeys.remove(_pathKey(openPath));
      }
    });
    controller.closeSourceFile(openPath);
    if (_searchVisible && _searchController.text.isNotEmpty) {
      _queueSearch(_searchController.text, immediate: true);
    }
    if (!wasSelected) {
      _scheduleTabOverflowUpdate();
      return;
    }
    final nextPath = controller.sourceWorkspace.selectedPath;
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
      _sourceDocuments.invalidate(key);
      controller.openSourceFile(path, select: false);
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
        : (_indexSourceRoot(root));
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
                  final score = sourcePathSuffixLength(path, candidate);
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
    HighlightedSourceLine line,
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
    final sourceFile = await _sourceDocuments.resolve(
      sourcePath,
      controller.debugState.sourceRoot,
    );
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
        : await (_indexSourceRoot(root));
    final indexedMatches =
        rootIndex[_basename(includeName).toLowerCase()] ?? const <String>[];
    if (indexedMatches.isNotEmpty) {
      final ranked =
          indexedMatches
              .map((path) => (path, sourcePathSuffixLength(includeName, path)))
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

  Future<Map<String, List<String>>> _indexSourceRoot(String root) =>
      _sourceDocuments.indexRoot(root);

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
              LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SourceBuildToolbar(
                      controller: controller,
                      compact: constraints.maxHeight < 260,
                    ),
                    AnimatedBuilder(
                      animation: controller.sourceToolsChanges,
                      builder: (context, _) => _buildToolbar(),
                    ),
                    if (_searchVisible) _buildSearchArea(),
                    const Divider(height: 1, color: TalColors.borderSoft),
                    Expanded(child: _buildBody()),
                    _buildRegisterStrip(),
                    _SourceTaskOutput(
                      controller: controller,
                      maxHeight: constraints.maxHeight < 240
                          ? 34
                          : (constraints.maxHeight * .32).clamp(85.0, 264.0),
                      onOpenLocation: (path, line) {
                        _sourceDocuments.invalidate(path);
                        _openSource(path);
                        unawaited(_loadSource(path, revealLine: line));
                      },
                    ),
                  ],
                ),
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
    final connected =
        controller.connectionStatus == ConnectionStatus.connected &&
        !controller.sourceTask.blocksProbe;
    final isRunning = state == DebugExecutionState.running;
    return SizedBox(
      height: TalUiTheme.of(context).targetExtent(42),
      child: Row(
        children: [
          const SizedBox(width: 8),
          _DebugToolbarButton(
            key: const ValueKey('debug-run-control'),
            tooltip: isRunning ? '暂停目标' : '继续运行',
            icon: isRunning ? Icons.pause : Icons.play_arrow,
            onPressed: !connected
                ? null
                : switch (state) {
                    DebugExecutionState.running => controller.haltTarget,
                    DebugExecutionState.halted => controller.resumeTarget,
                    _ => null,
                  },
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
            onPressed: controller.sourceTask.running
                ? null
                : controller.chooseSourceRoot,
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
                SizedBox(
                  width: 10,
                  child: controller.isSourceFileUnread(path)
                      ? Center(
                          child: _SourceUnreadDot(
                            key: ValueKey('source-file-unread-$path'),
                          ),
                        )
                      : null,
                ),
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
        final path = _selectedPath!;
        _requestedLines = controller.debugState.requestedBreakpoints.entries
            .where((entry) => controller.sourcePathsMatch(entry.key, path))
            .expand((entry) => entry.value)
            .toSet();
        _executableLines = controller.executableLinesFor(path);
        _lineBreakpoints = {};
        for (final item in controller.debugState.resolvedBreakpoints) {
          if (controller.sourcePathsMatch(item.path, path)) {
            _lineBreakpoints.putIfAbsent(item.requestedLine, () => item);
          }
        }
        final longest = _maximumLineLength;
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
    final breakpoint = _lineBreakpoints[lineNumber];
    final hasBreakpoint = _requestedLines.contains(lineNumber);
    final canSetBreakpoint = _executableLines.contains(lineNumber);
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
      child: SingleChildScrollView(
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
