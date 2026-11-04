part of 'controller.dart';

extension TakeALookControllerFreeRtos on TakeALookController {
  Future<JsonObject> requestFreeRtos(
    String operation,
    JsonObject arguments,
  ) async {
    final request = freeRtosRequest;
    if (request == null) throw StateError('当前会话未提供 FreeRTOS 上下文读取。');
    return request(operation, arguments);
  }

  void refreshFreeRtos() => _scheduleFreeRtosConfig();
  FreeRtosSnapshot get freeRtos => state.freeRtos;
  Map<String, dynamic> get freeRtosSettings =>
      Map.unmodifiable(state.freeRtosSettings);

  void setFreeRtosViewVisible(String viewId, bool visible) {
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.setFreeRtosViewVisible, {
        'viewId': viewId,
        'visible': visible,
      });
      return;
    }
    final changed = visible
        ? _freeRtosViews.add(viewId)
        : _freeRtosViews.remove(viewId);
    if (changed) _scheduleFreeRtosConfig();
  }

  void releaseFreeRtosViewsForWindow(String windowId) {
    _freeRtosViews.removeWhere((id) => id.startsWith('window:$windowId:'));
    _scheduleFreeRtosConfig();
  }

  void _scheduleFreeRtosConfig() {
    if (_freeRtosConfigPending || _disposed) return;
    _freeRtosConfigPending = true;
    scheduleMicrotask(() {
      _freeRtosConfigPending = false;
      if (_disposed) return;
      _dispatchCommand(ControllerCommand.configureFreeRtos, {
        'enabled': _freeRtosViews.isNotEmpty,
        'rateHz': state.freeRtosSettings['rateHz'] ?? 2,
        'tickHz': state.freeRtosSettings['tickHz'],
      });
    });
  }

  void setFreeRtosSettings(Map<String, dynamic> settings) {
    if (_dispatchRemote(ControllerCommand.setFreeRtosSettings, settings)) {
      return;
    }
    final next = {...state.freeRtosSettings, ...settings};
    final rate = next['rateHz'];
    final tick = next['tickHz'];
    final threshold = next['stackWarningPercent'];
    if (rate is! num ||
        !rate.isFinite ||
        rate < 1 ||
        rate > 5 ||
        (tick != null && (tick is! int || tick < 1 || tick > 1000000)) ||
        threshold is! num ||
        !threshold.isFinite ||
        threshold < 0 ||
        threshold > 100) {
      throw const FormatException('FreeRTOS 刷新或阈值设置无效。');
    }
    if (!const {
          'tasks',
          'objects',
          'memory',
          'timers',
          'diagnostics',
        }.contains(next['page']) ||
        next['search'] is! String ||
        (next['search'] as String).length > 256 ||
        !const {'', 'cpu', 'stack'}.contains(next['sort']) ||
        next['objectFilter'] is! String ||
        next['columns'] is! Map) {
      throw const FormatException('FreeRTOS 布局设置无效。');
    }
    for (final entry in (next['columns'] as Map).entries) {
      if (entry.key is! String ||
          entry.value is! num ||
          !(entry.value as num).isFinite ||
          (entry.value as num) < 64 ||
          (entry.value as num) > 600) {
        throw const FormatException('FreeRTOS 列宽设置无效。');
      }
    }
    for (final key in [
      'selectedTask',
      'selectedTaskNumber',
      'selectedObject',
      'selectedTimer',
    ]) {
      if (next[key] != null && (next[key] is! int || (next[key] as int) < 0)) {
        throw const FormatException('FreeRTOS 选择设置无效。');
      }
    }
    final samplingChanged =
        state.freeRtosSettings['rateHz'] != rate ||
        state.freeRtosSettings['tickHz'] != tick;
    state.freeRtosSettings = next;
    if (samplingChanged) _scheduleFreeRtosConfig();
    _emitState([signals.freeRtos]);
  }

  void addFreeRtosWatch(int handle, String field) {
    _dispatchCommand(ControllerCommand.addFreeRtosWatch, {
      'handle': handle,
      'field': field,
    });
  }
}
