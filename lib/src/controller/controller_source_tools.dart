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
        'code': 'source_task_failed',
        'message': error.toString(),
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
    sourceTask.applyJson(data);
    _emitState([signals.sourceTools]);
  }
}
