part of 'controller.dart';

extension TakeALookControllerSync on TakeALookController {
  void setPresentationActive(bool active, {bool releaseHistory = false}) {
    _presentationActive = active;
    _resetPlotRefreshSchedule();
    _reconcileSamplingClock();
    if (!active && releaseHistory && _isDetachedRemote) {
      plotHistory.clear();
      for (final watch in _watches) {
        watch.samples.clear();
      }
      _frozenPlotSamples.clear();
      analysisSession.clearData();
      signals.analysis.emit();
    }
  }

  Map<String, int> snapshotVersions() =>
      _snapshotRevisions.versions(symbolRevision: symbolRevision);

  void _touchSnapshotFields(Iterable<String> fields) =>
      _snapshotRevisions.touch(fields);

  void _recordStateChanges(Set<ControllerSignal> changes) =>
      _snapshotRevisions.record({
        if (changes.contains(signals.connection)) SnapshotDomain.connection,
        if (changes.contains(signals.sampling)) SnapshotDomain.sampling,
        if (changes.contains(signals.targetCatalog))
          SnapshotDomain.targetCatalog,
        if (changes.contains(signals.symbols)) SnapshotDomain.symbols,
        if (changes.contains(signals.watches)) SnapshotDomain.watches,
        if (changes.contains(signals.plot) ||
            changes.contains(signals.plotControls))
          SnapshotDomain.plot,
        if (changes.contains(signals.logs)) SnapshotDomain.logs,
        if (changes.contains(signals.analysis)) SnapshotDomain.analysis,
        if (changes.contains(signals.debug)) SnapshotDomain.debug,
        if (changes.contains(signals.sourceWorkspace))
          SnapshotDomain.sourceWorkspace,
        if (changes.contains(signals.sourceTools)) SnapshotDomain.sourceTools,
      });

  JsonObject stateDeltaSnapshot(
    Map<String, int> acknowledged, {
    bool includeAnalysisData = false,
  }) {
    final versions = snapshotVersions();
    final fields = {
      for (final key in ControllerSnapshotSchema.fields)
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
