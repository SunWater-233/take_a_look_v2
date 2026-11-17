part of 'controller.dart';

extension TakeALookControllerFirmware on TakeALookController {
  bool get firmwareRequiresDownload =>
      state.firmware['requiresDownload'] == true;

  bool get sourceDebugConfigured =>
      hasFirmwareSymbols && sourceProject.sourceRoot.trim().isNotEmpty;

  String? get firmwareNotice => firmwareRequiresDownload
      ? '固件已变化，符号已自动刷新；请重新下载后继续采样或源码调试。'
      : switch (state.firmware['status']) {
          'missing' => '固件文件尚未生成，请编译或选择文件。',
          'unloaded' => '编译已完成，请下载或刷新符号。',
          'stale' => '固件已重新编译，当前保留编译前的符号，请下载或刷新。',
          _ => null,
        };

  void loadDemoSymbols() {
    if (_dispatchRemote(ControllerCommand.loadFirmware)) return;
    sourceProject.firmwarePath = 'motor_control_release.axf';
    state.firmware = {'status': 'ready', 'revision': 1, 'fingerprint': 'demo'};
    _replaceSymbols(demoSymbols);
    _selectedSymbols.clear();
    _appendLog('已读取符号文件：$firmwarePath，变量符号 ${_symbols.length} 个。');
    _emitState([signals.symbols, signals.logs]);
  }

