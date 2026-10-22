part of 'controller.dart';

extension TakeALookControllerProject on TakeALookController {
  Map<String, dynamic> projectSettings() {
    final data = _encodeSnapshot(
      fields: ControllerSnapshotSchema.projectFields,
      includeSamples: false,
      includeAnalysisData: true,
    );
    // A project stores variable configuration and input drafts. Recorded values
    // belong to recordings and must never be replayed as target writes.
    for (final raw in data['watches'] as List) {
      (raw as Map).removeWhere(
        (key, _) => const {
          'value',
          'updatedAtMs',
          'sampleCursor',
          'historyStartSeconds',
        }.contains(key),
      );
    }
    return {
      ...data,
      'watchInputDrafts': Map<String, String>.of(watchInputDrafts),
      'compactWatchSelection': compactWatchSelection,
      'compactExpandedWatches': compactExpandedWatches.toList(),
      'expandedSymbolTreeNodes': _expandedSymbolTreeNodes.toList(),
      'sourceRoot': debugState.sourceRoot,
      'requestedBreakpoints': {
        for (final entry in debugState.requestedBreakpoints.entries)
          entry.key: entry.value.toList()..sort(),
      },
    };
  }

  static void validateProjectSettings(Map<String, dynamic> data) {
    if (data['symbols'] is! List ||
        data['watches'] is! List ||
        data['sourceProject'] is! Map ||
        !ControllerSnapshotSchema.projectFields.every(data.containsKey)) {
      throw const FormatException('项目缺少变量或工程配置。');
    }
    for (final key in const [
      'sampleRateHz',
      'monitorRateHz',
      'rttSampleRateHz',
      'plotVisibleWindowSeconds',
      'plotRetentionSeconds',
      'uiScale',
    ]) {
      final value = data[key];
      if (value is! num || !value.isFinite || value <= 0) {
        throw FormatException('项目设置无效：$key');
      }
    }
    final monitorRate = (data['monitorRateHz'] as num).toDouble();
    if (monitorRate < .5 ||
        monitorRate > 10 ||
        data['sourceRoot'] is! String ||
        data['symbolFile'] is! String ||
        !const {
          'local',
          'ember',
          'emberGdb',
          'gdb',
        }.contains(data['connectionKind'])) {
      throw const FormatException('项目连接或监视设置无效。');
    }
    for (final raw in data['watches'] as List) {
      final watch = raw as Map;
      final rate = watch['monitorRateHz'];
      if (watch['color'] is! int ||
          watch['sampling'] is! bool ||
          watch['plotted'] is! bool ||
          (watch['pinned'] != null && watch['pinned'] is! bool) ||
          !WatchReadMode.values.any((mode) => mode.name == watch['readMode']) ||
          (rate != null &&
              (rate is! num || !rate.isFinite || rate < .5 || rate > 10))) {
        throw const FormatException('项目变量配置无效。');
      }
    }
    final probe = TakeALookController(backendCommand: (_, _) async {});
    try {
      probe.applySnapshot({
        for (final key in ControllerSnapshotSchema.projectFields)
          if (data.containsKey(key)) key: data[key],
      });
      if (probe.watches.length != (data['watches'] as List).length ||
          probe.watches.map((w) => w.symbol.key).toSet().length !=
              probe.watches.length) {
        throw const FormatException('项目变量引用无效。');
      }
      Map<String, String>.from(data['watchInputDrafts'] as Map? ?? {});
      (data['compactExpandedWatches'] as List? ?? []).cast<String>().toList();
      (data['expandedSymbolTreeNodes'] as List? ?? []).cast<String>().toList();
      if (data['compactWatchSelection'] != null &&
          data['compactWatchSelection'] is! String) {
        throw const FormatException('项目变量选择无效。');
      }
      for (final entry
          in (data['requestedBreakpoints'] as Map? ?? {}).entries) {
        if (entry.key is! String ||
            (entry.value as List).cast<int>().any((line) => line <= 0)) {
          throw const FormatException('项目断点无效。');
        }
      }
    } finally {
      probe.dispose();
    }
  }

  Future<void> restoreProjectSettings(Map<String, dynamic> data) async {
    validateProjectSettings(data);
    if (_restoringProject || sourceTask.running || isSymbolLoading) {
      throw const FormatException('请等待当前项目或文件任务完成，再打开项目。');
    }
    _restoringProject = true;
    signals.connection.emit();
    try {
      await _restoreProjectSettings(data);
    } finally {
      _restoringProject = false;
      if (!_disposed) signals.connection.emit();
    }
  }

