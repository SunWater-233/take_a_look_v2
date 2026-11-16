import 'dart:async';

import '../controller/controller.dart';

typedef WindowStateSender =
    Future<void> Function(String method, Map<String, dynamic> data);

/// One ordered channel per window. Slow recipients keep one pending request,
/// not a queue of serialized histories; only acknowledged cursors advance.
class WindowSyncTarget {
  WindowSyncTarget(this.controller, this.send);
  final TakeALookController controller;
  final WindowStateSender send;
  Map<String, int> _versions = {};
  Map<String, int> _cursors = {};
  int _telemetryEpoch = -1;
  int _analysisRevision = -1;
  bool active = false;
  bool history = true;
  bool analysis = false;
  bool _initialized = false;
  bool _sending = false;
  bool _disposed = false;
  bool _statePending = false;
  bool _telemetryPending = false;
  Completer<void>? _fullPending;
  Completer<void>? _stateBarrier;
  Completer<void>? _drained;
  Timer? _retry;

  Future<void> get settled => _drained?.future ?? Future<void>.value();

  Future<void> initialize({
    required bool includeHistory,
    required bool includeAnalysis,
  }) {
    history = includeHistory;
    analysis = includeAnalysis;
    final previous = _fullPending;
    final full = Completer<void>();
    _fullPending = full;
    // Configuration is normally serial. Concurrent callers share the next
    // complete snapshot rather than leaving an obsolete initialization pending.
    if (previous != null) {
      full.future.then(previous.complete, onError: previous.completeError);
    }
    _retry?.cancel();
    _kick();
    return full.future;
  }

  void requestState() {
    if (_disposed) return;
    _statePending = true;
    _kick();
  }

  Future<void> flushState() {
    final barrier = _stateBarrier ??= Completer<void>();
    requestState();
    return barrier.future;
  }

  void requestTelemetry() {
    if (_disposed) return;
    _telemetryPending = true;
    _kick();
  }

  void _kick() {
    if (_disposed || _sending || _retry?.isActive == true) return;
    final drained = Completer<void>();
    _drained = drained;
    _sending = true;
    unawaited(_pump(drained));
  }

  Future<void> _pump(Completer<void> drained) async {
    try {
      while (!_disposed &&
          (_fullPending != null || _statePending || _telemetryPending)) {
        final full = _fullPending;
        final barrier = _stateBarrier;
        final stateWanted = _statePending;
        final telemetryWanted = _telemetryPending;
        _fullPending = null;
        _stateBarrier = null;
        _statePending = _telemetryPending = false;
        try {
          if (full != null || !_initialized) {
            final versions = controller.snapshotVersions();
            final cursors = controller.telemetryCursors();
            final epoch = controller.samplingEpoch;
            final analysisRevision = controller.analysisDataRevision;
            final data = controller.snapshot(
              includeSamples: history,
              packedSamples: true,
              includeAnalysisData: analysis,
            );
            if (!history) data['discardSampleHistory'] = true;
            await send('state', data);
            _versions = versions;
            _cursors = cursors;
            _telemetryEpoch = epoch;
            _analysisRevision = analysis ? analysisRevision : -1;
            _initialized = true;
            full?.complete();
            barrier?.complete();
          } else {
            // Metadata is delivered before samples using that watch schema.
            if (stateWanted ||
                controller.snapshotVersions()['watches'] !=
                    _versions['watches'] ||
                controller.snapshotVersions()['symbols'] !=
                    _versions['symbols']) {
              final versions = controller.snapshotVersions();
              final analysisRevision = controller.analysisDataRevision;
              final data = controller.stateDeltaSnapshot(
                _versions,
                includeAnalysisData:
                    analysis && analysisRevision != _analysisRevision,
              );
              if (data.isNotEmpty) await send('state', data);
              if (data['watches'] case final List watches) {
                final keys = watches
                    .map((watch) => (watch as Map)['key'])
                    .toSet();
                // Once a row disappears, the replica has released its buffer.
                // Undo must send its complete retained tail, even if no
                // telemetry message was sent between deletion and restoration.
                _cursors.removeWhere((key, _) => !keys.contains(key));
              }
              _versions = versions;
              if (analysis) _analysisRevision = analysisRevision;
            }
            barrier?.complete();
            if (telemetryWanted) {
              final current = controller.snapshotVersions();
              if (current['watches'] != _versions['watches'] ||
                  current['symbols'] != _versions['symbols']) {
                _statePending = _telemetryPending = true;
                continue;
              }
              final epoch = controller.samplingEpoch;
              if (epoch != _telemetryEpoch) _cursors.clear();
              final data = controller.telemetryDeltaSnapshot(
                _cursors,
                packedSamples: true,
                includeSamples: history,
              );
              final cursors = controller.telemetryCursors();
              await send('telemetryDelta', data);
              _cursors = cursors;
              _telemetryEpoch = epoch;
            }
          }
        } catch (error, stack) {
          if (full != null && !full.isCompleted) {
            full.completeError(error, stack);
          }
          if (barrier != null && !barrier.isCompleted) {
            barrier.completeError(error, stack);
          }
          // Unacknowledged versions and sample cursors remain unchanged.
          _statePending = _telemetryPending = true;
          if (active && !_disposed) {
            _retry = Timer(const Duration(milliseconds: 80), _kick);
          }
          break;
        }
      }
    } finally {
      _sending = false;
      drained.complete();
    }
  }

  void deactivate() {
    active = false;
    _statePending = _telemetryPending = false;
    _retry?.cancel();
  }

  void dispose() {
    _disposed = true;
    deactivate();
    _fullPending?.complete();
    _fullPending = null;
    _stateBarrier?.complete();
    _stateBarrier = null;
  }
}
