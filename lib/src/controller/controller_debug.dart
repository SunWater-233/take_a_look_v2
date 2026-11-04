part of 'controller.dart';

extension TakeALookControllerDebug on TakeALookController {
  DebugState get debugState => state.debug;

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
    if (sourceTask.running || isSymbolLoading) return;
    try {
      await saveSourceProject({'sourceRoot': path.trim()});
    } on Object catch (error) {
      applyBackendEvent(BackendEventType.error, {
        'code': 'source_project_failed',
        'message': error.toString(),
      });
    }
  }

  void toggleBreakpoint(String path, int line) {
    if (line <= 0) return;
    final executableLines = executableLinesFor(path);
    if (!executableLines.contains(line)) return;
    final matchingRequest = debugState.requestedBreakpoints.entries
        .where((entry) => sourcePathsMatch(entry.key, path))
        .firstOrNull;
    final requestPath = matchingRequest?.key ?? path;
    final lines = <int>{...matchingRequest?.value ?? const <int>{}};
    if (!lines.add(line)) lines.remove(line);
    setBreakpoints(requestPath, lines);
  }

  void setBreakpoints(String path, Iterable<int> requestedLines) {
    final executableLines = executableLinesFor(path);
    final lines = requestedLines
        .where((line) => line > 0 && executableLines.contains(line))
        .toSet();
    if (lines.isEmpty) {
      debugState.requestedBreakpoints.remove(path);
    } else {
      debugState.requestedBreakpoints[path] = lines;
    }
    _emitState([signals.debug]);
    _dispatchCommand(ControllerCommand.setBreakpoints, {
      'path': path,
      'lines': lines.toList()..sort(),
    });
  }

  void haltTarget() => _dispatchCommand(ControllerCommand.debugControl, 'halt');

  void resumeTarget() =>
      _dispatchCommand(ControllerCommand.debugControl, 'resume');

  void stepTarget() => _dispatchCommand(ControllerCommand.debugControl, 'step');

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
    if (data['breakpoints'] case final List rawBreakpoints) {
      debugState.resolvedBreakpoints
        ..clear()
        ..addAll(
          rawBreakpoints.whereType<Map>().map(
            (raw) => DebugBreakpoint.fromJson(Map<String, dynamic>.from(raw)),
          ),
        );
      debugState.requestedBreakpoints.clear();
      for (final breakpoint in debugState.resolvedBreakpoints) {
        debugState.requestedBreakpoints
            .putIfAbsent(breakpoint.path, () => <int>{})
            .add(breakpoint.requestedLine);
      }
    }
    if (data['requestedBreakpoints'] case final Map rawRequested) {
      debugState.requestedBreakpoints
        ..clear()
        ..addEntries(
          rawRequested.entries
              .where((entry) => entry.key is String && entry.value is List)
              .map(
                (entry) => MapEntry(
                  entry.key as String,
                  (entry.value as List).whereType<int>().toSet(),
                ),
              ),
        );
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
    if (emit) _emitState([signals.debug]);
  }
}
