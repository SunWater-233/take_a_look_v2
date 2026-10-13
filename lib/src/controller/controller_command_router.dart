import 'package:flutter/material.dart';

import 'controller.dart';
import '../protocol/commands.dart';

/// Executes commands arriving from detached windows.
///
/// Transport parsing is deliberately outside [TakeALookController], leaving
/// the controller focused on state transitions and domain operations.
Future<JsonObject> executeControllerCommand(
  TakeALookController controller,
  ControllerCommand command,
  Object? arguments, {
  bool includeResultState = true,
}) async {
  switch (command) {
    case ControllerCommand.setSourceProject:
      await controller.saveSourceProject(Map<String, dynamic>.from(arguments! as Map));
    case ControllerCommand.startSourceTask:
      await controller.startSourceTask((arguments! as Map)['kind'] as String);
    case ControllerCommand.cancelSourceTask:
      await controller.cancelSourceTask();
    case ControllerCommand.clearSourceOutput:
      controller.clearSourceOutput();
    case ControllerCommand.toggleConnection:
      await controller.toggleConnection();
    case ControllerCommand.loadSymbols:
      if (arguments is String && arguments.isNotEmpty) {
        controller.loadSymbolsFromPath(arguments);
      } else {
        await controller.chooseSymbolFile();
      }
    case ControllerCommand.setSampleRate:
      controller.setSampleRate((arguments as num).toDouble());
    case ControllerCommand.setDisplayRefreshMode:
      controller.setDisplayRefreshMode(arguments as String);
    case ControllerCommand.setRttSampleRate:
      controller.setRttSampleRate((arguments as num).toDouble());
    case ControllerCommand.setProbeType:
      controller.setProbeType(arguments as String);
    case ControllerCommand.setTargetName:
      controller.setTargetName(arguments as String);
    case ControllerCommand.setSwdClock:
      controller.setSwdClock(arguments as String);
    case ControllerCommand.setSerialNumber:
      controller.setSerialNumber(arguments as String);
    case ControllerCommand.setConnectionKind:
      controller.setConnectionKind(arguments as String);
    case ControllerCommand.setRemoteConfig:
      controller.setRemoteConfig(Map<String, String>.from(arguments! as Map));
    case ControllerCommand.setUiScale:
      controller.setUiScale((arguments as num).toDouble());
    case ControllerCommand.toggleSampling:
      controller.toggleSampling();
    case ControllerCommand.setSamplingPaused:
      if (controller.samplingPaused != (arguments == true)) {
        controller.toggleSampling();
      }
    case ControllerCommand.togglePlotting:
      controller.togglePlotting();
    case ControllerCommand.toggleRtt:
      controller.toggleRtt(arguments == true);
    case ControllerCommand.setRttProtocol:
      controller.setRttProtocol(arguments as String);
    case ControllerCommand.toggleFollowLatest:
      controller.toggleFollowLatest();
    case ControllerCommand.setPlotViewport:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.setPlotViewport(
        xMin: (values['xMin'] as num).toDouble(),
        xMax: (values['xMax'] as num).toDouble(),
        yMin: (values['yMin'] as num?)?.toDouble(),
        yMax: (values['yMax'] as num?)?.toDouble(),
        preserveFollowLatest: values['preserveFollowLatest'] == true,
      );
    case ControllerCommand.configurePlotView:
      controller.configurePlotView(
        Map<String, dynamic>.from(arguments! as Map),
      );
    case ControllerCommand.showAllPlotSamples:
      controller.showAllPlotSamples();
    case ControllerCommand.resetPlotView:
      controller.resetPlotView();
    case ControllerCommand.clearSamples:
      controller.clearSamples();
    case ControllerCommand.clearLogs:
      controller.clearLogs();
    case ControllerCommand.resetTarget:
      controller.resetTarget(halt: arguments == true);
    case ControllerCommand.setSourceRoot:
      if (arguments is String) {
        controller.setSourceRoot(arguments);
      } else {
        await controller.chooseSourceRoot();
      }
    case ControllerCommand.addSourceFile:
      controller.addSourceFileFromSymbols(arguments as String);
    case ControllerCommand.openSourceFile:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.openSourceFile(
        values['path'] as String,
        select: values['select'] != false,
      );
    case ControllerCommand.closeSourceFile:
      controller.closeSourceFile(arguments as String);
    case ControllerCommand.markSourceFileRead:
      controller.markSourceFileRead(arguments as String);
    case ControllerCommand.dismissSourceAttention:
      controller.dismissSourceAttention();
    case ControllerCommand.setSourceViewVisible:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.setSourceViewVisible(
        values['viewId'] as String,
        values['visible'] == true,
      );
    case ControllerCommand.setBreakpoints:
      final values = Map<String, Object?>.from(arguments! as Map);
      final path = values['path'] as String;
      final requested = (values['lines'] as List).cast<int>().toSet();
      controller.setBreakpoints(path, requested);
    case ControllerCommand.debugControl:
      switch (arguments) {
        case 'halt':
          controller.haltTarget();
        case 'resume':
          controller.resumeTarget();
        case 'step':
          controller.stepTarget();
      }
    case ControllerCommand.exportCsv:
      await controller.exportCsv();
    case ControllerCommand.toggleSymbol:
      controller.toggleSymbol(arguments as String);
    case ControllerCommand.selectSymbols:
      controller.selectSymbols((arguments as List).cast<String>());
    case ControllerCommand.activateSymbol:
      controller.activateSymbol(arguments as String);
    case ControllerCommand.addSelectedToWatch:
      controller.addSelectedToWatch();
    case ControllerCommand.removeWatch:
      controller.removeWatch(arguments as String);
    case ControllerCommand.removeWatches:
      controller.removeWatches((arguments as List).cast<String>());
    case ControllerCommand.reorderWatch:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.reorderWatch(
        values['oldIndex'] as int,
        values['newIndex'] as int,
      );
    case ControllerCommand.clearWatches:
      controller.clearWatches();
    case ControllerCommand.toggleWatchSampling:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.toggleWatchSampling(
        values['key'] as String,
        values['value'] as bool,
      );
    case ControllerCommand.toggleWatchPlot:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.toggleWatchPlot(
        values['key'] as String,
        values['value'] as bool,
      );
    case ControllerCommand.setWatchColor:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.setWatchColor(
        values['key'] as String,
        Color(values['color'] as int),
      );
    case ControllerCommand.setWatchColors:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.setWatchColors(
        (values['keys'] as List).cast<String>(),
        Color(values['color'] as int),
      );
    case ControllerCommand.setOnlyWatchesPlotted:
      controller.setOnlyWatchesPlotted((arguments as List).cast<String>());
    case ControllerCommand.setAllWatchesPlotted:
      controller.setAllWatchesPlotted(arguments as bool);
    case ControllerCommand.invertWatchPlots:
      controller.invertWatchPlots((arguments as List).cast<String>());
    case ControllerCommand.updateAnalysisSession:
      controller.applyAnalysisSession(
        Map<String, dynamic>.from(arguments! as Map),
      );
    case ControllerCommand.writeWatch:
      final values = Map<String, Object?>.from(arguments! as Map);
      controller.writeWatch(values['key'] as String, values['value'] as String);
    case ControllerCommand.setWatches:
      throw UnsupportedError('setWatches is an internal backend command');
  }
  return includeResultState ? controller.stateSnapshot() : <String, dynamic>{};
}
