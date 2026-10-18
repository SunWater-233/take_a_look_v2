import 'dart:async';
import 'dart:io';

import 'project_document.dart';
import 'workspace_layout.dart';

/// Serializes writes and owns restore generations and project-file operations.
/// UI lifecycle checks and application of loaded state remain with the caller.
class WorkspacePersistence {
  WorkspacePersistence({required this.layoutRepository});

  final WorkspaceLayoutRepository Function() layoutRepository;
  Timer? _saveTimer;
  Future<void> _writeQueue = Future<void>.value();
  int _restoreRevision = 0;
  bool _projectBusy = false;
  bool _disposed = false;
  String? _projectPath;

  String? get projectPath => _projectPath;
  bool get hasPendingSave => _saveTimer?.isActive == true;

  void scheduleLayoutSave(Future<void> Function() save) {
    if (_disposed) return;
    cancelPendingSave();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_disposed) unawaited(save());
    });
  }

  void cancelPendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  Future<void> saveLayout(WorkspaceLayoutSnapshot layout) {
    cancelPendingSave();
    // Freeze before joining the queue: subsequent gestures cannot change a
    // snapshot whose write is waiting behind an earlier filesystem operation.
    final snapshot = WorkspaceLayoutSnapshot.fromJson(layout.toJson());
    final repository = layoutRepository();
    _writeQueue = _writeQueue
        .catchError((Object _) {})
        .then((_) => repository.save(snapshot));
    return _writeQueue;
  }

  Future<void> restoreLayout(
    void Function(WorkspaceLayoutSnapshot? layout) apply,
  ) async {
    final revision = ++_restoreRevision;
    final layout = await layoutRepository().load();
    if (!_disposed && revision == _restoreRevision) apply(layout);
  }

  Future<String?> saveProject({
    required Future<String?> Function() pickPath,
    required ProjectDocument Function() capture,
    required bool Function() isActive,
    bool saveAs = false,
  }) async {
    if (_projectBusy || _disposed) return null;
    _projectBusy = true;
    try {
      var path = saveAs ? null : _projectPath;
      path ??= await pickPath();
      if (path == null || path.isEmpty || !_active(isActive)) return null;
      if (!path.toLowerCase().endsWith('.talproj')) path = '$path.talproj';
      await capture().write(File(path));
      if (!_active(isActive)) return null;
      _projectPath = path;
      return path;
    } finally {
      _projectBusy = false;
    }
  }

  Future<String?> openProject({
    required Future<String?> Function() pickPath,
    required Future<bool> Function(ProjectDocument document) apply,
    required bool Function() isActive,
  }) async {
    if (_projectBusy || _disposed) return null;
    _projectBusy = true;
    try {
      final path = await pickPath();
      if (path == null || path.isEmpty || !_active(isActive)) return null;
      // Parsing validates the entire document before changing application state.
      final document = await ProjectDocument.read(File(path));
      if (!_active(isActive)) return null;
      _restoreRevision++;
      if (!await apply(document) || !_active(isActive)) return null;
      _projectPath = path;
      return path;
    } finally {
      _projectBusy = false;
    }
  }

  bool _active(bool Function() isActive) => !_disposed && isActive();

  void dispose() {
    _disposed = true;
    _restoreRevision++;
    cancelPendingSave();
  }
}
