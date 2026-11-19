part of 'controller.dart';

const _projectStateFields = {
  'freeRtosSettings',
  'probeType',
  'targetName',
  'targetPackId',
  'swdClock',
  'serialNumber',
  'connectionKind',
  'remoteConfig',
  'sampleRateHz',
  'monitorRateHz',
  'rttSampleRateHz',
  'displayRefreshMode',
  'samplingPaused',
  'plottingPaused',
  'rttEnabled',
  'rttProtocol',
  'followLatest',
  'plotVisibleWindowSeconds',
  'plotRetentionSeconds',
  'plotAutoY',
  'plotYMin',
  'plotYMax',
  'plotShowGrid',
  'plotShowLegend',
  'plotMouseXEnabled',
  'plotMouseYEnabled',
  'plotInvertX',
  'plotInvertY',
  'uiScale',
  'selectedSymbols',
  'watches',
  'analysisSession',
  'sourceWorkspace',
  'sourceProject',
};

/// An immutable copy of settings that have passed project validation.
final class ValidatedProjectSettings
    extends UnmodifiableMapView<String, dynamic> {
  factory ValidatedProjectSettings(Map<String, dynamic> data) {
    final settings = ValidatedProjectSettings._({
      for (final entry in data.entries) entry.key: _freeze(entry.value),
    });
    TakeALookControllerProject.validateProjectSettings(settings);
    return settings;
  }

  ValidatedProjectSettings._(super.map);

  static Object? _freeze(Object? value) => switch (value) {
    Map() => Map.unmodifiable({
      for (final entry in value.entries) entry.key: _freeze(entry.value),
    }),
    List() => List.unmodifiable(value.map(_freeze)),
    _ => value,
  };
}

extension TakeALookControllerProject on TakeALookController {
  Map<String, dynamic> projectSettings() {
    final data = _encodeSnapshot(
      fields: _projectStateFields.difference(const {
        'watches',
        'sourceProject',
        'sourceWorkspace',
      }),
      includeSamples: false,
      includeAnalysisData: true,
    );
    final visibility = state.plot.visibilityBeforeIsolation;
    return {
      ...data,
      'sourceProject': sourceProject.settings(),
      'sourceWorkspace': {
        'openPaths': sourceWorkspace.openPaths.toList(),
        'selectedPath': sourceWorkspace.selectedPath,
      },
      'watches': [
        for (final watch in _watches)
          if (watch.symbol.section != '.rodata.freertos')
            {
              'key': watch.symbol.key,
              'symbol': watch.symbol.toJson(),
              'color': watch.color.toARGB32(),
              'sampling': watch.samplingEnabled,
              'readMode': watch.readMode.name,
              'monitorRateHz': watch.monitorRateHz,
              'plotted':
                  watch.samplingEnabled &&
                  (visibility?[watch.symbol.key] ?? watch.plotted),
              'pinned': watch.pinned,
              'standalone': watch.standalone,
              'displayHex': watch.displayHex,
            },
      ],
      'watchInputDrafts': Map<String, String>.of(watchInputDrafts),
      'compactWatchSelection': compactWatchSelection,
      'compactExpandedWatches': compactExpandedWatches.toList(),
      'compactWatchSummaryFraction': compactWatchSummaryFraction,
      'compactWatchPinnedFraction': compactWatchPinnedFraction,
      'compactWatchSectionOrders': {
        for (final entry in compactWatchSectionOrders.entries)
          entry.key: List<String>.of(entry.value),
      },
      'expandedSymbolTreeNodes': _expandedSymbolTreeNodes.toList(),
      ...debugState.breakpointSettings.toJson(includePause: false),
    };
  }

  Future<void> createProject() async {
    final defaults = TakeALookController(backendCommand: (_, _) async {});
    final settings = defaults.projectSettings()
      ..['uiScale'] = uiScale
      ..['sourceWorkspace'] = {
        'viewedStopRevision': debugState.stopRevision,
        'additionRevision': sourceWorkspace.additionRevision,
      };
    defaults.debugState.stopRevision = debugState.stopRevision;
    defaults.debugState.breakpointRevision = debugState.breakpointRevision;
    final localFirmwareState = defaults._encodeSnapshot(
      fields: const {'firmware', 'debug', 'debugIndex'},
    );
    defaults.dispose();

    await restoreProjectSettings(settings);
    if (!_disposed && backendCommand == null && projectBackendCommand == null) {
      applySnapshot(localFirmwareState);
    }
  }