  void _replaceSymbols(Iterable<SymbolItem> symbols) {
    final next = symbols.toList(growable: false);
    if (_symbols.length == next.length) {
      var unchanged = true;
      for (var index = 0; index < next.length; index += 1) {
        final current = _symbols[index];
        final replacement = next[index];
        if (!current.hasSameDefinition(replacement)) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return;
    }
    final hierarchy = SymbolHierarchy(next);
    final replacements = <String, SymbolItem>{
      for (final symbol in _symbols)
        if (_symbolHierarchy.resolve(symbol)?.key == symbol.key)
          if (hierarchy.resolve(symbol) case final SymbolItem replacement)
            symbol.key: replacement,
    };
    _watchRegistry.rebindSymbols(replacements, hierarchy);
    _rekeySymbolSet(_selectedSymbols, replacements);
    _rekeySymbolMap(_frozenPlotSamples, replacements);
    final visibility = state.plot.visibilityBeforeIsolation;
    if (visibility != null) _rekeySymbolMap(visibility, replacements);
    state.plot.highlightedWatchKey =
        replacements[state.plot.highlightedWatchKey]?.key;
    for (final order in compactWatchSectionOrders.values) {
      final rebound = [
        for (final key in order)
          if (replacements[key] case final SymbolItem symbol) symbol.key,
      ];
      order
        ..clear()
        ..addAll(rebound);
    }
    for (final scope in _watchMonitorScopes.values) {
      _rekeySymbolSet(scope, replacements);
    }
    _lastMonitorEnabledKeys = null;
    _symbolHierarchy = hierarchy;
    _symbols
      ..clear()
      ..addAll(next);
    _expandedSymbolTreeNodes.clear();
    _symbolRevision += 1;
  }

  Future<void> chooseFirmwareFile() async {
    if (isSymbolLoading || _pickingFirmwareFile) return;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.loadFirmware);
      return;
    }
    final picker = firmwareFilePicker;
    if (picker == null) {
      loadDemoSymbols();
      return;
    }
    _pickingFirmwareFile = true;
    try {
      final path = await picker();
      if (_disposed || path == null || path.isEmpty) return;
      unawaited(loadFirmware(path));
    } finally {
      _pickingFirmwareFile = false;
    }
  }

  Future<void> loadFirmware(String path) async {
    if (_disposed || isSymbolLoading || path.isEmpty) return;
    if (_isDetachedRemote) {
      await remoteCommand!(ControllerCommand.loadFirmware, path);
      return;
    }
    final sender = backendCommand;
    if (sender == null) {
      loadDemoSymbols();
      return;
    }
    await _runFirmwareCommand(ControllerCommand.loadFirmware, {
      'path': path,
    }, path);
  }

  Future<void> _runFirmwareCommand(
    ControllerCommand command,
    Map<String, dynamic> arguments,
    String path, {
    bool propagateFailure = false,
  }) async {
    final sender = backendCommand!;
    final startedAt = DateTime.now();
    final loadId = '${startedAt.microsecondsSinceEpoch}-${_nextSymbolLoadId++}';
    lastBackendError = null;
    _setSymbolLoad(
      SymbolLoadProgress(loadId: loadId, path: path, startedAt: startedAt),
    );
    try {
      await sender(command, {...arguments, 'loadId': loadId});
      if (_disposed || state.symbolLoad?.loadId != loadId) return;
      _setSymbolLoad(
        state.symbolLoad!.copyWith(
          phase: 'ui',
          current: 0,
          total: 0,
          status: SymbolLoadStatus.complete,
          finishedAt: DateTime.now(),
        ),
      );
    } catch (error) {
      if (_disposed || state.symbolLoad?.loadId != loadId) return;
      _setSymbolLoad(
        state.symbolLoad!.copyWith(
          status: SymbolLoadStatus.failed,
          finishedAt: DateTime.now(),
        ),
      );
      final failure = error is BackendException
          ? error
          : BackendException(
              'symbol_load_failed',
              '无法读取 ELF 文件。',
              error.toString(),
            );
      if (propagateFailure) rethrow;
      // A process exit is also reported globally by the client.
      if (lastBackendError?['code'] != failure.code) {
        applyBackendEvent(BackendEventType.error, {
          'code': failure.code,
          'operation': 'loadFirmware',
          'message': failure.message,
          if (failure.details != null) 'details': failure.details,
        });
      }
    }
  }

  void _setSymbolLoad(SymbolLoadProgress progress) {
    final wasLoading = isSymbolLoading;
    state.symbolLoad = progress;
    _touchSnapshotFields(['symbolLoad']);
    signals.symbolLoad.emit();
    if (wasLoading != isSymbolLoading) signals.symbols.emit();
  }

  void applySymbolLoadProgress(Map<String, dynamic> payload) {
    final current = state.symbolLoad;
    if (_disposed ||
        current == null ||
        !current.isLoading ||
        payload['loadId'] != current.loadId) {
      return;
    }
    final phase = payload['phase'];
    if (phase is! String ||
        !const {
          'check',
          'debug',
          'scan',
          'variables',
          'source',
          'ui',
        }.contains(phase)) {
      return;
    }
    _setSymbolLoad(
      current.copyWith(
        phase: phase,
        current: math.max(0, (payload['current'] as num?)?.toInt() ?? 0),
        total: math.max(0, (payload['total'] as num?)?.toInt() ?? 0),
      ),
    );
  }

  void applySymbolLoadSnapshot(Map<String, dynamic> payload) {
    if (_disposed) return;
    final next = SymbolLoadProgress.fromJson(payload);
    final current = state.symbolLoad;
    if (current != null &&
        (next.startedAt.isBefore(current.startedAt) ||
            (next.loadId == current.loadId &&
                next.revision <= current.revision))) {
      return;
    }
    _setSymbolLoad(next);
  }

  void refreshFirmware() {
    if (firmwarePath.isEmpty || isSymbolLoading) return;
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.loadFirmware, firmwarePath);
      return;
    }
    loadFirmware(firmwarePath);
  }
}

void _rekeySymbolSet(Set<String> values, Map<String, SymbolItem> replacements) {
  final rebound = {
    for (final key in values)
      if (replacements[key] case final SymbolItem symbol) symbol.key,
  };
  values
    ..clear()
    ..addAll(rebound);
}

void _rekeySymbolMap<T>(
  Map<String, T> values,
  Map<String, SymbolItem> replacements,
) {
  final rebound = {
    for (final entry in values.entries)
      if (replacements[entry.key] case final SymbolItem symbol)
        symbol.key: entry.value,
  };
  values
    ..clear()
    ..addAll(rebound);
}
