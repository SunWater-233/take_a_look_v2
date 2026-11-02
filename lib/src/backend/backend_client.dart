import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backend_transport.dart';
import '../protocol/commands.dart';
import '../protocol/events.dart';
import '../telemetry/raw_recording.dart';

export 'backend_transport.dart';
export '../app/file_pickers.dart';

typedef BackendEventHandler =
    void Function(BackendEventType event, Object? params);

class _QueuedWatchWrite {
  _QueuedWatchWrite(this.params);

  final Map<String, Object?> params;
  final completion = Completer<void>();
}

class BackendException implements Exception {
  const BackendException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => details == null ? message : '$message ($details)';
}

class BackendClient {
  BackendClient({
    this.eventHandler,
    this.commandTimeout = const Duration(seconds: 30),
    this.symbolLoadTimeout = const Duration(minutes: 11),
    this.processStarter,
  });

  static const protocolVersion = 2;

  BackendEventHandler? eventHandler;
  final Duration commandTimeout;
  // The parser has a ten-minute deadline and checks it before committing.
  // Leave time for it to return its structured error without killing a probe.
  final Duration symbolLoadTimeout;
  final Future<Process> Function()? processStarter;
  Process? _process;
  Future<void>? _starting;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  BackendStreamDecoder? _streamDecoder;
  Future<void> _writeTail = Future<void>.value();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<_QueuedWatchWrite> _watchWrites = [];
  bool _supportsBatchWrites = false;
  final Map<int, List<String>> _sampleSchemas = {};
  final Set<int> _captureOnlySchemas = {};
  Map<String, dynamic> _state = {};
  int _nextRequestId = 1;
  int? _lastSampleSequence;
  bool _closing = false;
  bool _closed = false;

  bool get isRunning => _process != null;

  Future<JsonObject> emberRequest(String operation, JsonObject arguments) =>
      request(BackendMethod.ember, {...arguments, 'operation': operation});

  Future<Map<String, Object?>> targetCatalogRequest(
    String operation,
    Map<String, Object?> arguments,
  ) {
    final method = switch (operation) {
      'listTargets' => BackendMethod.listTargets,
      'onlineTargetPacks' => BackendMethod.onlineTargetPacks,
      'inspectTargetPack' => BackendMethod.inspectTargetPack,
      'importTargetPack' => BackendMethod.importTargetPack,
      'discardTargetPackPreview' => BackendMethod.discardTargetPackPreview,
      'removeTargetPack' => BackendMethod.removeTargetPack,
      'selectTarget' => BackendMethod.selectTarget,
      _ => throw ArgumentError.value(operation, 'operation'),
    };
    return request(method, arguments);
  }

