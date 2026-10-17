typedef JsonObject = Map<String, Object?>;

/// Commands understood by the main Flutter window.
///
/// Detached windows still cross a platform-channel boundary as strings, but
/// strings are converted to this closed set immediately at the boundary.
enum ControllerCommand {
  setSourceProject,
  startSourceTask,
  cancelSourceTask,
  clearSourceOutput,
  toggleConnection,
  loadSymbols,
  setSampleRate,
  setMonitorRate,
  setDisplayRefreshMode,
  setRttSampleRate,
  setProbeType,
  setTargetName,
  setSwdClock,
  setSerialNumber,
  setConnectionKind,
  setRemoteConfig,
  setUiScale,
  toggleSampling,
  setSamplingPaused,
  togglePlotting,
  toggleRtt,
  setRttProtocol,
  toggleFollowLatest,
  setPlotViewport,
  configurePlotView,
  showAllPlotSamples,
  resetPlotView,
  clearSamples,
  clearLogs,
  resetTarget,
  setSourceRoot,
  addSourceFile,
  openSourceFile,
  closeSourceFile,
  markSourceFileRead,
  dismissSourceAttention,
  setSourceViewVisible,
  setBreakpoints,
  debugControl,
  exportCsv,
  toggleSymbol,
  selectSymbols,
  activateSymbol,
  addSelectedToWatch,
  removeWatch,
  removeWatches,
  undoWatchDeletion,
  reorderWatch,
  clearWatches,
  toggleWatchSampling,
  setWatchReadMode,
  setWatchMonitorRate,
  readWatch,
  toggleWatchPlot,
  setWatchColor,
  setWatchColors,
  setOnlyWatchesPlotted,
  setAllWatchesPlotted,
  invertWatchPlots,
  updateAnalysisSession,
  setWatches,
  writeWatch;

  String get wireName => name;

  static ControllerCommand parse(String value) {
    for (final command in values) {
      if (command.wireName == value) return command;
    }
    throw FormatException('Unknown controller command: $value');
  }
}

/// Commands implemented by the Python hardware process.
enum BackendMethod {
  listTargets,
  inspectTargetPack,
  importTargetPack,
  discardTargetPackPreview,
  removeTargetPack,
  selectTarget,
  setSourceProject,
  startSourceTask,
  cancelSourceTask,
  handshake,
  getState,
  connect,
  toggleConnection,
  disconnect,
  loadSymbols,
  setConfig,
  setWatches,
  writeWatch,
  readWatch,
  setSamplingPaused,
  setRtt,
  clearSamples,
  resetTarget,
  getDebugInfo,
  setBreakpoints,
  debugControl,
  exportCsv,
  shutdown;

  String get wireName => name;
}

class BackendCall {
  const BackendCall(this.method, [this.params = const {}]);

  final BackendMethod method;
  final JsonObject params;
}

/// The only mapping from UI-domain commands to backend RPC methods.
class BackendCommandMapper {
  const BackendCommandMapper._();

