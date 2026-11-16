part of 'controller.dart';

extension TakeALookControllerSourceTools on TakeALookController {
  SourceProjectConfig get sourceProject => state.sourceProject;
  SourceTaskState get sourceTask => state.sourceTask;

  Future<void> saveSourceProject(Map<String, dynamic> values) async {
    if (_isDetachedRemote) {
      await remoteCommand!(ControllerCommand.setSourceProject, values);
    } else if (backendCommand != null) {
      if (isSymbolLoading) {
        throw const BackendException('firmware_busy', '请等待当前固件加载完成。');
      }
      if (!values.containsKey('firmwarePath')) {
        await backendCommand!(ControllerCommand.setSourceProject, values);
        return;
      }
      await _runFirmwareCommand(
        ControllerCommand.setSourceProject,
        values,
        values['firmwarePath'] as String? ?? firmwarePath,
        propagateFailure: true,
      );
    } else {
      sourceProject.applyJson(values);
      _emitState([signals.sourceTools, signals.debug]);
    }
  }

  Future<void> startSourceTask(String kind) async {
    if (sourceTask.running || _restoringProject) return;
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