  Future<void> _restoreProjectSettings(Map<String, dynamic> data) async {
    final settings = <String, dynamic>{
      for (final key in ControllerSnapshotSchema.projectFields)
        if (data.containsKey(key)) key: data[key],
    };
    // Project contents can change while a probe is attached. Keep the active
    // hardware session instead of applying connection defaults from the file.
    final preserveConnection =
        connectionStatus != ConnectionStatus.disconnected;
    if (preserveConnection) {
      for (final key in const [
        'probeType',
        'targetName',
        'targetPackId',
        'swdClock',
        'serialNumber',
        'connectionKind',
        'remoteConfig',
      ]) {
        settings.remove(key);
      }
    }
    final sender = projectBackendCommand ?? backendCommand;
    if (sender != null) {
      final path = data['symbolFile'] as String? ?? '';
      if (path.isNotEmpty && !await File(path).exists()) {
        throw FormatException('项目符号文件不存在：$path');
      }
      if (!preserveConnection && targetCatalogRequest != null) {
        await requestTargetCatalog('selectTarget', {
          'name': data['targetName'],
          'packId': data['targetPackId'] ?? '',
        });
      }
      await sender(ControllerCommand.configureProject, {
        for (final key in const [
          'probeType',
          'targetName',
          'swdClock',
          'serialNumber',
          'connectionKind',
          'remoteConfig',
          'sampleRateHz',
          'monitorRateHz',
          'rttSampleRateHz',
        ])
          if (settings.containsKey(key)) key: settings[key],
      });
      await sender(ControllerCommand.setSamplingPaused, true);
      await sender(ControllerCommand.clearSamples, null);
      await saveSourceProject(
        Map<String, dynamic>.from(data['sourceProject'] as Map),
      );
      if (path.isNotEmpty) {
        await loadSymbolsFromPath(path);
        if (state.symbolLoad?.status == SymbolLoadStatus.failed) {
          throw const FormatException('项目符号文件加载失败。');
        }
        final loadedKeys = _symbols.map((s) => s.key).toSet();
        if ((data['watches'] as List).any(
          (w) => !loadedKeys.contains((w as Map)['key']),
        )) {
          throw const FormatException('固件符号已变化，无法恢复项目变量，请使用保存项目时的 ELF / AXF。');
        }
        settings['symbols'] = [for (final symbol in _symbols) symbol.toJson()];
      }
      // Await the backend before applying the UI, so a delayed state echo cannot
      // replace the project's variables with the previous watch list.
      await sender(ControllerCommand.setWatches, {
        'watches': [
          for (final raw in data['watches'] as List)
            {
              ...Map<String, dynamic>.from(raw as Map),
              'color':
                  '#${(raw['color'] as int).toRadixString(16).padLeft(8, '0')}',
            },
        ],
      });
      await sender(ControllerCommand.setRttProtocol, data['rttProtocol']);
      await sender(ControllerCommand.toggleRtt, data['rttEnabled'] == true);
      await sender(
        ControllerCommand.setSamplingPaused,
        data['samplingPaused'] == true,
      );
    }
    _clearWatchDeletionHistory();
    _removedWatchKeys.clear();
    _watches.clear();
    plotHistory.clear();
    _clearFrozenPlot();
    state.acquisition.rawRecording = {};
    applySnapshot({
      ...settings,
      'elapsedSeconds': 0,
      'samplingElapsedSeconds': 0,
    });
    watchInputDrafts
      ..clear()
      ..addAll(
        Map<String, String>.from(data['watchInputDrafts'] as Map? ?? {}),
      );
    compactWatchSelection = data['compactWatchSelection'] as String?;
    compactExpandedWatches
      ..clear()
      ..addAll((data['compactExpandedWatches'] as List? ?? []).cast<String>());
    _expandedSymbolTreeNodes
      ..clear()
      ..addAll((data['expandedSymbolTreeNodes'] as List? ?? []).cast<String>());
    debugState.sourceRoot =
        data['sourceRoot'] as String? ?? sourceProject.sourceRoot;
    debugState.requestedBreakpoints.clear();
    for (final entry in (data['requestedBreakpoints'] as Map? ?? {}).entries) {
      final lines = (entry.value as List).cast<int>().toSet();
      debugState.requestedBreakpoints[entry.key as String] = lines;
      if (sender != null) {
        await sender(ControllerCommand.setBreakpoints, {
          'path': entry.key,
          'lines': lines.toList(),
        });
      }
    }
    _emitState([signals.watches, signals.symbols, signals.debug]);
  }
}