  static BackendCall? translate(
    ControllerCommand command,
    Object? arguments,
    JsonObject backendState,
  ) {
    switch (command) {
      case ControllerCommand.setSourceProject:
        return BackendCall(
          BackendMethod.setSourceProject,
          Map<String, Object?>.from(arguments! as Map),
        );
      case ControllerCommand.startSourceTask:
        return BackendCall(
          BackendMethod.startSourceTask,
          Map<String, Object?>.from(arguments! as Map),
        );
      case ControllerCommand.cancelSourceTask:
        return const BackendCall(BackendMethod.cancelSourceTask);
      case ControllerCommand.clearSourceOutput:
        return null;
      case ControllerCommand.toggleConnection:
        return const BackendCall(BackendMethod.toggleConnection);
      case ControllerCommand.loadSymbols:
        return BackendCall(
          BackendMethod.loadSymbols,
          arguments is Map
              ? Map<String, Object?>.from(arguments)
              : {'path': arguments},
        );
      case ControllerCommand.setSampleRate:
        return BackendCall(BackendMethod.setConfig, {
          'sampleRateHz': arguments,
        });
      case ControllerCommand.setMonitorRate:
        return BackendCall(BackendMethod.setConfig, {
          'monitorRateHz': arguments,
        });
      case ControllerCommand.setRttSampleRate:
        return BackendCall(BackendMethod.setConfig, {
          'rttSampleRateHz': arguments,
        });
      case ControllerCommand.setProbeType:
        return BackendCall(BackendMethod.setConfig, {'probeType': arguments});
      case ControllerCommand.setTargetName:
        return BackendCall(BackendMethod.setConfig, {'targetName': arguments});
      case ControllerCommand.setSwdClock:
        return BackendCall(BackendMethod.setConfig, {'swdClock': arguments});
      case ControllerCommand.setSerialNumber:
        return BackendCall(BackendMethod.setConfig, {
          'serialNumber': arguments,
        });
      case ControllerCommand.setConnectionKind:
        return BackendCall(BackendMethod.setConfig, {
          'connectionKind': arguments,
        });
      case ControllerCommand.setRemoteConfig:
        return BackendCall(BackendMethod.setConfig, {
          'remoteConfig': arguments,
        });
      case ControllerCommand.toggleSampling:
        return BackendCall(BackendMethod.setSamplingPaused, {
          'paused': !(backendState['samplingPaused'] == true),
        });
      case ControllerCommand.setSamplingPaused:
        return BackendCall(BackendMethod.setSamplingPaused, {
          'paused': arguments == true,
        });
      case ControllerCommand.toggleRtt:
        return BackendCall(BackendMethod.setRtt, {
          'enabled': arguments == true,
          'protocol': backendState['rttProtocol'] ?? 'normal',
          'rateHz': backendState['rttSampleRateHz'] ?? 1000,
        });
      case ControllerCommand.setRttProtocol:
        return BackendCall(BackendMethod.setRtt, {
          'enabled': backendState['rttEnabled'] == true,
          'protocol': arguments,
          'rateHz': backendState['rttSampleRateHz'] ?? 1000,
        });
      case ControllerCommand.clearSamples:
        return const BackendCall(BackendMethod.clearSamples);
      case ControllerCommand.resetTarget:
        return BackendCall(BackendMethod.resetTarget, {
          'halt': arguments == true,
        });
      case ControllerCommand.setBreakpoints:
        return BackendCall(
          BackendMethod.setBreakpoints,
          Map<String, Object?>.from(arguments! as Map),
        );
      case ControllerCommand.debugControl:
        return BackendCall(BackendMethod.debugControl, {'action': arguments});
      case ControllerCommand.exportCsv:
        return BackendCall(BackendMethod.exportCsv, {'path': arguments});
      case ControllerCommand.setWatches:
        return BackendCall(
          BackendMethod.setWatches,
          Map<String, Object?>.from(arguments! as Map),
        );
      case ControllerCommand.writeWatch:
        return BackendCall(
          BackendMethod.writeWatch,
          Map<String, Object?>.from(arguments! as Map),
        );
      case ControllerCommand.readWatch:
        return BackendCall(BackendMethod.readWatch, {'key': arguments});
      case ControllerCommand.setDisplayRefreshMode:
      case ControllerCommand.setUiScale:
      case ControllerCommand.setSourceRoot:
      case ControllerCommand.addSourceFile:
      case ControllerCommand.openSourceFile:
      case ControllerCommand.closeSourceFile:
      case ControllerCommand.markSourceFileRead:
      case ControllerCommand.dismissSourceAttention:
      case ControllerCommand.setSourceViewVisible:
      case ControllerCommand.togglePlotting:
      case ControllerCommand.toggleFollowLatest:
      case ControllerCommand.setPlotViewport:
      case ControllerCommand.configurePlotView:
      case ControllerCommand.showAllPlotSamples:
      case ControllerCommand.resetPlotView:
      case ControllerCommand.clearLogs:
      case ControllerCommand.toggleSymbol:
      case ControllerCommand.selectSymbols:
      case ControllerCommand.activateSymbol:
      case ControllerCommand.addSelectedToWatch:
      case ControllerCommand.removeWatch:
      case ControllerCommand.removeWatches:
      case ControllerCommand.undoWatchDeletion:
      case ControllerCommand.reorderWatch:
      case ControllerCommand.clearWatches:
      case ControllerCommand.toggleWatchSampling:
      case ControllerCommand.setWatchReadMode:
      case ControllerCommand.setWatchMonitorRate:
      case ControllerCommand.toggleWatchPlot:
      case ControllerCommand.setWatchColor:
      case ControllerCommand.setWatchColors:
      case ControllerCommand.setOnlyWatchesPlotted:
      case ControllerCommand.setAllWatchesPlotted:
      case ControllerCommand.invertWatchPlots:
      case ControllerCommand.updateAnalysisSession:
        return null;
    }
  }

  static BackendCall setWatches(JsonObject params) {
    return BackendCall(BackendMethod.setWatches, params);
  }
}
