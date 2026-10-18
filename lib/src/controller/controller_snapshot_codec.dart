import '../models/models.dart';
import '../protocol/commands.dart';
import 'controller_snapshot_schema.dart';
import 'controller_state.dart';

/// Transient typed view; encoding never mutates application state or emits events.
class ControllerSnapshotView {
  const ControllerSnapshotView({
    required this.state,
    required this.symbols,
    required this.selectedSymbols,
    required this.watches,
    required this.logs,
    required this.uiScale,
    required this.samplingElapsedSeconds,
    required this.plotWindowEndSeconds,
    required this.canUndoWatchDeletion,
    required this.canRedoWatchDeletion,
  });

  final ControllerState state;
  final Iterable<SymbolItem> symbols;
  final Iterable<String> selectedSymbols;
  final Iterable<WatchItem> watches;
  final Iterable<LogEntry> logs;
  final double uiScale;
  final double samplingElapsedSeconds;
  final double plotWindowEndSeconds;
  final bool canUndoWatchDeletion;
  final bool canRedoWatchDeletion;
}

class ControllerSnapshotCodec {
  const ControllerSnapshotCodec();

  JsonObject encode(
    ControllerSnapshotView source, {
    bool includeSamples = true,
    bool packedSamples = false,
    bool? includeAnalysisData,
    Set<String>? fields,
  }) => {
    for (final field in SnapshotField.values)
      if ((fields == null || fields.contains(field.name)) &&
          (field != SnapshotField.symbolLoad ||
              source.state.symbolLoad != null))
        field.name: _encodeField(
          source,
          field,
          includeSamples: includeSamples,
          packedSamples: packedSamples,
          includeAnalysisData: includeAnalysisData,
        ),
  };