  Future<void> start() {
    if (_starting case final starting?) return starting;
    if (_process != null) return Future<void>.value();
    return _starting = _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    _closed = false;
    try {
      final backendDirectory = _findBackendDirectory();
      final launch = _pythonLaunch(backendDirectory);
      final process =
          await (processStarter?.call() ??
              Process.start(
                launch.executable,
                launch.arguments,
                workingDirectory: backendDirectory.path,
                environment: {
                  ...Platform.environment,
                  'PYTHONPATH': backendDirectory.path,
                  'PYTHONUTF8': '1',
                  'TAL_PARENT_PID': '$pid',
                  'TAL_HOST_PYTHONPATH':
                      Platform.environment['PYTHONPATH'] ?? '',
                  'TAL_HOST_PYTHONUTF8':
                      Platform.environment['PYTHONUTF8'] ?? '',
                  'TAL_RECORDINGS_DIR':
                      RawSampleRecording.defaultDirectory.path,
                },
                runInShell: launch.runInShell,
              ));
      _process = process;
      _writeTail = Future<void>.value();
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
            final log = decodeBackendStderrLine(line);
            if (log != null) {
              eventHandler?.call(BackendEventType.log, {
                'level': log.level,
                'message': '后端：${log.message}',
              });
            }
          });
      unawaited(process.exitCode.then(_handleExit));
      final handshake = await request(BackendMethod.handshake);
      _supportsBatchWrites =
          (handshake['capabilities'] as List?)?.contains('memoryWriteBatch') ==
          true;
      final state = _map(handshake['state']);
      if (state != null) {
        _state = state;
        eventHandler?.call(BackendEventType.state, state);
      }
      eventHandler?.call(BackendEventType.log, {
        'level': 'info',
        'message': '本机硬件后端已启动，协议版本 $protocolVersion',
      });
    } catch (error) {
      await close(force: true);
      eventHandler?.call(BackendEventType.error, {
        'code': 'startup_failed',
        'message': '无法启动本机硬件后端。',
        'details': error.toString(),
      });
    }
  }

  Future<void> command(ControllerCommand command, Object? arguments) async {
    try {
      if (_starting case final starting?) await starting;
      final call = BackendCommandMapper.translate(command, arguments, _state);
      if (call == null) return;
      if (command == ControllerCommand.writeWatch && _supportsBatchWrites) {
        final write = _QueuedWatchWrite(Map.of(call.params));
        _watchWrites.add(write);
        if (_watchWrites.length == 1) scheduleMicrotask(_flushWatchWrites);
        await write.completion.future;
      } else {
        await request(call.method, call.params);
      }
    } catch (error) {
      // These operations await completion and own error feedback in the controller.
      if (const {
        ControllerCommand.loadSymbols,
        ControllerCommand.configureProject,
        ControllerCommand.setSourceProject,
        ControllerCommand.startSourceTask,
        ControllerCommand.cancelSourceTask,
        ControllerCommand.writeWatch,
      }.contains(command)) {
        rethrow;
      }
      if (error is BackendException) {
        eventHandler?.call(BackendEventType.error, {
          'code': error.code,
          'message': error.message,
          if (error.details != null) 'details': error.details,
        });
      } else {
        eventHandler?.call(BackendEventType.error, {
          'code': 'command_failed',
          'message': '后端命令失败。',
          'details': error.toString(),
        });
      }
    }
  }

  /// Project restoration awaits each operation and reports any failure once.
  Future<void> projectCommand(
    ControllerCommand command,
    Object? arguments,
  ) async {
    if (_starting case final starting?) await starting;
    final call = BackendCommandMapper.translate(command, arguments, _state);
    if (call == null) throw StateError('Unsupported project command: $command');
    await request(call.method, call.params);
  }

  Future<Map<String, dynamic>> request(
    BackendMethod method, [
    Map<String, Object?> params = const {},
  ]) {
    // Flush synchronously into the existing stdin queue so a following pause,
    // reset or configuration command cannot overtake an explicit write.
    _flushWatchWrites();
    return _request(method, params);
  }

  void _flushWatchWrites() {
    if (_watchWrites.isEmpty) return;
    final writes = List<_QueuedWatchWrite>.of(_watchWrites);
    _watchWrites.clear();
    var start = 0;
    while (start < writes.length) {
      final keys = <Object?>{};
      var end = start;
      while (end < writes.length &&
          end - start < 64 &&
          keys.add(writes[end].params['key'])) {
        end++;
      }
      final group = writes.sublist(start, end);
      final method = group.length == 1
          ? BackendMethod.writeWatch
          : BackendMethod.writeWatches;
      final params = group.length == 1
          ? group.single.params
          : <String, Object?>{
              'writes': [for (final write in group) write.params],
            };
      unawaited(
        _request(method, params).then<void>(
          (_) {
            for (final write in group) {
              write.completion.complete();
            }
          },
          onError: (Object error, StackTrace stack) {
            for (final write in group) {
              write.completion.completeError(error, stack);
            }
          },
        ),
      );
      start = end;
    }
  }

  Future<Map<String, dynamic>> _request(
    BackendMethod method,
    Map<String, Object?> params,
  ) async {
    // Handshake establishes readiness; shutdown must also work during startup.
    if (method != BackendMethod.handshake && method != BackendMethod.shutdown) {
      if (_starting case final starting?) await starting;
    }
    final process = _process;
    if (process == null) {
      throw const BackendException('not_running', '本机硬件后端尚未启动。');
    }
    final requestId = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    try {
      // Listen to the response before yielding for stdin.flush(): a fast
      // protocol error or process exit can arrive while the pipe is flushing.
      final response = completer.future.timeout(
        method == BackendMethod.loadSymbols
            ? symbolLoadTimeout
            : const {
                BackendMethod.listTargets,
                BackendMethod.inspectTargetPack,
                BackendMethod.importTargetPack,
              }.contains(method)
            ? const Duration(minutes: 5)
            : commandTimeout,
        onTimeout: () =>
            throw BackendException('timeout', '后端命令超时：${method.wireName}'),
      );
      // IOSink cannot accept another write while flush() is binding its
      // stream. Serialize writes only; responses may complete independently.
      _writeTail = _writeTail.then((_) async {
        if (!identical(_process, process) ||
            !identical(_pending[requestId], completer)) {
          return;
        }
        try {
          process.stdin.writeln(
            jsonEncode({
              'v': protocolVersion,
              'id': requestId,
              'method': method.wireName,
              'params': params,
            }),
          );
          await process.stdin.flush();
        } catch (error, stack) {
          // Complete the response too, so a failed send cancels its timeout
          // immediately and leaves the write queue usable for later requests.
          if (!completer.isCompleted) completer.completeError(error, stack);
        }
      });
      return await response;
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<void> close({bool force = false}) async {
    if (_closing) return;
    _closing = true;
    final process = _process;
    if (process != null && !force) {
      try {
        await request(
          BackendMethod.shutdown,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (force) process?.kill();
    await _writeTail;
    await process?.stdin.close();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _process = null;
    _streamDecoder = null;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _sampleSchemas.clear();
    _supportsBatchWrites = false;
    _captureOnlySchemas.clear();
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
          final patch = _map(params);
          if (patch != null) _state = {..._state, ...patch};
        }
        eventHandler?.call(BackendEventType.parse(event), params);
        return;
      }
      final id = message['id'];
      if (id is! int) throw const FormatException('Response id is missing');
      final completer = _pending[id];
      if (completer == null) return;
      final error = _map(message['error']);
      if (error != null) {
        _pending.remove(id);
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
      if (state != null) _state = {..._state, ...state};
      _pending.remove(id);
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
    if (schema?['captureOnly'] == true) _captureOnlySchemas.add(id);
    if (_sampleSchemas.length > 8) {
      _captureOnlySchemas.remove(_sampleSchemas.keys.first);
      _sampleSchemas.remove(_sampleSchemas.keys.first);
    }
  }

  void _handleSamplePayload(Uint8List payload) {
    final schemaId = backendSampleSchemaId(payload);
    final keys = _sampleSchemas[schemaId];
    if (keys == null) {
      throw FormatException('Unknown backend sample schema $schemaId');
    }
    final batch = decodeBackendSamplePayload(
      payload,
      keys,
      captureOnly: _captureOnlySchemas.contains(schemaId),
    );
    final previousSequence = _lastSampleSequence;
    if (previousSequence != null &&
        batch.sequence != ((previousSequence + 1) & 0xFFFFFFFF)) {
      eventHandler?.call(BackendEventType.log, {
        'level': 'warning',
        'message': '后端采样序号不连续：$previousSequence -> ${batch.sequence}',
      });
    }
    _lastSampleSequence = batch.sequence;
    eventHandler?.call(BackendEventType.samples, batch);
  }

  void _handleTransportError(Object error) {
    final failure = BackendException(
      'protocol_error',
      '后端协议错误。',
      error.toString(),
    );
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(failure);
    }
    _pending.clear();
    eventHandler?.call(BackendEventType.error, {
      'code': 'protocol_error',
      'message': '后端协议错误。',
      'details': error.toString(),
    });
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
    eventHandler?.call(BackendEventType.state, _state);
    eventHandler?.call(BackendEventType.error, {
      'code': 'process_exited',
      'message': '本机硬件后端意外退出。',
      'details': '退出代码：$exitCode',
    });
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
    // A checkout runs current sources; ignored frozen output may be older.
    // Packaged applications have no development virtual environment.
    final sourceCandidates = <File>[
      if (override != null && override.isNotEmpty) File(override),
      File(
        '${backendDirectory.path}${Platform.pathSeparator}.venv${Platform.pathSeparator}'
        '${Platform.isWindows ? 'Scripts' : 'bin'}${Platform.pathSeparator}$executable',
      ),
    ];
    for (final candidate in sourceCandidates) {
      if (candidate.existsSync()) {
        return _PythonLaunch(
          candidate.absolute.path,
          arguments: const ['-m', 'take_a_look_backend.stdio'],
        );
      }
    }
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
      File(
        '${backendDirectory.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}$executable',
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
