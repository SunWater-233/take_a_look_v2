import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

typedef BackendEventHandler = void Function(String event, Object? params);

class BackendException implements Exception {
  const BackendException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => details == null ? message : '$message ($details)';
}

class BackendClient {
  BackendClient({this.eventHandler});

  static const protocolVersion = 2;

  BackendEventHandler? eventHandler;
  Process? _process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  BackendStreamDecoder? _streamDecoder;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, List<String>> _sampleSchemas = {};
  Map<String, dynamic> _state = {};
  int _nextRequestId = 1;
  int? _lastSampleSequence;
  bool _closing = false;
  bool _closed = false;

  bool get isRunning => _process != null;

  Future<void> start() async {
    if (_process != null) return;
    _closed = false;
    try {
      final backendDirectory = _findBackendDirectory();
      final launch = _pythonLaunch(backendDirectory);
      final process = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: backendDirectory.path,
        environment: {
          ...Platform.environment,
          'PYTHONPATH': backendDirectory.path,
          'PYTHONUTF8': '1',
        },
        runInShell: launch.runInShell,
      );
      _process = process;
      _streamDecoder = BackendStreamDecoder(
        onJsonLine: _handleLine,
        onSamplePayload: _handleSamplePayload,
      );
      _stdoutSubscription = process.stdout.listen(
        _handleBytes,
        onError: _handleTransportError,
      );
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              eventHandler?.call('log', {
                'level': 'error',
                'message': '后端：${line.trim()}',
              });
            }
          });
      unawaited(process.exitCode.then(_handleExit));
      final handshake = await request('handshake');
      final state = _map(handshake['state']);
      if (state != null) {
        _state = state;
        eventHandler?.call('state', state);
      }
      eventHandler?.call('log', {
        'level': 'info',
        'message': '本机硬件后端已启动，协议版本 $protocolVersion。',
      });
    } catch (error) {
      await close(force: true);
      eventHandler?.call('error', {
        'code': 'startup_failed',
        'message': '无法启动本机硬件后端。',
        'details': error.toString(),
      });
    }
  }

  Future<void> command(String method, Object? arguments) async {
    try {
      final call = _translateCommand(method, arguments);
      if (call == null) return;
      await request(call.method, call.params);
    } catch (error) {
      if (error is BackendException) {
        eventHandler?.call('error', {
          'code': error.code,
          'message': error.message,
          if (error.details != null) 'details': error.details,
        });
      } else {
        eventHandler?.call('error', {
          'code': 'command_failed',
          'message': '后端命令失败。',
          'details': error.toString(),
        });
      }
    }
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final process = _process;
    if (process == null) {
      throw const BackendException('not_running', '本机硬件后端尚未启动。');
    }
    final requestId = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    process.stdin.writeln(
      jsonEncode({
        'v': protocolVersion,
        'id': requestId,
        'method': method,
        'params': params,
      }),
    );
    await process.stdin.flush();
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(requestId);
        throw BackendException('timeout', '后端命令超时：$method');
      },
    );
  }

  Future<void> close({bool force = false}) async {
    if (_closing) return;
    _closing = true;
    final process = _process;
    if (process != null && !force) {
      try {
        await request('shutdown').timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (force) process?.kill();
    await process?.stdin.close();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _process = null;
    _streamDecoder = null;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _sampleSchemas.clear();
    _lastSampleSequence = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(const BackendException('closed', '本机硬件后端已关闭。'));
      }
    }
    _pending.clear();
    _closed = true;
    _closing = false;
  }

  void _handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw const FormatException('Expected JSON object');
      final message = Map<String, dynamic>.from(decoded);
      if (message['v'] != protocolVersion) {
        throw FormatException('Unsupported backend protocol ${message['v']}');
      }
      final event = message['event'];
      if (event is String) {
        final params = message['params'];
        if (event == 'sampleSchema') {
          _handleSampleSchema(params);
          return;
        }
        if (event == 'state') {
          _state = _map(params) ?? _state;
        }
        eventHandler?.call(event, params);
        return;
      }
      final id = message['id'];
      if (id is! int) throw const FormatException('Response id is missing');
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = _map(message['error']);
      if (error != null) {
        completer.completeError(
          BackendException(
            error['code'] as String? ?? 'backend_error',
            error['message'] as String? ?? '后端命令失败。',
            error['details'],
          ),
        );
        return;
      }
      final result = _map(message['result']);
      if (result == null) {
        throw const FormatException('Response result is missing');
      }
      final state = _map(result['state']);
      if (state != null) _state = state;
      completer.complete(result);
    } catch (error) {
      _handleTransportError(error);
    }
  }

  void _handleBytes(List<int> bytes) {
    try {
      _streamDecoder?.add(bytes);
    } catch (error) {
      _streamDecoder?.reset();
      _handleTransportError(error);
    }
  }

  void _handleSampleSchema(Object? params) {
    final schema = _map(params);
    final id = schema?['id'];
    final rawKeys = schema?['keys'];
    if (id is! int ||
        rawKeys is! List ||
        rawKeys.any((key) => key is! String)) {
      throw const FormatException('Invalid backend sample schema');
    }
    _sampleSchemas[id] = List<String>.unmodifiable(rawKeys.cast<String>());
    if (_sampleSchemas.length > 8) {
      _sampleSchemas.remove(_sampleSchemas.keys.first);
    }
  }

  void _handleSamplePayload(Uint8List payload) {
    final schemaId = backendSampleSchemaId(payload);
    final keys = _sampleSchemas[schemaId];
    if (keys == null) {
      throw FormatException('Unknown backend sample schema $schemaId');
    }
    final batch = decodeBackendSamplePayload(payload, keys);
    final previousSequence = _lastSampleSequence;
    if (previousSequence != null &&
        batch.sequence != ((previousSequence + 1) & 0xFFFFFFFF)) {
      eventHandler?.call('log', {
        'level': 'warning',
        'message': '后端采样序号不连续：$previousSequence -> ${batch.sequence}',
      });
    }
    _lastSampleSequence = batch.sequence;
    eventHandler?.call('samples', batch);
  }

  void _handleTransportError(Object error) {
    eventHandler?.call('log', {'level': 'error', 'message': '后端协议错误：$error'});
  }

  void _handleExit(int exitCode) {
    if (_closing || _closed) return;
    _process = null;
    _state = {..._state, 'connectionStatus': 'disconnected'};
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          BackendException('process_exited', '本机硬件后端已退出，代码 $exitCode。'),
        );
      }
    }
    _pending.clear();
    eventHandler?.call('state', _state);
    eventHandler?.call('log', {
      'level': 'error',
      'message': '本机硬件后端意外退出，代码 $exitCode。',
    });
  }

  _BackendCall? _translateCommand(String method, Object? arguments) {
    switch (method) {
      case 'toggleConnection':
        return const _BackendCall('toggleConnection');
      case 'loadSymbols':
        return _BackendCall('loadSymbols', {'path': arguments});
      case 'setSampleRate':
        return _BackendCall('setConfig', {'sampleRateHz': arguments});
      case 'setRttSampleRate':
        return _BackendCall('setConfig', {'rttSampleRateHz': arguments});
      case 'setProbeType':
        return _BackendCall('setConfig', {'probeType': arguments});
      case 'setTargetName':
        return _BackendCall('setConfig', {'targetName': arguments});
      case 'setSwdClock':
        return _BackendCall('setConfig', {'swdClock': arguments});
      case 'setSerialNumber':
        return _BackendCall('setConfig', {'serialNumber': arguments});
      case 'toggleSampling':
        return _BackendCall('setSamplingPaused', {
          'paused': !(_state['samplingPaused'] == true),
        });
      case 'toggleRtt':
        return _BackendCall('setRtt', {
          'enabled': arguments == true,
          'protocol': _state['rttProtocol'] ?? 'normal',
          'rateHz': _state['rttSampleRateHz'] ?? 1000,
        });
      case 'setRttProtocol':
        return _BackendCall('setRtt', {
          'enabled': _state['rttEnabled'] == true,
          'protocol': arguments,
          'rateHz': _state['rttSampleRateHz'] ?? 1000,
        });
      case 'clearSamples':
        return const _BackendCall('clearSamples');
      case 'resetTarget':
        return _BackendCall('resetTarget', {'halt': arguments == true});
      case 'exportCsv':
        return _BackendCall('exportCsv', {'path': arguments});
      case 'setWatches':
      case 'writeWatch':
        return _BackendCall(
          method,
          Map<String, Object?>.from(arguments as Map),
        );
      default:
        return null;
    }
  }

  static Directory _findBackendDirectory() {
    final override = Platform.environment['TAKE_A_LOOK_BACKEND_DIR'];
    final candidates = <Directory>[
      if (override != null && override.isNotEmpty) Directory(override),
      Directory('${Directory.current.path}${Platform.pathSeparator}backend'),
      Directory(
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}backend',
      ),
      Directory(
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data'
        '${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}backend',
      ),
      Directory(
        '${File(Platform.resolvedExecutable).parent.parent.path}${Platform.pathSeparator}Frameworks'
        '${Platform.pathSeparator}App.framework${Platform.pathSeparator}Resources'
        '${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}backend',
      ),
    ];
    for (final candidate in candidates) {
      if (File(
        '${candidate.path}${Platform.pathSeparator}pyproject.toml',
      ).existsSync()) {
        return candidate.absolute;
      }
    }
    throw const BackendException(
      'backend_not_found',
      '没有找到 backend/pyproject.toml。可通过 TAKE_A_LOOK_BACKEND_DIR 指定路径。',
    );
  }

  static _PythonLaunch _pythonLaunch(Directory backendDirectory) {
    final override = Platform.environment['TAKE_A_LOOK_PYTHON'];
    final executable = Platform.isWindows ? 'python.exe' : 'python';
    final backendExecutable = Platform.isWindows
        ? 'take_a_look_backend.exe'
        : 'take_a_look_backend';
    final standaloneCandidates = <File>[
      File(
        '${backendDirectory.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}take_a_look_backend${Platform.pathSeparator}$backendExecutable',
      ),
      File(
        '${backendDirectory.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}$backendExecutable',
      ),
    ];
    for (final candidate in standaloneCandidates) {
      if (candidate.existsSync()) return _PythonLaunch(candidate.absolute.path);
    }
    final candidates = <File>[
      if (override != null && override.isNotEmpty) File(override),
      File(
        '${backendDirectory.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}$executable',
      ),
      File(
        '${backendDirectory.path}${Platform.pathSeparator}.venv${Platform.pathSeparator}'
        '${Platform.isWindows ? 'Scripts' : 'bin'}${Platform.pathSeparator}$executable',
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) {
        return _PythonLaunch(
          candidate.absolute.path,
          arguments: const ['-m', 'take_a_look_backend.stdio'],
        );
      }
    }
    return const _PythonLaunch(
      'python',
      arguments: ['-m', 'take_a_look_backend.stdio'],
      runInShell: true,
    );
  }

  static Map<String, dynamic>? _map(Object? value) {
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}

