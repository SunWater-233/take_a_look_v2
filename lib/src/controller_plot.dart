part of 'controller.dart';

extension TakeALookControllerPlot on TakeALookController {
  void togglePlotting() {
    if (_dispatchRemote(ControllerCommand.togglePlotting)) return;
    plottingPaused = !plottingPaused;
    _resetPlotRefreshSchedule();
    if (plottingPaused) {
      _freezePlotIfNeeded();
    } else if (followLatest) {
      _clearFrozenPlot();
    }
    _appendLog(plottingPaused ? '绘图已暂停，后台继续采样。' : '绘图已恢复。');
    _emitState([signals.plot, signals.plotControls, signals.logs]);
  }

  void toggleRtt(bool value) {
    if (_dispatchCommand(ControllerCommand.toggleRtt, value)) return;
    rttEnabled = value;
    _appendLog(value ? 'RTT 采样已启用。' : 'RTT 采样已关闭。');
    _emitState([signals.sampling, signals.logs]);
  }

  void setRttProtocol(String value) {
    if (value != 'normal' && value != 'plus') return;
    if (_dispatchCommand(ControllerCommand.setRttProtocol, value)) return;
    rttProtocol = value;
    _appendLog('RTT 协议已设置为 ${value == 'normal' ? 'RTT-Normal' : 'RTT-Plus'}。');
    _emitState([signals.sampling, signals.logs]);
  }

  void toggleFollowLatest() {
    if (_dispatchRemote(ControllerCommand.toggleFollowLatest)) return;
    _resetPlotRefreshSchedule();
    if (followLatest) {
      _freezePlotIfNeeded();
    } else if (!plottingPaused) {
      _clearFrozenPlot();
    }
    followLatest = !followLatest;
    _emitState([signals.plot, signals.plotControls]);
  }

  void setPlotViewport({
    required double xMin,
    required double xMax,
    double? yMin,
    double? yMax,
  }) {
    final arguments = <String, double>{
      'xMin': xMin,
      'xMax': xMax,
      'yMin': ?yMin,
      'yMax': ?yMax,
    };
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.setPlotViewport, arguments)) {
      return;
    }
    final normalizedXMin = math.max(0, math.min(xMin, xMax));
    final normalizedXMax = math.max(
      normalizedXMin + 0.001,
      math.max(xMin, xMax),
    );
    final span = (normalizedXMax - normalizedXMin).clamp(0.2, 120).toDouble();
    final latest = math.max(elapsedSeconds, span);
    final end = normalizedXMax.clamp(span, latest).toDouble();
    if (followLatest) _freezePlotIfNeeded();
    followLatest = false;
    plotVisibleWindowSeconds = span;
    _frozenPlotEndSeconds = end;
    if (yMin != null &&
        yMax != null &&
        yMin.isFinite &&
        yMax.isFinite &&
        yMax > yMin) {
      plotAutoY = false;
      plotYMin = yMin;
      plotYMax = yMax;
    }
    _emitState([signals.plot, signals.plotControls]);
  }

  void configurePlotView(Map<String, dynamic> values) {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.configurePlotView, values)) {
      return;
    }
    if (values.containsKey('followLatest')) {
      final nextFollowLatest = values['followLatest'] == true;
      if (nextFollowLatest != followLatest) {
        if (nextFollowLatest && !plottingPaused) {
          _clearFrozenPlot();
        } else {
          _freezePlotIfNeeded();
        }
        followLatest = nextFollowLatest;
      }
    }
    final xMin = (values['xMin'] as num?)?.toDouble();
    final xMax = (values['xMax'] as num?)?.toDouble();
    if (xMin != null && xMax != null && xMin.isFinite && xMax > xMin) {
      plotVisibleWindowSeconds = (xMax - xMin).clamp(0.2, 120).toDouble();
      _frozenPlotEndSeconds = xMax;
    }
    if (values.containsKey('plotAutoY')) {
      plotAutoY = values['plotAutoY'] == true;
    }
    final yMin = (values['yMin'] as num?)?.toDouble();
    final yMax = (values['yMax'] as num?)?.toDouble();
    if (yMin != null && yMax != null && yMin.isFinite && yMax > yMin) {
      plotYMin = yMin;
      plotYMax = yMax;
    }
    if (values.containsKey('plotShowGrid')) {
      plotShowGrid = values['plotShowGrid'] == true;
    }
    if (values.containsKey('plotShowLegend')) {
      plotShowLegend = values['plotShowLegend'] == true;
    }
    if (values.containsKey('plotMouseXEnabled')) {
      plotMouseXEnabled = values['plotMouseXEnabled'] == true;
    }
    if (values.containsKey('plotMouseYEnabled')) {
      plotMouseYEnabled = values['plotMouseYEnabled'] == true;
    }
    if (values.containsKey('plotInvertX')) {
      plotInvertX = values['plotInvertX'] == true;
    }
    if (values.containsKey('plotInvertY')) {
      plotInvertY = values['plotInvertY'] == true;
    }
    _emitState([signals.plot, signals.plotControls]);
  }

  void showAllPlotSamples() {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.showAllPlotSamples)) {
      return;
    }
    if (followLatest) _freezePlotIfNeeded();
    followLatest = false;
    final plottedSamples = _watches
        .where((watch) => watch.plotted)
        .expand((watch) => watch.samples);
    var first = double.infinity;
    var last = -double.infinity;
    for (final point in plottedSamples) {
      first = math.min(first, point.dx);
      last = math.max(last, point.dx);
    }
    if (!first.isFinite || !last.isFinite) {
      first = 0;
      last = math.max(0.2, elapsedSeconds);
    }
    plotVisibleWindowSeconds = math.max(0.2, last - math.max(0, first));
    _frozenPlotEndSeconds = math.max(last, plotVisibleWindowSeconds);
    plotAutoY = true;
    plotYMin = null;
    plotYMax = null;
    _emitState([signals.plot, signals.plotControls]);
  }

  void resetPlotView() {
    if (_isDetachedRemote && _dispatchRemote(ControllerCommand.resetPlotView)) {
      return;
    }
    followLatest = true;
    plotVisibleWindowSeconds = 12;
    plotAutoY = true;
    plotYMin = null;
    plotYMax = null;
    plotShowGrid = true;
    plotShowLegend = true;
    plotMouseXEnabled = true;
    plotMouseYEnabled = true;
    plotInvertX = false;
    plotInvertY = false;
    if (!plottingPaused) _clearFrozenPlot();
    _emitState([signals.plot, signals.plotControls]);
  }
}
