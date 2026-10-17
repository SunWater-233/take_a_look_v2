part of 'controller.dart';

extension TakeALookControllerSourceTools on TakeALookController {
  SourceProjectConfig get sourceProject => state.sourceProject;
  SourceTaskState get sourceTask => state.sourceTask;

  Future<void> saveSourceProject(Map<String, dynamic> values) async {
    if (_isDetachedRemote) {
      await remoteCommand!(ControllerCommand.setSourceProject, values);
    } else if (backendCommand != null) {
      await backendCommand!(ControllerCommand.setSourceProject, values);
    } else {
      sourceProject.applyJson(values);
      debugState.sourceRoot = sourceProject.sourceRoot;
      _emitState([signals.sourceTools, signals.debug]);
    }
  }

  Future<void> loadSourceProjectSymbols() async {
    if (_disposed || kIsWeb) return;
    var path = sourceProject.firmwarePath.trim();
    if (path.isEmpty) return;
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      final homeDirectory =
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      if (homeDirectory != null) path = '$homeDirectory${path.substring(1)}';
    }
    final file = File.fromUri(
      Directory(
        sourceProject.sourceRoot,
      ).absolute.uri.resolveUri(File(path).uri).normalizePath(),
    );
    String pathKey(String value) {
      final normalized = File(value).absolute.uri.normalizePath().toFilePath();
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    if (symbolFile.isNotEmpty && pathKey(symbolFile) == pathKey(file.path)) {
      return;
    }
    // A build output may not exist yet; keep that configuration usable.
    if (!await file.exists() || _disposed) return;
    await loadSymbolsFromPath(file.path);
  }

  Future<void> startSourceTask(String kind) async {
    if (sourceTask.running) return;
    try {
      final sender = remoteCommand ?? backendCommand;
      if (sender == null) {
        throw const BackendException(
          'backend_unavailable',
          '请启动本机后端后再执行编译或下载。',
        );
      }
      await sender(ControllerCommand.startSourceTask, {'kind': kind});
    } on Object catch (error) {
      applyBackendEvent(BackendEventType.error, {
        'code': error is BackendException ? error.code : 'source_task_failed',
        'operation': 'sourceTask',
        'message': error is BackendException ? error.message : error.toString(),
        if (error is BackendException && error.details != null)
          'details': error.details,
      });
    }
  }

  Future<void> cancelSourceTask() async {
    try {
      await (remoteCommand ?? backendCommand)?.call(
        ControllerCommand.cancelSourceTask,
        null,
      );
    } on Object catch (error) {
      applyBackendEvent(BackendEventType.error, {
        'code': 'source_cancel_failed',
        'message': error.toString(),
      });
    }
  }

  void clearSourceOutput() {
    if (_dispatchRemote(ControllerCommand.clearSourceOutput)) return;
    sourceTask.clearOutput();
    _emitState([signals.sourceTools]);
  }

  void applySourceTask(Map<String, dynamic> data) {
    final previousId = sourceTask.id;
    final previousStatus = sourceTask.status;
    sourceTask.applyJson(data);
    if (sourceTask.status == 'failed' &&
        (sourceTask.id != previousId || previousStatus != 'failed')) {
      applyBackendEvent(BackendEventType.error, {
        'code': 'source_task_failed',
        'operation': 'sourceTask',
        'message': sourceTask.message.isEmpty
            ? '编译或下载失败，请查看输出。'
            : sourceTask.message,
      });
    }
    _emitState([signals.sourceTools]);
  }
}