class BackendSampleBatch {
  const BackendSampleBatch({
    required this.schemaId,
    required this.sequence,
    required this.keys,
    required this.elapsedSeconds,
    required this.values,
    required this.validity,
    required this.validityBytesPerFrame,
  });

  final int schemaId;
  final int sequence;
  final List<String> keys;
  final Float64List elapsedSeconds;
  final Float64List values;
  final Uint8List validity;
  final int validityBytesPerFrame;

  int get frameCount => elapsedSeconds.length;
  int get variableCount => keys.length;

  bool hasValue(int frameIndex, int variableIndex) {
    final byte =
        validity[frameIndex * validityBytesPerFrame + variableIndex ~/ 8];
    return byte & (1 << (variableIndex % 8)) != 0;
  }

  double valueAt(int frameIndex, int variableIndex) {
    return values[frameIndex * variableCount + variableIndex];
  }
}

int backendSampleSchemaId(Uint8List payload) {
  if (payload.length < 15) {
    throw const FormatException('Backend sample payload is truncated');
  }
  return ByteData.sublistView(payload).getUint32(1, Endian.little);
}

BackendSampleBatch decodeBackendSamplePayload(
  Uint8List payload,
  List<String> keys,
) {
  if (payload.length < 15) {
    throw const FormatException('Backend sample payload is truncated');
  }
  final data = ByteData.sublistView(payload);
  if (data.getUint8(0) != 1) {
    throw FormatException(
      'Unsupported sample payload version ${data.getUint8(0)}',
    );
  }
  final schemaId = data.getUint32(1, Endian.little);
  final sequence = data.getUint32(5, Endian.little);
  final frameCount = data.getUint32(9, Endian.little);
  final variableCount = data.getUint16(13, Endian.little);
  if (variableCount != keys.length) {
    throw FormatException(
      'Sample schema $schemaId expected ${keys.length} values, got $variableCount',
    );
  }

  final validityBytes = (variableCount + 7) ~/ 8;
  final minimumFrameBytes = 8 + validityBytes;
  if (frameCount > (payload.length - 15) ~/ minimumFrameBytes) {
    throw const FormatException('Backend sample frame count is invalid');
  }
  if (frameCount * variableCount > 16 * 1024 * 1024) {
    throw const FormatException('Backend sample matrix is too large');
  }
  final elapsed = Float64List(frameCount);
  final values = Float64List(frameCount * variableCount);
  final validity = Uint8List(frameCount * validityBytes);
  var offset = 15;
  void requireBytes(int count) {
    if (offset + count > payload.length) {
      throw const FormatException('Backend sample payload is truncated');
    }
  }

  for (var frame = 0; frame < frameCount; frame += 1) {
    requireBytes(8 + validityBytes);
    elapsed[frame] = data.getFloat64(offset, Endian.little);
    offset += 8;
    final frameValidityOffset = frame * validityBytes;
    validity.setRange(
      frameValidityOffset,
      frameValidityOffset + validityBytes,
      payload,
      offset,
    );
    offset += validityBytes;
    for (var variable = 0; variable < variableCount; variable += 1) {
      final present =
          validity[frameValidityOffset + variable ~/ 8] &
              (1 << (variable % 8)) !=
          0;
      if (!present) continue;
      requireBytes(8);
      values[frame * variableCount + variable] = data.getFloat64(
        offset,
        Endian.little,
      );
      offset += 8;
    }
  }
  if (offset != payload.length) {
    throw const FormatException('Backend sample payload has trailing bytes');
  }
  return BackendSampleBatch(
    schemaId: schemaId,
    sequence: sequence,
    keys: List<String>.unmodifiable(keys),
    elapsedSeconds: elapsed,
    values: values,
    validity: validity,
    validityBytesPerFrame: validityBytes,
  );
}

