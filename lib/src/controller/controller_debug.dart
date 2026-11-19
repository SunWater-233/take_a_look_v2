part of 'controller.dart';

extension TakeALookControllerDebug on TakeALookController {
  DebugState get debugState => state.debug;

  List<String> get sourceCatalogFiles {
    final revision = (symbolRevision, debugIndexRevision);
    if (revision != _sourceCatalogRevision) {
      _sourceCatalogRevision = revision;
      final files = {
        ...debugState.sourceFiles,
        for (final symbol in _symbols)
          if (!symbol.missing &&
              symbol.source.isNotEmpty &&
              symbol.source != '未知来源')
            symbol.source,
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _sourceCatalogFiles = List.unmodifiable(files);
    }
    return _sourceCatalogFiles;
  }

  Future<void> chooseSourceRoot() async {
    if (_isDetachedRemote) {
      _dispatchRemote(ControllerCommand.setSourceRoot);
      return;
    }
    final picker = sourceRootPicker;
    if (picker == null) return;
    final path = await picker();
    if (path == null || path.isEmpty) return;
    await setSourceRoot(path);
  }

  Future<void> setSourceRoot(String path) async {
    if (sourceTask.running || isSymbolLoading || isProjectRestoring) return;
    try {
      await saveSourceProject({'sourceRoot': path.trim()});
    } on Object catch (error) {
      applyBackendEvent(BackendEventType.error, {
        'code': 'source_project_failed',
        'message': error.toString(),
      });
    }
  }

  String? get breakpointEditDisabledReason {
    if (_breakpointEditPending) return '正在更新断点';
    if (isProjectRestoring) return '正在打开工程';
    if (sourceTask.blocksProbe) return '请等待固件下载完成';
    return null;
  }

  Future<bool> toggleBreakpoint(String path, int line) =>
      editBreakpoints(BreakpointAction.toggle, path: path, line: line);

  Future<bool> editBreakpoints(
    BreakpointAction action, {
    String? path,
    int? line,
    bool? value,
    int? undoId,
  }) async {
    if (breakpointEditDisabledReason != null) return false;
    try {
      if (_isDetachedRemote) {
        _breakpointEditPending = true;
        _emitState([signals.debug]);
        try {
          await remoteCommand!(ControllerCommand.setBreakpoints, {
            'action': action.name,
            'path': ?path,
            'line': ?line,
            'value': ?value,
            'undoId': ?undoId,
          });
          return true;
        } finally {
          _breakpointEditPending = false;
          if (!_disposed) _emitState([signals.debug]);
        }
      }

      final settings = debugState.breakpointSettings.copy();
      BreakpointSettings? removed;
      switch (action) {
        case BreakpointAction.clear:
          if (settings.requested.isEmpty) return false;
          removed = settings.copy();
          settings.requested.clear();
          settings.disabled.clear();
        case BreakpointAction.setPaused:
          if (value == null || value == settings.paused) return false;
          settings.paused = value;
        case BreakpointAction.undo:
          final removal = _removedBreakpoints;
          if (removal == null || undoId != debugState.breakpointUndoId) {
            return false;
          }
          for (final entry in removal.requested.entries) {
            final file = _breakpointRequestPath(settings, entry.key);
            final lines = settings.requested.putIfAbsent(file, () => {});
            final restoredDisabled = entry.value
                .difference(lines)
                .intersection(removal.disabled[entry.key] ?? const {});
            lines.addAll(entry.value);
            if (restoredDisabled.isNotEmpty) {
              settings.disabled
                  .putIfAbsent(file, () => {})
                  .addAll(restoredDisabled);
            }
          }
        case BreakpointAction.toggle:
        case BreakpointAction.remove:
        case BreakpointAction.setEnabled:
          if (path == null || line == null || line <= 0) return false;
          final file = _breakpointRequestPath(settings, path);
          final lines = settings.requested[file];
          final disabled = settings.disabled[file];
          final exists = lines?.contains(line) ?? false;
          if (action == BreakpointAction.setEnabled) {
            if (!exists || value == null) return false;
            if (value) {
              disabled?.remove(line);
            } else {
              settings.disabled.putIfAbsent(file, () => {}).add(line);
            }
          } else if (exists) {
            removed = BreakpointSettings(
              requested: {
                file: {line},
              },
              disabled: {
                if (disabled?.contains(line) ?? false) file: {line},
              },
            );
            lines!.remove(line);
            disabled?.remove(line);
          } else if (action == BreakpointAction.toggle &&
              executableLinesFor(path).contains(line)) {
            settings.requested.putIfAbsent(file, () => {}).add(line);
          } else {
            return false;
          }
      }
      await _commitBreakpointSettings(settings, backendCommand);
      if (_disposed) return false;
      if (removed != null || action == BreakpointAction.undo) {
        _removedBreakpoints = removed;
        debugState.breakpointUndoId = removed == null
            ? 0
            : ++_nextBreakpointUndoId;
        _emitState([signals.debug]);
      }
      return true;
    } on Object catch (error) {
      if (!_disposed) {
        applyBackendEvent(BackendEventType.error, {
          'code': 'breakpoint_update_failed',
          'message': '无法更新断点。',
          'details': error.toString(),
        });
      }
      return false;
    }
  }

  String _breakpointRequestPath(BreakpointSettings settings, String path) =>
      settings.requested.keys
          .where((file) => sourcePathsMatch(file, path))
          .firstOrNull ??
      canonicalSourcePath(path);

  Future<void> setBreakpoints(String path, Iterable<int> requestedLines) async {
    if (breakpointEditDisabledReason != null) return;
    final settings = debugState.breakpointSettings.copy();
    final file = _breakpointRequestPath(settings, path);
    final lines = requestedLines
        .where(executableLinesFor(path).contains)
        .toSet();
    settings.requested[file] = lines;
    settings.disabled[file]?.retainAll(lines);
    await _commitBreakpointSettings(settings, backendCommand);
  }

  Future<void> _commitBreakpointSettings(
    BreakpointSettings settings,
    BackendCommand? sender,
  ) async {
    if (sender == null) {
      debugState.breakpointSettings = settings.copy();
      debugState.resolvedBreakpoints.clear();
      _emitState([signals.debug]);
      return;
    }
    final previousRevision = debugState.breakpointRevision;
    _breakpointEditPending = true;
    _emitState([signals.debug]);
    try {
      await sender(ControllerCommand.setBreakpoints, settings.toJson());
      if (!_disposed && debugState.breakpointRevision == previousRevision) {
        debugState.breakpointSettings = settings.copy();
        debugState.resolvedBreakpoints.clear();
      }
    } finally {
      _breakpointEditPending = false;
      if (!_disposed) _emitState([signals.debug]);
    }
  }

  void haltTarget() => _dispatchCommand(ControllerCommand.debugControl, 'halt');

  void resumeTarget() =>
      _dispatchCommand(ControllerCommand.debugControl, 'resume');

  void stepTarget() => _dispatchCommand(ControllerCommand.debugControl, 'step');

  bool get sourceStepPending => _sourceStepPending;

  String? sourceStepDisabledReason(SourceStep step) {
    if (_sourceStepPending) return '正在执行源码步进';
    if (connectionStatus != ConnectionStatus.connected) return '请先连接调试目标';
    if (!supportsTargetControl) return '当前连接不支持源码步进';
    if (sourceTask.blocksProbe) return '请等待固件下载完成';
    if (firmwareRequiresDownload) return '固件已变化，请先重新下载';
    if (debugState.executionState != DebugExecutionState.halted) {
      return '请先暂停目标';
    }
    if (step == SourceStep.stepOut) {
      return debugState.stepOutAvailable ? null : '当前停止位置没有可用的调用帧信息';
    }
    return debugState.sourceStepAvailable ? null : '当前停止位置没有可用的源码行信息';
  }

  Future<void> stepSource(SourceStep step) async {
    final send = backendCommand ?? remoteCommand;
    if (send == null || sourceStepDisabledReason(step) != null) return;
    _sourceStepPending = true;
    _emitState([signals.debug]);
    try {
      await send(ControllerCommand.debugControl, step.name);
    } finally {
      _sourceStepPending = false;
      if (!_disposed) _emitState([signals.debug]);
    }
  }

  Set<int> executableLinesFor(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    for (final entry in debugState.executableLines.entries) {
      if (entry.key.replaceAll('\\', '/').toLowerCase() == normalized) {
        return entry.value;
      }
    }
    final basename = normalized.substring(normalized.lastIndexOf('/') + 1);
    final basenameMatches = debugState.executableLines.entries
        .where((entry) {
          final key = entry.key.replaceAll('\\', '/').toLowerCase();
          return key.substring(key.lastIndexOf('/') + 1) == basename;
        })
        .map((entry) => entry.value)
        .toList();
    return basenameMatches.length == 1 ? basenameMatches.single : const <int>{};
  }

  bool sourcePathsMatch(String left, String right) {
    String normalize(String path) => path.replaceAll('\\', '/').toLowerCase();
    String basename(String path) {
      final normalized = normalize(path);
      return normalized.substring(normalized.lastIndexOf('/') + 1);
    }

    if (normalize(left) == normalize(right)) return true;
    final name = basename(left);
    if (name != basename(right)) return false;
    final matchingDebugPaths = {
      ...debugState.sourceFiles,
      ...debugState.executableLines.keys,
    }.map(normalize).toSet().where((path) => basename(path) == name).length;
    return matchingDebugPaths == 1;
  }

  void applyDebugState(Map<String, dynamic> data, {bool emit = true}) {
    final previousExecution = debugState.executionState;
    final previousSource = debugState.currentSource;
    final previousLine = debugState.currentLine;
    final previousPc = debugState.programCounter;
    final execution = data['executionState'] as String?;
    debugState.executionState = DebugExecutionState.values.firstWhere(
      (candidate) => candidate.name == execution,
      orElse: () => DebugExecutionState.unknown,
    );
    debugState.sourceStepAvailable = data['sourceStepAvailable'] == true;
    debugState.stepOutAvailable = data['stepOutAvailable'] == true;
    final indexChanged = _applyDebugIndex(data);
    final breakpointRevision = data['breakpointRevision'] as int?;
    if (breakpointRevision == null ||
        breakpointRevision >= debugState.breakpointRevision) {
      _applyBreakpointState(data);
    }
    if (data['registers'] case final Map rawRegisters) {
      debugState.registers
        ..clear()
        ..addEntries(
          rawRegisters.entries
              .where((entry) => entry.key is String && entry.value is num)
              .map(
                (entry) =>
                    MapEntry(entry.key as String, (entry.value as num).toInt()),
              ),
        );
    }
    final location = data['stoppedLocation'];
    if (location is Map) {
      final mapped = Map<String, dynamic>.from(location);
      debugState.currentSource = mapped['path'] as String?;
      debugState.currentLine = mapped['line'] as int?;
      debugState.programCounter = mapped['address'] as int?;
    } else {
      debugState.currentSource = null;
      debugState.currentLine = null;
      debugState.programCounter = null;
    }
    if (data['stopRevision'] case final int revision) {
      debugState.stopRevision = revision;
    } else if (debugState.executionState == DebugExecutionState.halted &&
        (previousExecution != DebugExecutionState.halted ||
            previousSource != debugState.currentSource ||
            previousLine != debugState.currentLine ||
            previousPc != debugState.programCounter)) {
      debugState.stopRevision++;
    }
    if (emit) _emitState([signals.debug, if (indexChanged) signals.debugIndex]);
  }

  bool _applyDebugIndex(Map<String, dynamic> data) {
    if (!data.containsKey('sourceFiles') &&
        !data.containsKey('sourceDefinitions') &&
        !data.containsKey('executableLines')) {
      return false;
    }
    if (data['sourceFiles'] case final List rawFiles) {
      debugState.sourceFiles
        ..clear()
        ..addAll(rawFiles.whereType<String>());
    }
    if (data.containsKey('sourceDefinitions')) {
      final rawDefinitions = data['sourceDefinitions'];
      debugState.hasSourceDefinitionIndex = rawDefinitions is List;
      debugState.sourceDefinitions
        ..clear()
        ..addAll(
          (rawDefinitions is List ? rawDefinitions : const [])
              .whereType<Map>()
              .map(
                (raw) =>
                    SourceDefinition.fromJson(Map<String, dynamic>.from(raw)),
              ),
        );
    }
    if (data['executableLines'] case final Map rawLines) {
      debugState.executableLines
        ..clear()
        ..addEntries(
          rawLines.entries
              .where((entry) => entry.key is String && entry.value is List)
              .map(
                (entry) => MapEntry(
                  entry.key as String,
                  (entry.value as List)
                      .whereType<int>()
                      .where((line) => line > 0)
                      .toSet(),
                ),
              ),
        );
    }
    _debugIndexRevision++;
    return true;
  }

  void _applyBreakpointState(Map<String, dynamic> data) {
    if (data['breakpointRevision'] case final int revision) {
      debugState.breakpointRevision = revision;
    }
    if (data['breakpointUndoId'] case final int undoId) {
      debugState.breakpointUndoId = undoId;
    }
    if (data['breakpoints'] case final List rawBreakpoints) {
      debugState.resolvedBreakpoints
        ..clear()
        ..addAll(
          rawBreakpoints.whereType<Map>().map(
            (raw) => DebugBreakpoint.fromJson(Map<String, dynamic>.from(raw)),
          ),
        );
    }
    if (data['requestedBreakpoints'] is Map) {
      debugState.breakpointSettings = BreakpointSettings.fromJson(data);
    } else if (data['breakpoints'] is List) {
      final settings = BreakpointSettings();
      for (final breakpoint in debugState.resolvedBreakpoints) {
        settings.requested
            .putIfAbsent(breakpoint.path, () => {})
            .add(breakpoint.requestedLine);
      }
      debugState.breakpointSettings = settings;
    }
  }
}
