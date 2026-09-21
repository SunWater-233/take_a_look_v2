part of 'controller.dart';

extension TakeALookControllerDebug on TakeALookController {
  DebugState get debugState => state.debug;

  void toggleBreakpoint(String path, int line) {
    if (line <= 0) return;
    final lines = <int>{
      ...debugState.requestedBreakpoints[path] ?? const <int>{},
    };
    if (!lines.add(line)) lines.remove(line);
    setBreakpoints(path, lines);
  }

  void setBreakpoints(String path, Iterable<int> requestedLines) {
    final lines = requestedLines.where((line) => line > 0).toSet();
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

  void applyDebugState(Map<String, dynamic> data, {bool emit = true}) {
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
    if (emit) _emitState([signals.debug]);
  }
}