class BackendStreamDecoder {
  BackendStreamDecoder({
    required this.onJsonLine,
    required this.onSamplePayload,
  });

  static const _maxPayloadLength = 64 * 1024 * 1024;

  final void Function(String line) onJsonLine;
  final void Function(Uint8List payload) onSamplePayload;
  Uint8List _buffer = Uint8List(4096);
  int _start = 0;
  int _end = 0;

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _ensureCapacity(bytes.length);
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;

    while (_start < _end) {
      if (_buffer[_start] == 0) {
        if (_end - _start < 5) break;
        final length = _uint32At(_start + 1);
        if (length > _maxPayloadLength) {
          throw FormatException('Backend frame is too large: $length bytes');
        }
        if (_end - _start < 5 + length) break;
        final payload = Uint8List.fromList(
          _buffer.sublist(_start + 5, _start + 5 + length),
        );
        _start += 5 + length;
        onSamplePayload(payload);
        continue;
      }

      var newline = _start;
      while (newline < _end && _buffer[newline] != 0x0A) {
        newline += 1;
      }
      if (newline == _end) break;
      var lineEnd = newline;
      if (lineEnd > _start && _buffer[lineEnd - 1] == 0x0D) {
        lineEnd -= 1;
      }
      final line = utf8.decode(_buffer.sublist(_start, lineEnd));
      _start = newline + 1;
      if (line.trim().isNotEmpty) onJsonLine(line);
    }
    _compactIfNeeded();
  }

  void reset() {
    _start = 0;
    _end = 0;
  }

  int _uint32At(int offset) {
    return _buffer[offset] |
        (_buffer[offset + 1] << 8) |
        (_buffer[offset + 2] << 16) |
        (_buffer[offset + 3] << 24);
  }

  void _ensureCapacity(int additionalBytes) {
    final required = _end + additionalBytes;
    if (required <= _buffer.length) return;
    if (_start > 0) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _start = 0;
    }
    if (_end + additionalBytes <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < _end + additionalBytes) {
      capacity *= 2;
    }
    final expanded = Uint8List(capacity)..setRange(0, _end, _buffer);
    _buffer = expanded;
  }

  void _compactIfNeeded() {
    if (_start == _end) {
      reset();
    } else if (_start > _buffer.length ~/ 2) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _start = 0;
    }
  }
}

Future<String?> pickSymbolFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'ELF/AXF 固件符号', extensions: ['elf', 'axf']),
    ],
  );
  return file?.path;
}

Future<String?> pickCsvExportPath() async {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final name =
      'raw_samples_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV 文件', extensions: ['csv']),
    ],
  );
  return location?.path;
}

class _BackendCall {
  const _BackendCall(this.method, [this.params = const {}]);

  final String method;
  final Map<String, Object?> params;
}

class _PythonLaunch {
  const _PythonLaunch(
    this.executable, {
    this.arguments = const [],
    this.runInShell = false,
  });

  final String executable;
  final List<String> arguments;
  final bool runInShell;
}
