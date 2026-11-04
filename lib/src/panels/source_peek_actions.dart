part of 'source_debug_panel.dart';

class _SourcePeekSession {
  _SourcePeekSession({
    required this.kind,
    required this.token,
    required this.anchorLine,
    this.locations = const [],
    this.searching = false,
  });
  final SourcePeekKind kind;
  final String token;
  final int anchorLine;
  List<SourceCodeLocation> locations;
  bool searching;
  bool truncated = false;
  int unreadableFiles = 0;
}

extension _SourcePeekActions on _SourceDebugPanelState {
  bool _canPeekSource(_SourceTokenSelection selection) =>
      widget.visible &&
      !widget.readOnlyPreview &&
      _selectedPath != null &&
      controller.sourcePathsMatch(selection.path, _selectedPath!);

  void _openDefinitionPeek(_SourceTokenSelection selection) {
    if (!_canPeekSource(selection)) return;
    final definitions = _definitionsFor(selection);
    if (definitions.isEmpty) {
      unawaited(_goToDefinition(selection));
      return;
    }
    _references.cancel();
    _updateSourceView(
      () => _sourcePeek = _SourcePeekSession(
        kind: SourcePeekKind.definitions,
        token: selection.token,
        anchorLine: selection.lineIndex + 1,
        locations: [
          for (final definition in definitions)
            SourceCodeLocation(
              path: definition.path,
              line: definition.line,
              label:
                  '${definition.qualifiedName}  ${definition.kindLabel}${definition.isDeclaration ? '声明' : ''}',
            ),
        ],
      ),
    );
    _revealSourcePeek();
  }

  void _openReferences(_SourceTokenSelection selection) {
    if (!_canPeekSource(selection)) return;
    final session = _SourcePeekSession(
      kind: SourcePeekKind.references,
      token: selection.token,
      anchorLine: selection.lineIndex + 1,
      searching: true,
    );
    _updateSourceView(() => _sourcePeek = session);
    _revealSourcePeek();
    unawaited(
      _references.search(
        selection.token,
        sourceRoot: controller.sourceProject.sourceRoot,
        currentPath: selection.path,
        getFiles: _getSearchFiles,
        publish: (results) {
          if (!mounted || _sourcePeek != session) return;
          _updateSourceView(() {
            session.locations = results.locations;
            session.searching = results.searching;
            session.truncated = results.truncated;
            session.unreadableFiles = results.unreadableFiles;
          });
        },
      ),
    );
  }

  void _closeSourcePeek() {
    final session = _sourcePeek;
    _references.cancel();
    _updateSourceView(() => _sourcePeek = null);
    if (session != null) _scrollToLine(session.anchorLine, immediate: true);
    _restorePanelFocus();
  }

  void _revealSourcePeek() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sourcePeek == null || !_verticalController.hasClients) {
        return;
      }
      final offset =
          _sourcePeek!.anchorLine * _SourceDebugPanelState._lineHeight -
          _verticalController.position.viewportDimension * .15;
      _verticalController.jumpTo(
        offset.clamp(0.0, _verticalController.position.maxScrollExtent),
      );
    });
  }

  Widget _buildSourcePeek(double viewportWidth, double contentWidth) {
    final session = _sourcePeek!;
    return SizedBox(
      width: contentWidth,
      height: _visiblePeekHeight,
      child: Align(
        alignment: Alignment.topLeft,
        child: AnimatedBuilder(
          animation: _horizontalController,
          builder: (context, child) => Transform.translate(
            offset: Offset(
              _horizontalController.hasClients
                  ? _horizontalController.offset
                  : 0,
              0,
            ),
            child: child,
          ),
          child: SizedBox(
            width: viewportWidth,
            height: _visiblePeekHeight,
            child: SourcePeekPanel(
              key: ObjectKey(session),
              kind: session.kind,
              interactive: widget.visible && !widget.readOnlyPreview,
              token: session.token,
              locations: session.locations,
              searching: session.searching,
              truncated: session.truncated,
              unreadableFiles: session.unreadableFiles,
              documents: _sourceDocuments,
              highlighter: _highlighter,
              sourceRoot: controller.sourceProject.sourceRoot,
              onClose: _closeSourcePeek,
              onOpen: (location) =>
                  unawaited(_navigateToCodeLocation(location)),
              onResize: (delta) => _updateSourceView(() {
                _sourcePeekHeight = (_visiblePeekHeight + delta).clamp(
                  150.0,
                  520.0,
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _navigateToCodeLocation(SourceCodeLocation location) async {
    if (!widget.visible || widget.readOnlyPreview) return;
    final origin = _captureNavigationLocation();
    if (origin != null) {
      _navigation.record(origin);
    }
    await _revealNavigationLocation((
      path: location.path,
      line: location.line,
      horizontalOffset: 0,
      selection: null,
    ));
  }
}
