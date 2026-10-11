part of 'controller.dart';

const _snapshotFields = <String>{
  'connectionStatus',
  'probeType',
  'targetName',
  'swdClock',
  'serialNumber',
  'connectionKind',
  'gatewayProtocolVersion',
  'remoteConfig',
  'symbolFile',
  'symbolLoad',
  'sampleRateHz',
  'rttSampleRateHz',
  'displayRefreshMode',
  'samplingElapsedSeconds',
  'elapsedSeconds',
  'samplingPaused',
  'rawRecording',
  'plottingPaused',
  'plotHighlightedWatchKey',
  'plotWatchSelectionRevision',
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
  'plotWindowEndSeconds',
  'uiScale',
  'lastBackendError',
  'selectedSymbols',
  'symbols',
  'watches',
  'logs',
  'analysisSession',
  'sourceWorkspace',
  'debug',
};

extension TakeALookControllerSync on TakeALookController {
  void setPresentationActive(bool active, {bool releaseHistory = false}) {
    _presentationActive = active;
    _resetPlotRefreshSchedule();
    _reconcileSamplingClock();
    if (!active && releaseHistory && _isDetachedRemote) {
      for (final watch in _watches) {
        watch.samples.clear();
      }
      _frozenPlotSamples.clear();
      analysisSession.clearData();
      signals.analysis.emit();
    }
  }

  Map<String, int> snapshotVersions() => {
    for (final key in _snapshotFields)
      key: key == 'symbols' ? symbolRevision : _stateFieldRevisions[key] ?? 0,
  };

  void _touchSnapshotFields(Iterable<String> fields) {
    final revision = ++_stateRevision;
    for (final key in fields) {
      if (_snapshotFields.contains(key)) _stateFieldRevisions[key] = revision;
    }
  }

  void _recordStateChanges(Set<ControllerSignal> changes) {
    _touchSnapshotFields({
      'uiScale',
      'elapsedSeconds',
      'samplingElapsedSeconds',
      if (changes.contains(signals.connection)) ...{
        'connectionStatus',
        'probeType',
        'targetName',
        'swdClock',
        'serialNumber',
        'connectionKind',
        'gatewayProtocolVersion',
        'remoteConfig',
        'lastBackendError',
        'symbolFile',
      },
      if (changes.contains(signals.sampling)) ...{
        'sampleRateHz',
        'rttSampleRateHz',
        'samplingPaused',
        'rawRecording',
        'rttEnabled',
        'rttProtocol',
      },
      if (changes.contains(signals.symbols)) ...{
        'selectedSymbols',
        'symbolFile',
      },
      if (changes.contains(signals.watches)) 'watches',
      if (changes.contains(signals.plot) ||
          changes.contains(signals.plotControls)) ...{
        'displayRefreshMode',
        'plottingPaused',
        'plotHighlightedWatchKey',
        'plotWatchSelectionRevision',
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
        'plotWindowEndSeconds',
      },
      if (changes.contains(signals.logs)) 'logs',
      if (changes.contains(signals.analysis)) 'analysisSession',
      if (changes.contains(signals.debug)) 'debug',
      if (changes.contains(signals.sourceWorkspace)) 'sourceWorkspace',
    });
  }

  JsonObject stateDeltaSnapshot(
    Map<String, int> acknowledged, {
    bool includeAnalysisData = false,
  }) {
    final versions = snapshotVersions();
    final fields = {
      for (final key in _snapshotFields)
        if (acknowledged[key] != versions[key]) key,
    };
    return _encodeSnapshot(
      includeSamples: false,
      fields: fields,
      packedSamples: true,
      includeAnalysisData: includeAnalysisData,
    );
  }

  int get analysisDataRevision => _analysisDataRevision;
}

int _sampleWireLength(Object? samples) => samples is Float64List
    ? samples.length ~/ 2
    : (samples as List?)?.length ?? 0;

void _appendWireSamples(SampleBuffer target, Object? samples, {int skip = 0}) {
  if (samples is Float64List) {
    if (samples.length.isOdd) {
      throw const FormatException('Invalid sample pairs');
    }
    for (var i = skip * 2; i < samples.length; i += 2) {
      target.addXY(samples[i], samples[i + 1]);
    }
  } else {
    for (final raw in (samples as List? ?? const []).skip(skip)) {
      final point = raw as List;
      target.addXY((point[0] as num).toDouble(), (point[1] as num).toDouble());
    }
  }
}