  Object? _encodeField(
    ControllerSnapshotView source,
    SnapshotField field, {
    required bool includeSamples,
    required bool packedSamples,
    required bool? includeAnalysisData,
  }) => switch (field) {
    SnapshotField.connectionStatus => source.state.connection.status.name,
    SnapshotField.probeType => source.state.connection.probeType,
    SnapshotField.targetName => source.state.connection.targetName,
    SnapshotField.targetPackId => source.state.connection.targetPackId,
    SnapshotField.targetPartNumber => source.state.connection.targetPartNumber,
    SnapshotField.targetPackLabel => source.state.connection.targetPackLabel,
    SnapshotField.targetPackMissing =>
      source.state.connection.targetPackMissing,
    SnapshotField.targetCatalogRevision =>
      source.state.connection.targetCatalogRevision,
    SnapshotField.swdClock => source.state.connection.swdClock,
    SnapshotField.serialNumber => source.state.connection.serialNumber,
    SnapshotField.connectionKind => source.state.connection.connectionKind,
    SnapshotField.gatewayProtocolVersion =>
      source.state.connection.gatewayProtocolVersion,
    SnapshotField.remoteConfig => Map<String, String>.from(
      source.state.connection.remoteConfig,
    ),
    SnapshotField.symbolFile => source.state.connection.symbolFile,
    SnapshotField.symbolLoad => source.state.symbolLoad!.toJson(),
    SnapshotField.sampleRateHz => source.state.acquisition.sampleRateHz,
    SnapshotField.monitorRateHz => source.state.acquisition.monitorRateHz,
    SnapshotField.rttSampleRateHz => source.state.acquisition.rttSampleRateHz,
    SnapshotField.displayRefreshMode =>
      source.state.acquisition.displayRefreshMode,
    SnapshotField.samplingElapsedSeconds => source.samplingElapsedSeconds,
    SnapshotField.elapsedSeconds => source.state.acquisition.elapsedSeconds,
    SnapshotField.samplingPaused => source.state.acquisition.samplingPaused,
    SnapshotField.rawRecording => source.state.acquisition.rawRecording,
    SnapshotField.plottingPaused => source.state.plot.plottingPaused,
    SnapshotField.plotHighlightedWatchKey =>
      source.state.plot.highlightedWatchKey,
    SnapshotField.plotWatchSelectionRevision =>
      source.state.plot.watchSelectionRevision,
    SnapshotField.rttEnabled => source.state.acquisition.rttEnabled,
    SnapshotField.rttProtocol => source.state.acquisition.rttProtocol,
    SnapshotField.followLatest => source.state.plot.followLatest,
    SnapshotField.plotVisibleWindowSeconds =>
      source.state.plot.visibleWindowSeconds,
    SnapshotField.plotRetentionSeconds => source.state.plot.retentionSeconds,
    SnapshotField.plotAutoY => source.state.plot.autoY,
    SnapshotField.plotYMin => source.state.plot.yMin,
    SnapshotField.plotYMax => source.state.plot.yMax,
    SnapshotField.plotShowGrid => source.state.plot.showGrid,
    SnapshotField.plotShowLegend => source.state.plot.showLegend,
    SnapshotField.plotMouseXEnabled => source.state.plot.mouseXEnabled,
    SnapshotField.plotMouseYEnabled => source.state.plot.mouseYEnabled,
    SnapshotField.plotInvertX => source.state.plot.invertX,
    SnapshotField.plotInvertY => source.state.plot.invertY,
    SnapshotField.plotWindowEndSeconds => source.plotWindowEndSeconds,
    SnapshotField.uiScale => source.uiScale,
    SnapshotField.lastBackendError => source.state.connection.lastError,
    SnapshotField.selectedSymbols => source.selectedSymbols.toList(),
    SnapshotField.symbols => [
      for (final symbol in source.symbols) symbol.toJson(),
    ],
    SnapshotField.watches => [
      for (final watch in source.watches)
        {
          'key': watch.symbol.key,
          'color': watch.color.toARGB32(),
          'sampling': watch.samplingEnabled,
          'readMode': watch.readMode.name,
          'monitorRateHz': watch.monitorRateHz,
          'updatedAtMs': watch.updatedAtMs,
          'plotted': watch.plotted,
          'value': watch.value,
          'sampleCursor': watch.totalSampleCount,
          'historyStartSeconds': watch.historyStartSeconds,
          if (includeSamples)
            'samples': packedSamples
                ? watch.samples.packedRange()
                : [
                    for (final point in watch.samples) [point.dx, point.dy],
                  ],
        },
    ],
    SnapshotField.canUndoWatchDeletion => source.canUndoWatchDeletion,
    SnapshotField.canRedoWatchDeletion => source.canRedoWatchDeletion,
    SnapshotField.logs => [for (final entry in source.logs) entry.toJson()],
    SnapshotField.analysisSession => source.state.analysis.toJson(
      includeData: includeAnalysisData ?? includeSamples,
      packed: packedSamples,
    ),
    SnapshotField.sourceWorkspace => source.state.sourceWorkspace.toJson(),
    SnapshotField.sourceProject => source.state.sourceProject.toJson(),
    SnapshotField.sourceTask => source.state.sourceTask.toJson(),
    SnapshotField.debug => {
      'stopRevision': source.state.debug.stopRevision,
      'executionState': source.state.debug.executionState.name,
      'sourceFiles': source.state.debug.sourceFiles,
      'sourceRoot': source.state.debug.sourceRoot,
      'executableLines': {
        for (final entry in source.state.debug.executableLines.entries)
          entry.key: entry.value.toList()..sort(),
      },
      'breakpoints': [
        for (final breakpoint in source.state.debug.resolvedBreakpoints)
          breakpoint.toJson(),
      ],
      'requestedBreakpoints': {
        for (final entry in source.state.debug.requestedBreakpoints.entries)
          entry.key: entry.value.toList()..sort(),
      },
      'registers': source.state.debug.registers,
      'stoppedLocation': source.state.debug.programCounter == null
          ? null
          : {
              'address': source.state.debug.programCounter,
              if (source.state.debug.currentSource != null)
                'path': source.state.debug.currentSource,
              if (source.state.debug.currentLine != null)
                'line': source.state.debug.currentLine,
            },
    },
  };
}
