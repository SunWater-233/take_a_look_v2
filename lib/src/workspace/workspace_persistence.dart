import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'project_document.dart';
import 'workspace_layout.dart';

/// Serializes writes and owns restore generations and project-file operations.
/// UI lifecycle checks and application of loaded state remain with the caller.
class WorkspacePersistence {
  WorkspacePersistence({required this.layoutRepository});

  static const _recentProjectLimit = 10;

  final WorkspaceLayoutRepository Function() layoutRepository;
  final _recentProjects = ValueNotifier<List<String>>(const []);
  Future<void>? _recentProjectsLoad;
  Timer? _saveTimer;
  Future<void> _writeQueue = Future<void>.value();
  int _restoreRevision = 0;
  bool _projectBusy = false;
  bool _disposed = false;
  String? _projectPath;

  String? get projectPath => _projectPath;
  void restoreProjectPath(String? path) => _projectPath = path;
  bool get hasPendingSave => _saveTimer?.isActive == true;

  ValueListenable<List<String>> get recentProjects {
    unawaited(_initializeRecentProjects());
    return _recentProjects;
  }

  File get _recentProjectsFile =>
      File(p.join(layoutRepository().file.parent.path, 'recent-projects.json'));

  Future<void> _initializeRecentProjects() =>
      _recentProjectsLoad ??= _loadRecentProjects();

  Future<void> _loadRecentProjects() async {
    try {
      final file = _recentProjectsFile;
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (_disposed || data is! List) return;
      _recentProjects.value = List.unmodifiable(
        data.whereType<String>().where(p.isAbsolute).take(_recentProjectLimit),
      );
    } on FileSystemException {
      // The history is optional when the settings directory is inaccessible.
    } on FormatException {
      // A damaged history can be replaced after the next successful open.
    }
  }

  Future<void> _recordRecentProject(String path) async {
    await _initializeRecentProjects();
    if (_disposed) return;
    final absolutePath = p.normalize(p.absolute(path));
    final paths = List<String>.unmodifiable(
      [
        absolutePath,
        ..._recentProjects.value.where(
          (entry) => !p.equals(entry, absolutePath),
        ),
      ].take(_recentProjectLimit),
    );
    _recentProjects.value = paths;

    final file = _recentProjectsFile;
    final temporary = File('${file.path}.$pid.tmp');
    try {
      await file.parent.create(recursive: true);
      try {
        await temporary.writeAsString(jsonEncode(paths), flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    } on FileSystemException {
      // Keep the current session's history available even if the write fails.
    }
  }

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

  Future<bool> createProject({
    required Future<void> Function() reset,
    required bool Function() isActive,
  }) async {
    if (_projectBusy || !_active(isActive)) return false;
    _projectBusy = true;
    try {
      await reset();
      if (!_active(isActive)) return false;
      _projectPath = null;
      return true;
    } finally {
      _projectBusy = false;
    }
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
      await _recordRecentProject(path);
      return _active(isActive) ? path : null;
    } finally {
      _projectBusy = false;
    }
  }

  bool _active(bool Function() isActive) => !_disposed && isActive();

  void dispose() {
    _disposed = true;
    _restoreRevision++;
    cancelPendingSave();
    _recentProjects.dispose();
  }
}
