import 'dart:async';

import 'package:flutter/painting.dart';

import 'panel_types.dart';

/// Gesture state and dwell deadlines, independent of widgets and native windows.
class WorkspaceTabDragSession {
  WorkspaceTabDragSession({required this.onChanged});

  static const dwell = Duration(milliseconds: 300);
  final VoidCallback onChanged;
  Timer? _mergeTimer;
  Timer? _dockTimer;
  bool _disposed = false;

  String? _sourceGroupId;
  String? _sourceWindowId;
  WorkspacePanelId? _detachedPanel;
  Offset? localPosition;
  String? _mergeCandidate;
  String? _armedMergeTarget;
  String? _highlightedGroupId;
  WorkspaceDockEdge? _dockCandidate;
  bool _dockArmed = false;
  bool _cancelled = false;

  String? get sourceGroupId => _sourceGroupId;
  WorkspacePanelId? get detachedPanel => _detachedPanel;
  String? get mergeCandidate => _mergeCandidate;
  String? get armedMergeTarget => _armedMergeTarget;
  String? get highlightedGroupId => _highlightedGroupId;
  WorkspaceDockEdge? get dockCandidate => _dockCandidate;
  bool get dockArmed => _dockArmed;
  bool get cancelled => _cancelled;

  void beginLocal(String groupId) {
    reset(notify: false);
    _sourceGroupId = groupId;
    _notify();
  }

  void beginDetached(String windowId, WorkspacePanelId panel) {
    reset(notify: false);
    _sourceWindowId = windowId;
    _detachedPanel = panel;
    _notify();
  }

  bool matchesDetached(String windowId, WorkspacePanelId panel) =>
      _sourceWindowId == windowId && _detachedPanel == panel;

  void setDockCandidate(WorkspaceDockEdge? edge) {
    if (_disposed || _cancelled || _dockCandidate == edge) return;
    _dockTimer?.cancel();
    _dockCandidate = edge;
    _dockArmed = false;
    if (edge != null) {
      _clearMerge();
      _dockTimer = Timer(dwell, () {
        if (_disposed || _cancelled || _dockCandidate != edge) return;
        _dockArmed = true;
        _notify();
      });
    }
    _notify();
  }

  void setMergeCandidate(String? groupId) {
    if (_disposed || _cancelled || _mergeCandidate == groupId) return;
    _clearMerge();
    _mergeCandidate = groupId;
    if (groupId != null) {
      _mergeTimer = Timer(dwell, () {
        if (_disposed || _cancelled || _mergeCandidate != groupId) return;
        _armedMergeTarget = groupId;
        _highlightedGroupId = groupId;
        _notify();
      });
    }
    _notify();
  }

  /// Detached-window drops retain their existing immediate group highlight.
  void highlightDetachedGroup(String? groupId) {
    if (_disposed || _cancelled || _highlightedGroupId == groupId) return;
    _highlightedGroupId = groupId;
    _notify();
  }

  void cancel() {
    _cancelled = true;
    _clearTargets();
    _notify();
  }

  void reset({bool notify = true}) {
    _clearTargets();
    _sourceGroupId = null;
    _sourceWindowId = null;
    _detachedPanel = null;
    localPosition = null;
    _cancelled = false;
    if (notify) _notify();
  }

  void _clearMerge() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _mergeCandidate = null;
    _armedMergeTarget = null;
    _highlightedGroupId = null;
  }

  void _clearTargets() {
    _clearMerge();
    _dockTimer?.cancel();
    _dockTimer = null;
    _dockCandidate = null;
    _dockArmed = false;
  }

  void _notify() {
    if (!_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    _clearTargets();
  }
}
