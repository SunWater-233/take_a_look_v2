import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backend_transport.dart';
import '../protocol/commands.dart';
import '../protocol/events.dart';

export 'backend_transport.dart';
export '../app/file_pickers.dart';

typedef BackendEventHandler =
    void Function(BackendEventType event, Object? params);

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
                },
                runInShell: launch.runInShell,
              ));
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
      final state = _map(handshake['state']);
      if (state != null) {
        _state = state;
        eventHandler?.call(BackendEventType.state, state);
      }
      eventHandler?.call(BackendEventType.log, {
        'level': 'info',
        'message': '本机硬件后端已启动，协议版本 $protocolVersion。',
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
      final call = BackendCommandMapper.translate(command, arguments, _state);
      if (call == null) return;
      await request(call.method, call.params);
    } catch (error) {
      // Loading owns its lifecycle in the controller, including error feedback.
      if (command == ControllerCommand.loadSymbols) rethrow;
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

  Future<Map<String, dynamic>> request(
    BackendMethod method, [
    Map<String, Object?> params = const {},
  ]) async {
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
            : commandTimeout,
        onTimeout: () =>
            throw BackendException('timeout', '后端命令超时：${method.wireName}'),
      );
      final results = await Future.wait<dynamic>([
        response,
        Future<void>.sync(() async {
          process.stdin.writeln(
            jsonEncode({
              'v': protocolVersion,
              'id': requestId,
              'method': method.wireName,
              'params': params,
            }),
          );
          await process.stdin.flush();
        }),
      ]);
      return results.first as Map<String, dynamic>;
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
