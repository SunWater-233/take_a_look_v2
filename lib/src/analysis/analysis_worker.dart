import 'dart:async';
import 'dart:isolate';

import 'analysis_data.dart';
import 'analysis_fft.dart';

/// One resident analysis isolate, with at most one active and one pending job.
/// Superseded requests resolve to null. Sampling never waits on this worker.
class FftAnalysisWorker {
  Isolate? _isolate;
  ReceivePort? _responses;
  SendPort? _commands;
  Completer<void>? _ready;
  Future<void>? _startup;
  _FftRequest? _active;
  _FftRequest? _pending;
  List<AnalysisPoint>? _loadedSignal;
  List<AnalysisPoint>? _loadedTime;
  bool _dispatching = false;
  bool _disposed = false;
  int _sequence = 0;
  int _datasetUploadCount = 0;

  int get datasetUploadCount => _datasetUploadCount;

  Future<AnalysisSpectrum?> analyze(
    List<AnalysisPoint> signal, {
    List<AnalysisPoint>? timePoints,
    double? selectionStart,
    double? selectionEnd,
    AnalysisWindowFunction window = AnalysisWindowFunction.hann,
    bool removeDc = true,
  }) {
    if (_disposed) {
      return Future.error(StateError('Analysis worker is disposed'));
    }
    _active?.supersede();
    _pending?.supersede();
    final request = _FftRequest(
      ++_sequence,
      signal,
      timePoints,
      selectionStart,
      selectionEnd,
      window,
      removeDc,
    );
    _pending = request;
    unawaited(_dispatch());
    return request.result.future;
  }

  void cancel() {
    _sequence++;
    _pending?.supersede();
    _pending = null;
    _active?.supersede();
  }

  void clearData() {
    cancel();
    _loadedSignal = _loadedTime = null;
    _commands?.send({'method': 'clear'});
  }

  Future<void> _dispatch() async {
    if (_disposed || _dispatching || _active != null || _pending == null) {
      return;
    }
    _dispatching = true;
    try {
      await _ensureStarted();
      if (_disposed || _pending == null) return;
      final request = _pending!;
      _pending = null;
      _active = request;
      final reload =
          !identical(request.signal, _loadedSignal) ||
          !identical(request.time, _loadedTime);
      _commands!.send({
        'method': 'analyze',
        'id': request.id,
        'reload': reload,
        if (reload) 'signal': _transferPoints(request.signal),
        if (reload)
          'time': request.time == null ? null : _transferPoints(request.time!),
        'start': request.start,
        'end': request.end,
        'window': request.window.index,
        'removeDc': request.removeDc,
      });
      if (reload) _datasetUploadCount++;
      _loadedSignal = request.signal;
      _loadedTime = request.time;
    } catch (error) {
      _fail(error);
    } finally {
      _dispatching = false;
      if (!_disposed && _active == null && _pending != null) {
        unawaited(_dispatch());
      }
    }
  }

  Future<void> _ensureStarted() {
    if (_startup != null) return _startup!;
    final ready = Completer<void>();
    final responses = ReceivePort();
    _ready = ready;
    _startup = ready.future;
    _responses = responses;
    responses.listen((message) {
      if (identical(_responses, responses)) _receive(message);
    });
    unawaited(
      Isolate.spawn(
        _runAnalysisWorker,
        responses.sendPort,
        onError: responses.sendPort,
        onExit: responses.sendPort,
        errorsAreFatal: true,
        debugName: 'fft-analysis',
      ).then(
        (isolate) {
          if (_disposed || !identical(_responses, responses)) {
            isolate.kill(priority: Isolate.immediate);
          } else {
            _isolate = isolate;
          }
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_responses, responses)) _fail(error);
        },
      ),
    );
    return ready.future;
  }

  void _receive(Object? message) {
    if (_disposed) return;
    if (message is SendPort) {
      _commands = message;
      _ready?.complete();
      return;
    }
    if (message is! Map) {
      _fail(StateError('Analysis worker exited: $message'));
      return;
    }
    final request = _active;
    if (request == null || message['id'] != request.id) return;
    _active = null;
    if (!request.result.isCompleted && request.id == _sequence) {
      try {
        final failure = message['failure'];
        if (failure != null) throw StateError('$failure');
        request.result.complete(_decodeSpectrum(message));
      } catch (error, stack) {
        request.result.completeError(error, stack);
      }
    } else {
      request.supersede();
    }
    unawaited(_dispatch());
  }

  void _fail(Object error) {
    if (_disposed) return;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    for (final request in [_active, _pending]) {
      if (request != null && !request.result.isCompleted) {
        request.result.completeError(error);
      }
    }
    _active = _pending = null;
    _loadedSignal = _loadedTime = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _responses?.close();
    _responses = null;
    _commands = null;
    _ready = null;
    _startup = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();
    _isolate?.kill(priority: Isolate.immediate);
    _responses?.close();
    _loadedSignal = _loadedTime = null;
    _active = null;
  }
}

