part of 'controller.dart';

extension TakeALookControllerPlot on TakeALookController {
  double get maximumPlotWindowSeconds => math.max(120, elapsedSeconds);

  void preparePlotHistory({double? pixelWidth}) {
    if (pixelWidth != null && pixelWidth.isFinite && pixelWidth > 0) {
      _plotPixelWidth = pixelWidth;
    }
    final end = plotWindowEndSeconds;
    final start = math.max(0.0, end - plotVisibleWindowSeconds);
    final plotted = _watches.where((watch) => watch.plotted).toList();
    plotHistory.update(
      path: rawRecording['historyPath'] as String?,
      keys: [for (final watch in plotted) watch.symbol.key],
      start: start,
      end: math.max(start + 0.2, end),
      sourceEnd: elapsedSeconds,
      pixelWidth: _plotPixelWidth,
      enabled:
          _presentationActive &&
          (plottingPaused ||
              !followLatest ||
              plotted.any(
                (watch) =>
                    watch.samples.isNotEmpty &&
                    watch.samples.first.dx > start &&
                    watch.totalSampleCount > watch.samples.length,
              )),
    );
  }

  void setPlotHighlightedWatch(String? key, {bool selectWatchRow = false}) {
    if (key == plotHighlightedWatchKey && !selectWatchRow) return;
    if (key != null && _watchByKey(key) == null) return;
    configurePlotView({
      'plotHighlightedWatchKey': key,
      if (selectWatchRow) 'selectWatchRow': true,
    });
  }

  void togglePlotting() {
    if (_dispatchRemote(ControllerCommand.togglePlotting)) return;
    plottingPaused = !plottingPaused;
    _resetPlotRefreshSchedule();
    if (plottingPaused) {
      _freezePlotIfNeeded();
    } else if (followLatest) {
      _clearFrozenPlot();
    } else {
      _frozenPlotSamples.clear();
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
      _freezePlotViewportIfNeeded();
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
    bool preserveFollowLatest = false,
  }) {
    final arguments = <String, Object?>{
      'xMin': xMin,
      'xMax': xMax,
      'yMin': ?yMin,
      'yMax': ?yMax,
      if (preserveFollowLatest) 'preserveFollowLatest': true,
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
    final keepFollowing = preserveFollowLatest && followLatest;
    final span =
        (keepFollowing ? (xMax - xMin).abs() : normalizedXMax - normalizedXMin)
            .clamp(0.2, maximumPlotWindowSeconds)
            .toDouble();
    final latest = math.max(elapsedSeconds, span);
    final end = normalizedXMax.clamp(span, latest).toDouble();
    plotVisibleWindowSeconds = span;
    if (keepFollowing) {
      if (!plottingPaused) _clearFrozenPlot();
    } else {
      if (followLatest) _freezePlotViewportIfNeeded();
      followLatest = false;
      _frozenPlotEndSeconds = end;
    }
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
    final retention = (values['plotRetentionSeconds'] as num?)?.toDouble();
    if (retention != null && retention.isFinite && retention > 0) {
      state.plot.retentionSeconds = retention.clamp(1, 120).toDouble();
      _configurePlotRetention();
    }
    if (values.containsKey('plotHighlightedWatchKey')) {
      final key = values['plotHighlightedWatchKey'] as String?;
      state.plot.highlightedWatchKey = key != null && _watchByKey(key) != null
          ? key
          : null;
    }
    final selectWatchRow = values['selectWatchRow'] == true;
    if (selectWatchRow) state.plot.watchSelectionRevision += 1;
    if (values.containsKey('followLatest')) {
      final nextFollowLatest = values['followLatest'] == true;
      if (nextFollowLatest != followLatest) {
        if (nextFollowLatest && !plottingPaused) {
          _clearFrozenPlot();
        } else {
          _freezePlotViewportIfNeeded();
        }
        followLatest = nextFollowLatest;
      }
    }
    final xMin = (values['xMin'] as num?)?.toDouble();
    final xMax = (values['xMax'] as num?)?.toDouble();
    if (xMin != null && xMax != null && xMin.isFinite && xMax > xMin) {
      plotVisibleWindowSeconds = (xMax - xMin)
          .clamp(0.2, maximumPlotWindowSeconds)
          .toDouble();
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
    _emitState([
      signals.plot,
      signals.plotControls,
      if (selectWatchRow) signals.watches,
    ]);
  }

  void showAllPlotSamples() {
    if (_isDetachedRemote &&
        _dispatchRemote(ControllerCommand.showAllPlotSamples)) {
      return;
    }
    if (followLatest) _freezePlotViewportIfNeeded();
    followLatest = false;
    var first = double.infinity;
    var last = -double.infinity;
    if (rawRecording['historyPath'] is String) {
      first = 0;
      last = elapsedSeconds;
    } else {
      for (final watch in _watches.where((watch) => watch.plotted)) {
        final samples = watch.samples;
        if (samples.isEmpty) continue;
        if (samples.isOrdered) {
          first = math.min(first, samples.first.dx);
          last = math.max(last, samples.last.dx);
        } else {
          for (final point in samples) {
            first = math.min(first, point.dx);
            last = math.max(last, point.dx);
          }
        }
      }
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