  static void validateProjectSettings(Map<String, dynamic> data) {
    for (final key in [
      'compactWatchSummaryFraction',
      'compactWatchPinnedFraction',
    ]) {
      final fraction = data[key];
      if (fraction != null &&
          (fraction is! num ||
              !fraction.isFinite ||
              fraction <= 0 ||
              fraction >= 1)) {
        throw const FormatException('项目变量监视分区比例无效。');
      }
    }
    final orders = data['compactWatchSectionOrders'];
    if (orders != null) {
      if (orders is! Map ||
          orders.entries.any(
            (entry) =>
                !const ['pinned', 'capture', 'members'].contains(entry.key) ||
                entry.value is! List ||
                (entry.value as List).any((key) => key is! String) ||
                (entry.value as List).toSet().length !=
                    (entry.value as List).length,
          )) {
        throw const FormatException('项目变量监视排序无效。');
      }
    }
    if (data['watches'] is! List ||
        data['sourceProject'] is! Map ||
        !_projectStateFields.every(data.containsKey)) {
      throw const FormatException('项目缺少变量或工程配置。');
    }
    final project = data['sourceProject'] as Map;
    for (final key in const [
      'sourceRoot',
      'firmwarePath',
      'buildCommand',
      'shell',
      'afterDownload',
      'extraPath',
      'outputEncoding',
    ]) {
      final value = project[key];
      if (value is! String || value.contains('\u0000')) {
        throw FormatException('项目工程配置无效：$key');
      }
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
      if (watch['symbol'] is! Map ||
          SymbolItem.fromJson(
                Map<String, dynamic>.from(watch['symbol'] as Map),
              ).key !=
              watch['key'] ||
          watch['color'] is! int ||
          watch['sampling'] is! bool ||
          watch['plotted'] is! bool ||
          (watch['pinned'] != null && watch['pinned'] is! bool) ||
          (watch['standalone'] != null && watch['standalone'] is! bool) ||
          (watch['displayHex'] != null && watch['displayHex'] is! bool) ||
          !WatchReadMode.values.any((mode) => mode.name == watch['readMode']) ||
          (rate != null &&
              (rate is! num || !rate.isFinite || rate < .5 || rate > 10))) {
        throw const FormatException('项目变量配置无效。');
      }
    }
    final probe = TakeALookController(backendCommand: (_, _) async {});
    try {
      if (data['freeRtosSettings'] case final Map settings) {
        probe.setFreeRtosSettings(Map<String, dynamic>.from(settings));
      } else if (data.containsKey('freeRtosSettings')) {
        throw const FormatException('FreeRTOS 面板设置无效。');
      }
      probe.applySnapshot({
        'symbols': _projectWatchSymbols(data),
        for (final key in _projectStateFields)
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
      final breakpoints = BreakpointSettings.fromJson(data);
      for (final entry in breakpoints.disabled.entries) {
        if (breakpoints.requested[entry.key]?.containsAll(entry.value) !=
            true) {
          throw const FormatException('项目断点无效。');
        }
      }
    } finally {
      probe.dispose();
    }
  }

  Future<void> restoreProjectSettings(Map<String, dynamic> data) async {
    if (data is! ValidatedProjectSettings) validateProjectSettings(data);
    if (_restoringProject ||
        sourceTask.running ||
        isSymbolLoading ||
        _breakpointEditPending) {
      throw const FormatException('请等待当前项目或文件任务完成，再打开项目。');
    }
    _restoringProject = true;
    signals.connection.emit();
    try {
      await _restoreProjectSettings(data);
    } finally {
      _applyRestoredProject = null;
      _restoringProject = false;
      _lastMonitorEnabledKeys = null;
      _scheduleWatchMonitorSync();
      if (!_disposed) signals.connection.emit();
    }
  }

  Future<void> _restoreProjectSettings(Map<String, dynamic> data) async {
    final settings = <String, dynamic>{
      for (final key in _projectStateFields)
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
      final visibleKeys = {
        for (final keys in _watchMonitorScopes.values) ...keys,
      };
      final unrestrictedMonitors =
          !_watchMonitorVisibilityKnown ||
          (data['rttEnabled'] == true && data['rttProtocol'] == 'plus');
      _applyRestoredProject = (backend) =>
          _commitRestoredProject(settings, data, backend);
      final arguments = <String, dynamic>{
        'sourceProject': data['sourceProject'],
        'connection': {
          for (final key in const [
            'probeType',
            'targetName',
            'targetPackId',
            'swdClock',
            'serialNumber',
            'connectionKind',
            'remoteConfig',
            'sampleRateHz',
            'monitorRateHz',
            'rttSampleRateHz',
          ])
            if (settings.containsKey(key)) key: settings[key],
        },
        'samplingPaused': data['samplingPaused'],
        'rttEnabled': data['rttEnabled'],
        'rttProtocol': data['rttProtocol'],
        'watches': [
          for (final raw in (data['watches'] as List).cast<Map>())
            {
              ...Map<String, dynamic>.from(raw),
              'monitorEnabled':
                  unrestrictedMonitors ||
                  raw['pinned'] == true ||
                  (raw['symbol'] as Map)['dataSource'] == 'rtt' ||
                  visibleKeys.contains(raw['key']),
              'color':
                  '#${(raw['color'] as int).toRadixString(16).padLeft(8, '0')}',
            },
        ],
        ...BreakpointSettings.fromJson(data).toJson(includePause: false),
      };
      final path = (data['sourceProject'] as Map)['firmwarePath'] as String;
      if (path.isEmpty) {
        await sender(ControllerCommand.restoreProject, arguments);
      } else {
        await _runFirmwareCommand(
          ControllerCommand.restoreProject,
          arguments,
          path,
          propagateFailure: true,
          commandSender: sender,
        );
      }
      if (_applyRestoredProject != null && projectBackendCommand != null) {
        throw const BackendException('project_state_missing', '后端未提交项目状态。');
      }
      _applyRestoredProject?.call(const {});
    } else {
      _commitRestoredProject(settings, data, const {});
    }
  }

  void _commitRestoredProject(
    Map<String, dynamic> settings,
    Map<String, dynamic> data,
    Map<String, dynamic> backend,
  ) {
    _applyRestoredProject = null;
    if (_disposed) return;
    _clearSampleHistory();
    _clearWatchDeletionHistory();
    _removedWatchKeys.clear();
    state.plot.visibilityBeforeIsolation = null;
    _watches.clear();
    _clearFrozenPlot();
    sourceLocationRequest = null;
    final breakpoints = BreakpointSettings.fromJson(data)..paused = false;
    _removedBreakpoints = null;
    debugState.breakpointUndoId = 0;
    if (!backend.containsKey('debug')) {
      debugState.breakpointSettings = breakpoints;
      debugState.resolvedBreakpoints.clear();
    }
    final backendDebug = backend['debug'] as Map?;
    _applySnapshot(
      {
        'symbols': _projectWatchSymbols(data),
        ...settings,
        ...backend,
        'watches': settings['watches'],
        'sourceWorkspace': {
          ...(settings['sourceWorkspace'] as Map),
          'viewedStopRevision':
              backendDebug?['stopRevision'] ?? debugState.stopRevision,
          'additionRevision': sourceWorkspace.additionRevision,
        },
        'elapsedSeconds': 0,
        'samplingElapsedSeconds': 0,
      },
      beforeNotify: () {
        watchInputDrafts
          ..clear()
          ..addAll(
            Map<String, String>.from(data['watchInputDrafts'] as Map? ?? {}),
          );
        compactWatchSelection = data['compactWatchSelection'] as String?;
        compactWatchSummaryFraction =
            (data['compactWatchSummaryFraction'] as num?)?.toDouble();
        compactWatchPinnedFraction =
            (data['compactWatchPinnedFraction'] as num?)?.toDouble();
        compactWatchSectionOrders
          ..clear()
          ..addAll({
            for (final entry
                in (data['compactWatchSectionOrders'] as Map? ?? {}).entries)
              entry.key as String: (entry.value as List)
                  .cast<String>()
                  .toList(),
          });
        compactExpandedWatches
          ..clear()
          ..addAll(
            (data['compactExpandedWatches'] as List? ?? []).cast<String>(),
          );
        _expandedSymbolTreeNodes
          ..clear()
          ..addAll(
            (data['expandedSymbolTreeNodes'] as List? ?? []).cast<String>(),
          );
      },
    );
    _emitState([
      signals.sampling,
      signals.watches,
      signals.symbols,
      signals.debug,
    ]);
    signals.telemetrySync.emit();
  }
}

List<Map> _projectWatchSymbols(Map<String, dynamic> data) => [
  for (final watch in (data['watches'] as List).cast<Map>())
    watch['symbol'] as Map,
];
