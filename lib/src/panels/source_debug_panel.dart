import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:tal_drag_preview/tal_drag_preview.dart';

import '../controller/controller.dart';
import '../app/file_pickers.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../models/models.dart';
import 'source_search.dart';
import 'source_search_controller.dart';
import 'source_highlighter.dart';
import 'source_documents.dart';
import 'source_references.dart';
import 'source_peek.dart';
import '../theme/theme.dart';

import 'shared_controls.dart';
import 'panel_frame.dart';
import 'source_file_drag_data.dart';

part 'source_build_tools.dart';
part 'source_navigation.dart';
part 'source_peek_actions.dart';
part 'workbench_output.dart';

class SourceDebugPanel extends StatefulWidget {
  const SourceDebugPanel({
    super.key,
    required this.controller,
    this.readOnlyPreview = false,
    this.externalOutput = false,
    this.visible = true,
  });

  final TakeALookController controller;
  final bool readOnlyPreview;
  final bool externalOutput;
  final bool visible;

  @override
  State<SourceDebugPanel> createState() => _SourceDebugPanelState();
}

class _SourceDebugPanelState extends State<SourceDebugPanel> {
  static const _lineHeight = 22.0;
  static const _searchResultHeight = 30.0;
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
  late final SourceSearchController _search = SourceSearchController(
    _sourceDocuments,
  );
  List<String> _sourceFiles = const [];
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
  bool _canScrollTabsRight = false;
  bool _draggingFiles = false;
  bool _searchVisible = false;
  bool _searching = false;
  bool _searchSelectionChanged = false;
  int _activeSearchIndex = -1;
  int? _revealedSearchLine;
  _SourceTokenSelection? _sourceSelection;
  final List<_SourceNavigationLocation> _navigationBack = [];
  final List<_SourceNavigationLocation> _navigationForward = [];
  bool _sourceTapWithModifier = false;
  _SourceTokenSelection? _hoveredToken;
  bool _hoveredTokenCanNavigate = false;
  bool _navigationModifierPressed = false;
  _SourcePeekSession? _sourcePeek;
  double? _sourcePeekHeight;
  double _visiblePeekHeight = 0;
  late final SourceReferencesController _references =
      SourceReferencesController(_sourceDocuments);
  List<SourceSearchResult> _searchResults = const [];
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
    HardwareKeyboard.instance.addHandler(_handleNavigationModifier);
    _tabController.addListener(_updateTabOverflow);
    controller.debugChanges.addListener(_handleDebugChange);
    controller.symbolChanges.addListener(_handleDebugChange);
    controller.sourceWorkspaceChanges.addListener(_handleSourceWorkspaceChange);
    controller.sourceToolsChanges.addListener(_handleFirmwareTask);
    if (!widget.readOnlyPreview && widget.visible) {
      controller.setSourceViewVisible(_sourceViewId, true);
    }
    _restoreSourceWorkspace();
    _handleDebugChange();
  }

  @override
  void didUpdateWidget(covariant SourceDebugPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) {
      _hoveredToken = null;
      _hoveredTokenCanNavigate = false;
      _navigationModifierPressed = false;
    }
    if (oldWidget.visible != widget.visible &&
        oldWidget.controller == controller &&
        !widget.readOnlyPreview) {
      controller.setSourceViewVisible(_sourceViewId, widget.visible);
      if (widget.visible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !widget.visible) return;
          controller.dismissSourceAttention();
          if (_selectedPath case final path?) {
            controller.markSourceFileRead(path);
          }
        });
      }
    }
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
    if (!widget.readOnlyPreview && widget.visible) {
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
    _search.cancel();
    _searchController.clear();
    _searchResults = const [];
    _sourceSelection = null;
    _hoveredToken = null;
    _sourcePeek = null;
    _references.cancel();
    _navigationBack.clear();
    _navigationForward.clear();
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
    HardwareKeyboard.instance.removeHandler(_handleNavigationModifier);
    _references.dispose();
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
    _search.dispose();
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
    if (!widget.readOnlyPreview && widget.visible) {
      controller.dismissSourceAttention();
    }
  }

  void _handleSourceWorkspaceChange() {
    if (!mounted) return;
    final nextPath =
        controller.sourceWorkspace.selectedPath ??
        (widget.readOnlyPreview ? _openPaths.firstOrNull : null);
    if (nextPath != _selectedPath || controller.sourceLocationRequest != null) {
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
      _sourcePeek = null;
      _references.cancel();
      _navigationBack.clear();
      _navigationForward.clear();
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
    final request = controller.sourceLocationRequest;
    if (request != null &&
        path != null &&
        controller.sourcePathsMatch(request.path, path)) {
      revealLine = request.line;
      controller.sourceLocationRequest = null;
    }
    if (path != null && !widget.readOnlyPreview && widget.visible) {
      controller.openSourceFile(path);
      path = controller.openSourcePathFor(path) ?? path;
    }
    final generation = ++_loadGeneration;
    setState(() {
      _selectedPath = path;
      _sourceSelection = null;
      _hoveredToken = null;
      _sourcePeek = null;
      _references.cancel();
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
      if (!widget.readOnlyPreview && widget.visible) {
        controller.markSourceFileRead(path);
      }
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
    if (!_searchVisible &&
        event is KeyDownEvent &&
        !event.synthesized &&
        !widget.readOnlyPreview &&
        widget.visible) {
      final keyboard = HardwareKeyboard.instance;
      if (event.logicalKey == LogicalKeyboardKey.escape &&
          _sourcePeek != null) {
        _closeSourcePeek();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.f12 &&
          !keyboard.isControlPressed &&
          !keyboard.isMetaPressed) {
        final selection = _selectedSourceToken;
        if (selection == null) return KeyEventResult.ignored;
        if (keyboard.isShiftPressed && !keyboard.isAltPressed) {
          _openReferences(selection);
        } else if (keyboard.isAltPressed && !keyboard.isShiftPressed) {
          _openDefinitionPeek(selection);
        } else if (!keyboard.isShiftPressed && !keyboard.isAltPressed) {
          unawaited(_goToDefinition(selection));
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      }
      if (!keyboard.isControlPressed &&
          !keyboard.isMetaPressed &&
          !keyboard.isShiftPressed) {
        if (keyboard.isAltPressed &&
            (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.arrowRight)) {
          _navigateHistory(
            back: event.logicalKey == LogicalKeyboardKey.arrowLeft,
          );
          return KeyEventResult.handled;
        }
      }
    }
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
    if (TalDragPreview.debugNativeDrag) {
      debugPrint('Source file drop accepted: ${accepted.length}');
    }
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
    _search.cancel();
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
    _search.cancel();
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
    _search.queue(
      query,
      immediate: immediate,
      getFiles: _getSearchFiles,
      readDocument: _readSearchDocument,
      beforeContents: () => WidgetsBinding.instance.endOfFrame,
      publish: (results, searching) =>
          _publishSearchResults(results, searching: searching),
    );
  }

  void _invalidateSearchFileIndex() => _search.invalidateIndex();

  Future<List<SourceSearchFile>> _getSearchFiles() => _search.files(
    sourcePaths: [..._sourceFiles, ..._openPaths],
    sourceRoot: controller.debugState.sourceRoot,
  );

  Future<SourceSearchText?> _readSearchDocument(SourceSearchFile file) async {
    try {
      return await _readSourceDocument(file.path, localPath: file.localPath);
    } on Object {
      return null;
    }
  }

  void _publishSearchResults(
    List<SourceSearchResult> results, {
    bool searching = true,
  }) {
    if (!mounted) return;
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
    final width = painter.width;
    painter.dispose();
    if (offset.dx > width) return null;
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
    if (!line.identifiers.any(
      (range) => range.start == start && range.end == end,
    )) {
      return null;
    }
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
    _updateSourceSelection(selection);
  }

  void _updateSourceSelection(_SourceTokenSelection? selection) =>
      setState(() => _sourceSelection = selection);

  void _updateSourceView(VoidCallback update) => setState(update);

  bool _handleNavigationModifier(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final pressed =
        widget.visible &&
        !widget.readOnlyPreview &&
        (keyboard.isControlPressed || keyboard.isMetaPressed) &&
        !keyboard.isAltPressed;
    if (mounted && pressed != _navigationModifierPressed) {
      setState(() {
        _navigationModifierPressed = pressed;
        _hoveredTokenCanNavigate =
            pressed &&
            _hoveredToken != null &&
            _definitionsFor(_hoveredToken!).isNotEmpty;
      });
    }
    return false;
  }

  void _hoverSourceToken(String path, int index, Offset position) {
    if (!widget.visible || widget.readOnlyPreview) return;
    final token = _tokenAtOffset(path, index, _lines[index], position);
    if (_hoveredToken?.path == token?.path &&
        _hoveredToken?.lineIndex == token?.lineIndex &&
        _hoveredToken?.start == token?.start) {
      return;
    }
    setState(() {
      _hoveredToken = token;
      _hoveredTokenCanNavigate =
          _navigationModifierPressed &&
          token != null &&
          _definitionsFor(token).isNotEmpty;
    });
  }

  void _exitSourceToken(String path, int index) {
    if (!mounted ||
        _hoveredToken?.path != path ||
        _hoveredToken?.lineIndex != index) {
      return;
    }
    setState(() {
      _hoveredToken = null;
      _hoveredTokenCanNavigate = false;
    });
  }

  List<TextSpan> _spansForSourceLine(String path, int lineIndex) {
    final line = _lines[lineIndex];
    final selection = _sourceSelection;
    final hovered = _hoveredToken;
    return decorateSourceSpans(line.spans, [
      if (selection != null &&
          selection.lineIndex == lineIndex &&
          controller.sourcePathsMatch(selection.path, path))
        (
          start: selection.start,
          end: selection.end,
          style: const TextStyle(backgroundColor: TalColors.selection),
        ),
      if (_navigationModifierPressed &&
          _hoveredTokenCanNavigate &&
          hovered != null &&
          hovered.lineIndex == lineIndex &&
          hovered.path == path)
        (
          start: hovered.start,
          end: hovered.end,
          style: TextStyle(
            color: TalColors.info,
            backgroundColor: TalColors.info.withValues(alpha: .14),
            decoration: TextDecoration.underline,
            decorationColor: TalColors.info,
          ),
        ),
    ]);
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
    final generation = _loadGeneration;
    final hit = _tokenAtOffset(sourcePath, lineIndex, line, localPosition);
    setState(() => _sourceSelection = hit);
    final token = hit?.token;
    final symbols = token == null
        ? const <SymbolItem>[]
        : _symbolsForToken(token, sourcePath);
    final includeName = _includeNameFromLine(line.rawText);
    final includePath = await _resolveIncludedSource(sourcePath, line.rawText);
    if (!context.mounted || generation != _loadGeneration) return;

    final items = <PopupMenuEntry<String>>[];
    if (hit != null) {
      items.add(
        PopupMenuItem<String>(
          key: const ValueKey('source-menu-definition'),
          value: 'definition',
          child: Text('跳转到定义  ${hit.token}    F12'),
        ),
      );
      items.addAll([
        PopupMenuItem<String>(
          key: const ValueKey('source-menu-peek-definition'),
          value: 'peek-definition',
          child: Text('预览定义  ${hit.token}    Alt+F12'),
        ),
        PopupMenuItem<String>(
          key: const ValueKey('source-menu-references'),
          value: 'references',
          child: Text('查看引用  ${hit.token}    Shift+F12'),
        ),
      ]);
    }
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
                ? '${widget.externalOutput ? '已在变量监视中' : '已在实时调试中'}  $symbolLabel$suffix'
                : '${widget.externalOutput ? '加入变量监视' : '加入实时调试'}  $symbolLabel$suffix',
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
    if (action == 'definition' && hit != null) {
      await _goToDefinition(hit);
    } else if (action == 'peek-definition' && hit != null) {
      _openDefinitionPeek(hit);
    } else if (action == 'references' && hit != null) {
      _openReferences(hit);
    } else if (action.startsWith('watch:')) {
      final key = action.substring('watch:'.length);
      if (widget.externalOutput) {
        controller.selectSymbols([key]);
        controller.addSelectedToWatch(mode: WatchReadMode.monitor);
      } else {
        controller.activateSymbol(key);
      }
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
      final peekOffset = _sourcePeek != null && line > _sourcePeek!.anchorLine
          ? _visiblePeekHeight
          : 0.0;
      final target = ((line - 1) * _lineHeight + peekOffset - viewport * 0.38)
          .clamp(0.0, _verticalController.position.maxScrollExtent);
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
    return DragTarget<SourceFileDragData>(
      key: const ValueKey('source-symbol-drop-target'),
      onWillAcceptWithDetails: (_) => !widget.readOnlyPreview && widget.visible,
      onAcceptWithDetails: (details) =>
          _openSource(controller.canonicalSourcePath(details.data.path)),
      builder: (context, candidateData, rejectedData) => PanelKeyboardListener(
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
            onDragDone: (details) {
              if (TalDragPreview.debugNativeDrag) {
                debugPrint(
                  'Source file drop candidates: ${details.files.length}',
                );
              }
              unawaited(
                _openDroppedFiles(details.files.map((file) => file.path)),
              );
            },
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
                      if (!widget.externalOutput)
                        _SourceTaskOutput(
                          controller: controller,
                          maxHeight: constraints.maxHeight < 240
                              ? 34
                              : (constraints.maxHeight * .32).clamp(
                                  85.0,
                                  264.0,
                                ),
                          onOpenLocation: (path, line) {
                            _sourceDocuments.invalidate(path);
                            _openSource(path);
                            unawaited(_loadSource(path, revealLine: line));
                          },
                        ),
                    ],
                  ),
                ),
                if (_draggingFiles || candidateData.isNotEmpty)
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
    final debugControls = <Widget>[
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
                _ =>
                  controller.isGdbMemoryMode ? controller.resumeTarget : null,
              },
      ),
      _DebugToolbarButton(
        key: const ValueKey('debug-step'),
        tooltip: '单条指令步进',
        icon: Icons.skip_next,
        onPressed:
            connected &&
                controller.supportsTargetControl &&
                state == DebugExecutionState.halted
            ? controller.stepTarget
            : null,
      ),
      const SizedBox(width: 8),
      _DebugStateBadge(state: state),
      const SizedBox(width: 12),
    ];
    final navigationControls = <Widget>[
      _DebugToolbarButton(
        key: const ValueKey('source-navigation-back'),
        tooltip: '返回上一位置 (Alt+←)',
        icon: Icons.arrow_back,
        onPressed: _navigationBack.isEmpty
            ? null
            : () => _navigateHistory(back: true),
      ),
      _DebugToolbarButton(
        key: const ValueKey('source-navigation-forward'),
        tooltip: '前往下一位置 (Alt+→)',
        icon: Icons.arrow_forward,
        onPressed: _navigationForward.isEmpty
            ? null
            : () => _navigateHistory(back: false),
      ),
    ];
    final rootPicker = _DebugToolbarButton(
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
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = TalUiTheme.of(context);
        final debugHeight = theme.targetExtent(42);
        final navigationHeight = theme.targetExtent(36);
        if (constraints.maxWidth >= 480) {
          return SizedBox(
            height: debugHeight,
            child: Row(
              children: [
                ...debugControls,
                ...navigationControls,
                Expanded(child: _buildSourceTabs()),
                rootPicker,
                const SizedBox(width: 8),
              ],
            ),
          );
        }
        return SizedBox(
          height: debugHeight + navigationHeight,
          child: Column(
            children: [
              SizedBox(
                height: debugHeight,
                child: Row(
                  children: [
                    ...debugControls,
                    const Spacer(),
                    rootPicker,
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              SizedBox(
                height: navigationHeight,
                child: Row(
                  children: [
                    ...navigationControls,
                    Expanded(child: _buildSourceTabs()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
                          child: SourceUnreadDot(
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
            : '请加载带 DWARF 调试信息的 ELF / AXF 文件',
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
        final peek = _sourcePeek;
        final peekIndex = peek?.anchorLine.clamp(1, _lines.length);
        _visiblePeekHeight =
            (_sourcePeekHeight ??
                    (constraints.maxHeight * .62).clamp(180.0, 320.0))
                .clamp(150.0, 520.0);
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
                  itemExtent: peek == null ? _lineHeight : null,
                  itemExtentBuilder: peek == null
                      ? null
                      : (index, _) => index == peekIndex
                            ? _visiblePeekHeight
                            : _lineHeight,
                  itemCount: _lines.length + (peek == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (peek != null && index == peekIndex) {
                      return _buildSourcePeek(
                        constraints.maxWidth,
                        contentWidth,
                      );
                    }
                    return _buildSourceLine(
                      peekIndex != null && index > peekIndex
                          ? index - 1
                          : index,
                    );
                  },
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
          ? TalColors.selection
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
                      color: TalColors.accent,
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
                  ? TalColors.surfaceAlt
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
                                    ? TalColors.error
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
                              ? TalColors.muted
                              : TalColors.disabled,
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
            child: MouseRegion(
              key: ValueKey('source-mouse-line-$lineNumber'),
              cursor:
                  _navigationModifierPressed &&
                      _hoveredTokenCanNavigate &&
                      _hoveredToken?.lineIndex == index
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.text,
              onEnter: (event) =>
                  _hoverSourceToken(path, index, event.localPosition),
              onHover: (event) =>
                  _hoverSourceToken(path, index, event.localPosition),
              onExit: (_) => _exitSourceToken(path, index),
              child: Listener(
                onPointerDown: (event) {
                  if (event.buttons != kPrimaryMouseButton) return;
                  final keyboard = HardwareKeyboard.instance;
                  _sourceTapWithModifier =
                      keyboard.isControlPressed || keyboard.isMetaPressed;
                  _selectSourceToken(path, index, event.localPosition);
                },
                child: GestureDetector(
                  key: ValueKey('source-line-$lineNumber'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (_) {
                    final selection = _selectedSourceToken;
                    if (_sourceTapWithModifier && selection != null) {
                      unawaited(_goToDefinition(selection));
                    }
                  },
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
