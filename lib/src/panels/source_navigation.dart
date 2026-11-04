part of 'source_debug_panel.dart';

typedef _SourceNavigationLocation = ({
  String path,
  int line,
  double horizontalOffset,
  _SourceTokenSelection? selection,
});

extension _SourceNavigation on _SourceDebugPanelState {
  _SourceTokenSelection? get _selectedSourceToken {
    final selection = _sourceSelection;
    return selection != null &&
            _selectedPath != null &&
            controller.sourcePathsMatch(selection.path, _selectedPath!)
        ? selection
        : null;
  }

  List<SourceDefinition> _definitionsFor(_SourceTokenSelection selection) =>
      findSourceDefinitions(
        controller.debugState.sourceDefinitions,
        selection.token,
        isCurrentFile: (path) =>
            controller.sourcePathsMatch(path, selection.path),
      );

  Future<void> _goToDefinition(_SourceTokenSelection selection) async {
    if (widget.readOnlyPreview ||
        !widget.visible ||
        _selectedPath == null ||
        !controller.sourcePathsMatch(selection.path, _selectedPath!)) {
      return;
    }
    final definitions = _definitionsFor(selection);
    if (definitions.isEmpty) {
      final message = !controller.debugState.hasSourceDefinitionIndex
          ? controller.firmwarePath.isEmpty
                ? '请先加载带调试信息的 ELF / AXF，再跳转到定义。'
                : '当前后端尚未提供源码定义索引，请重启完整新版应用后刷新符号文件。'
          : '未找到 ${selection.token} 的定义，请确认已加载包含该定义调试信息的 ELF / AXF。';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
      return;
    }
    if (definitions.length > 1) {
      _openDefinitionPeek(selection);
      return;
    }
    final definition = definitions.single;
    await _navigateToCodeLocation(
      SourceCodeLocation(path: definition.path, line: definition.line),
    );
  }

  _SourceNavigationLocation? _captureNavigationLocation() {
    final path = _selectedPath;
    if (path == null) return null;
    final selection = _selectedSourceToken;
    return (
      path: path,
      line: selection != null
          ? selection.lineIndex + 1
          : _revealedSearchLine ??
                ((_verticalController.hasClients
                                ? _verticalController.offset
                                : 0) /
                            _SourceDebugPanelState._lineHeight)
                        .floor() +
                    1,
      horizontalOffset: _horizontalController.hasClients
          ? _horizontalController.offset
          : 0,
      selection: selection,
    );
  }

  void _navigateHistory({required bool back}) {
    final location = _navigation.travel(
      back: back,
      current: _captureNavigationLocation(),
    );
    if (location != null) unawaited(_revealNavigationLocation(location));
  }

  Future<void> _revealNavigationLocation(
    _SourceNavigationLocation location,
  ) async {
    final loading = _loadSource(location.path, revealLine: location.line);
    final generation = _loadGeneration;
    await loading;
    if (!mounted ||
        generation != _loadGeneration ||
        _selectedPath == null ||
        !controller.sourcePathsMatch(_selectedPath!, location.path)) {
      return;
    }
    _updateSourceSelection(location.selection);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          !_horizontalController.hasClients) {
        return;
      }
      _horizontalController.jumpTo(
        location.horizontalOffset.clamp(
          0.0,
          _horizontalController.position.maxScrollExtent,
        ),
      );
    });
    _restorePanelFocus();
  }
}