class _FftRequest {
  _FftRequest(
    this.id,
    this.signal,
    this.time,
    this.start,
    this.end,
    this.window,
    this.removeDc,
  );
  final int id;
  final List<AnalysisPoint> signal;
  final List<AnalysisPoint>? time;
  final double? start;
  final double? end;
  final AnalysisWindowFunction window;
  final bool removeDc;
  final Completer<AnalysisSpectrum?> result = Completer();
  void supersede() {
    if (!result.isCompleted) result.complete(null);
  }
}

TransferableTypedData _transferPoints(List<AnalysisPoint> points) {
  final packed = packAnalysisPoints(points);
  return TransferableTypedData.fromList([packed.buffer.asUint8List()]);
}

AnalysisSpectrum _decodeSpectrum(Map message) {
  final error = message['error'] as String?;
  if (error != null) return AnalysisSpectrum.error(error);
  final rate = message['sampleRate'] as double;
  final size = message['fftSize'] as int;
  final amplitudes = (message['amplitudes'] as TransferableTypedData)
      .materialize()
      .asFloat64List();
  return AnalysisSpectrum(
    points: UniformAnalysisPoints(amplitudes, step: rate / size),
    sampleRate: rate,
    sampleCount: message['sampleCount'] as int,
    fftSize: size,
    resampled: message['resampled'] as bool,
    peakFrequency: message['peakFrequency'] as double,
    peakAmplitude: message['peakAmplitude'] as double,
  );
}

void _runAnalysisWorker(SendPort responses) {
  final commands = ReceivePort();
  List<AnalysisPoint>? signal;
  List<AnalysisPoint>? time;
  responses.send(commands.sendPort);
  commands.listen((raw) {
    final message = raw as Map;
    if (message['method'] == 'clear') {
      signal = time = null;
      return;
    }
    final id = message['id'];
    try {
      if (message['reload'] == true) {
        signal = PackedAnalysisPoints(
          (message['signal'] as TransferableTypedData)
              .materialize()
              .asFloat64List(),
        );
        final rawTime = message['time'] as TransferableTypedData?;
        time = rawTime == null
            ? null
            : PackedAnalysisPoints(rawTime.materialize().asFloat64List());
      }
      final spectrum = analysisSpectrumForSeries(
        signal!,
        timePoints: time,
        selectionStart: message['start'] as double?,
        selectionEnd: message['end'] as double?,
        window: AnalysisWindowFunction.values[message['window'] as int],
        removeDc: message['removeDc'] as bool,
      );
      if (spectrum.error != null) {
        responses.send({'id': id, 'error': spectrum.error});
        return;
      }
      final values = (spectrum.points as UniformAnalysisPoints).values;
      responses.send({
        'id': id,
        'amplitudes': TransferableTypedData.fromList([
          values.buffer.asUint8List(values.offsetInBytes, values.lengthInBytes),
        ]),
        'sampleRate': spectrum.sampleRate,
        'sampleCount': spectrum.sampleCount,
        'fftSize': spectrum.fftSize,
        'resampled': spectrum.resampled,
        'peakFrequency': spectrum.peakFrequency,
        'peakAmplitude': spectrum.peakAmplitude,
      });
    } catch (error) {
      responses.send({'id': id, 'failure': '$error'});
    }
  });
}
