part of 'controller.dart';

extension TakeALookControllerSourceWorkspace on TakeALookController {
  SourceWorkspaceState get sourceWorkspace => state.sourceWorkspace;
  bool get isSourceDebugVisible => _visibleSourceViews.isNotEmpty;

  String canonicalSourcePath(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    final candidates = <String>{
      ...debugState.sourceFiles,
      ...debugState.executableLines.keys,
    };
    final exact = candidates
        .where(
          (candidate) =>
              _sourcePathKey(candidate) == _sourcePathKey(normalized),
        )
        .firstOrNull;
    if (exact != null) return exact;
    final basename = normalized.split('/').last.toLowerCase();
    final matches = candidates
        .where(
          (candidate) => _sourcePathKey(candidate).split('/').last == basename,
        )
        .toList();
    return matches.length == 1 ? matches.single : normalized;
  }

  String? openSourcePathFor(String path) {
    final exactKey = _sourcePathKey(path);
    final exact = sourceWorkspace.openPaths
        .where((candidate) => _sourcePathKey(candidate) == exactKey)
        .firstOrNull;
    if (exact != null) return exact;
    final key = _sourcePathKey(canonicalSourcePath(path));
    return sourceWorkspace.openPaths.where((candidate) {
      return _sourcePathKey(canonicalSourcePath(candidate)) == key;
    }).firstOrNull;
  }

  bool isSourceFileOpen(String path) => openSourcePathFor(path) != null;

  bool isSourceFileUnread(String path) {
    final opened = openSourcePathFor(path);
    return opened != null && sourceWorkspace.unreadPaths.contains(opened);
  }

  void setSourceViewVisible(String viewId, bool visible) {
    if (_disposed) return;
    final changed = visible
        ? _visibleSourceViews.add(viewId)
        : _visibleSourceViews.remove(viewId);
    if (changed && _isDetachedRemote) {
      _dispatchRemote(ControllerCommand.setSourceViewVisible, {
        'viewId': viewId,
        'visible': visible,
      });
    }
  }

  void removeSourceViewsForWindow(String windowId) {
    _visibleSourceViews.removeWhere(
      (view) => view.startsWith('window:$windowId:'),
    );
  }

  void addSourceFileFromSymbols(String path) {
    if (path.trim().isEmpty || path == '未知来源' || isSourceFileOpen(path)) {
      return;
    }
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.addSourceFile, path);
      return;
    }
    final source = canonicalSourcePath(path);
    sourceWorkspace.openPaths.add(source);
    sourceWorkspace.additionRevision++;
    if (isSourceDebugVisible) {
      sourceWorkspace.selectedPath = source;
    } else {
      sourceWorkspace.unreadPaths.add(source);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (sourceWorkspace.attentionUntilMs > now) {
        // Extend at a cycle boundary without stacking or restarting pulses.
        final elapsed = now - sourceWorkspace.attentionStartedAtMs;
        sourceWorkspace.attentionUntilMs =
            sourceWorkspace.attentionStartedAtMs +
            ((elapsed / 1400).ceil() + 3) * 1400;
      } else {
        sourceWorkspace.attentionStartedAtMs = now;
        sourceWorkspace.attentionUntilMs = now + 4200;
      }
    }
    _notifySourceWorkspace();
  }

  void openSourceFile(String path, {bool select = true}) {
    if (path.trim().isEmpty) return;
    final existing = openSourcePathFor(path);
    final source = existing ?? path;
    final changed =
        existing == null ||
        (select &&
            (sourceWorkspace.selectedPath != source ||
                sourceWorkspace.viewedStopRevision != debugState.stopRevision));
    if (!changed) return;
    if (existing == null) sourceWorkspace.openPaths.add(source);
    if (select) {
      sourceWorkspace.selectedPath = source;
      sourceWorkspace.viewedStopRevision = debugState.stopRevision;
    }
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.openSourceFile, {
        'path': path,
        'select': select,
      });
    }
    _notifySourceWorkspace();
  }

  void markSourceFileRead(String path) {
    final source = openSourcePathFor(path);
    if (source == null || !sourceWorkspace.unreadPaths.remove(source)) return;
    if (sourceWorkspace.unreadPaths.isEmpty) {
      sourceWorkspace.attentionStartedAtMs = 0;
      sourceWorkspace.attentionUntilMs = 0;
    }
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.markSourceFileRead, source);
    }
    _notifySourceWorkspace();
  }

  void closeSourceFile(String path) {
    final source = openSourcePathFor(path);
    if (source == null) return;
    final index = sourceWorkspace.openPaths.indexOf(source);
    sourceWorkspace.openPaths.removeAt(index);
    sourceWorkspace.unreadPaths.remove(source);
    if (sourceWorkspace.selectedPath == source) {
      sourceWorkspace.selectedPath = sourceWorkspace.openPaths.isEmpty
          ? null
          : sourceWorkspace.openPaths[math.min(
              index,
              sourceWorkspace.openPaths.length - 1,
            )];
    }
    if (sourceWorkspace.unreadPaths.isEmpty) {
      sourceWorkspace.attentionStartedAtMs = 0;
      sourceWorkspace.attentionUntilMs = 0;
    }
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.closeSourceFile, source);
    }
    _notifySourceWorkspace();
  }

  void dismissSourceAttention() {
    if (_disposed || sourceWorkspace.attentionUntilMs == 0) return;
    sourceWorkspace.attentionStartedAtMs = 0;
    sourceWorkspace.attentionUntilMs = 0;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.dismissSourceAttention);
    }
    _notifySourceWorkspace();
  }

  void _notifySourceWorkspace() {
    if (_disposed || _sourceWorkspaceNotificationPending) return;
    _sourceWorkspaceNotificationPending = true;
    // Source widgets may restore their selection during mounting. Notify after
    // the current build, and coalesce selection/read changes into one snapshot.
    scheduleMicrotask(() {
      _sourceWorkspaceNotificationPending = false;
      if (!_disposed) _emitState([signals.sourceWorkspace]);
    });
  }
}

String _sourcePathKey(String path) => path.replaceAll('\\', '/').toLowerCase();
