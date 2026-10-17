import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../backend/backend_client.dart';
import '../controller/controller.dart';
import '../models/models.dart';
import '../protocol/commands.dart';
import '../protocol/events.dart';
import '../telemetry/raw_recording.dart';

enum UiTestScenario {
  live('实时波形'),
  dense('大量变量'),
  empty('空白状态'),
  disconnected('已断开');

  const UiTestScenario(this.label);
  final String label;
}

/// In-process fixtures behind the same command/event boundary as the backend.
/// This module is reachable only from main_ui_test.dart, never from main.dart.
class UiTestSession extends ChangeNotifier {
  UiTestSession({
    required this.sourcePath,
    this.stepDelay = const Duration(milliseconds: 300),
    Directory? recordingDirectory,
  }) : recording = RawSampleRecording(
         recordingDirectory ?? RawSampleRecording.defaultDirectory,
       ) {
    controller = TakeALookController(
      backendCommand: _command,
      symbolFilePicker: () async => 'ui_test_fixture.axf',
      sourceRootPicker: pickSourceRootDirectory,
      csvImportContentsPicker: pickCsvImportContents,
      csvImportPathPicker: pickCsvImportPath,
      csvExportPathPicker: pickCsvExportPath,
    );
    reset(UiTestScenario.live);
    _ticker = Timer.periodic(const Duration(milliseconds: 20), (_) => _tick());
  }

  final String sourcePath;
  final Duration stepDelay;
  final RawSampleRecording recording;
  late final TakeALookController controller;
  late final Timer _ticker;
  UiTestScenario scenario = UiTestScenario.live;
  final List<Map<String, String>> errors = [];
  final Map<String, double> _writtenValues = {};
  bool _disposed = false;
  bool _failNextLoad = false;
  int _generation = 0;
  double _sampleRemainder = 0;
  int _sourceLine = 10;

  static const sourceText = '''#include <stdint.h>

float speed_rpm = 0.0f;
float iq_ref = 0.0f;
float speed_pid_kp = 1.0f;
uint32_t can_rx_count = 0;

void motor_control_tick(void)
{
    float error = 1000.0f - speed_rpm;
    iq_ref = speed_pid_kp * error;
    speed_rpm += iq_ref * 0.001f;
    can_rx_count++;
}
''';

  List<SymbolItem> _symbols({required bool dense}) => [
    ...demoSymbols,
    if (dense)
      for (var index = 0; index < 500; index++)
        SymbolItem(
          source: 'control/axis_${index ~/ 32}/motor_control_with_long_name.c',
          name: 'axis_${index}_position_reference_with_long_name',
          address: 0x20001000 + index * 4,
          type: 'float',
          size: 4,
          section: '.bss',
        ),
  ];

  void reset(UiTestScenario next) {
    if (_disposed || controller.isSymbolLoading) return;
    if (!_rotateRecording()) return;
    _generation++;
    scenario = next;
    _sourceLine = 10;
    _sampleRemainder = 0;
    _writtenValues.clear();
    controller.applySnapshot({
      'connectionStatus': 'disconnected',
      'connectionKind': 'local',
      'serialNumber': 'UI-TEST',
      'gatewayProtocolVersion': null,
      'targetName': 'auto',
      'samplingPaused': false,
      'plottingPaused': false,
      'followLatest': true,
      'sampleRateHz': next == UiTestScenario.dense ? 1000 : 100,
      'rttEnabled': false,
      'rttProtocol': 'normal',
      'lastBackendError': null,
      'symbols': const [],
      'watches': const [],
      'logs': const [],
      'selectedSymbols': const [],
      'symbolFile': '',
      'elapsedSeconds': 0,
      'samplingElapsedSeconds': 0,
      'debug': {
        'executionState': 'unavailable',
        'sourceRoot': '',
        'sourceFiles': const [],
        'executableLines': const {},
        'breakpoints': const [],
        'registers': const {},
      },
    });
    controller.applyBackendSamplesCleared();
    controller.resetPlotView();
    controller.analysisSession.clearData();
    controller.commitAnalysisSession(includeData: true);
    controller.clearLogs();
    if (next != UiTestScenario.empty) {
      _loadFixture(dense: next == UiTestScenario.dense);
      controller.selectSymbols(
        controller.symbols
            .take(next == UiTestScenario.dense ? 32 : 6)
            .map((symbol) => symbol.key),
      );
      controller.addSelectedToWatch();
      if (next != UiTestScenario.disconnected) {
        controller.applySnapshot({'connectionStatus': 'connected'});
        _debug('running');
      }
      _appendFrames(400, 100);
    }
    controller.addLog('UI 测试版：${next.label}。连接、读写及采样全部使用模拟数据。');
    if (recording.path != null) controller.addLog('原始采样持续保存：${recording.path}');
    controller.addLog('可测试面板拖拽、独立窗口、变量菜单、图表缩放与源码断点。');
    notifyListeners();
  }

  void _loadFixture({bool dense = false}) {
    controller.applySnapshot({
      'symbols': _symbols(
        dense: dense,
      ).map((symbol) => symbol.toJson()).toList(),
      'symbolFile': 'ui_test_fixture.axf',
    });
    _debug(
      controller.connectionStatus == ConnectionStatus.connected
          ? 'running'
          : 'unavailable',
    );
  }

  Future<void> simulateLoad({bool fail = false}) async {
    if (_disposed || controller.isSymbolLoading) return;
    _failNextLoad = fail;
    await controller.loadSymbolsFromPath('ui_test_fixture.axf');
  }

  void injectDisconnect() {
    if (_disposed || controller.isSymbolLoading) return;
    _generation++;
    controller.applySnapshot({'connectionStatus': 'disconnected'});
    _debug('unavailable');
    _error('ui_test_disconnect', '模拟连接中断，可重新连接恢复采样。', 'UI 测试场景：连接在采样过程中断开。');
  }

  void _error(String code, String message, String details) {
    controller.applyBackendEvent(BackendEventType.error, {
      'code': code,
      'message': message,
      'details': details,
    });
  }

  Future<void> _command(ControllerCommand command, Object? arguments) async {
    if (_disposed) return;
    final call = BackendCommandMapper.translate(
      command,
      arguments,
      controller.stateSnapshot(),
    );
    switch (call?.method) {
      case BackendMethod.toggleConnection:
        if (controller.connectionStatus == ConnectionStatus.connecting) return;
        if (controller.connectionStatus == ConnectionStatus.connected) {
          controller.applySnapshot({'connectionStatus': 'disconnected'});
          _debug('unavailable');
          return;
        }
        final generation = _generation;
        controller.applySnapshot({
          'connectionStatus': 'connecting',
          'lastBackendError': null,
        });
        await Future<void>.delayed(stepDelay);
        if (_disposed || generation != _generation) return;
        controller.applySnapshot({'connectionStatus': 'connected'});
        _debug('running');
        controller.addLog('已连接模拟探针。');
      case BackendMethod.loadSymbols:
        final fail = _failNextLoad;
        _failNextLoad = false;
        for (final phase in [
          'check',
          'debug',
          'scan',
          'variables',
          'source',
          'ui',
        ]) {
          await Future<void>.delayed(stepDelay);
          if (_disposed) return;
          controller.applyBackendEvent(BackendEventType.symbolLoadProgress, {
            'loadId': call!.params['loadId'],
            'phase': phase,
            'current': 50,
            'total': 100,
          });
          if (fail && phase == 'variables') {
            throw const BackendException(
              'ui_test_load_failed',
              '模拟符号加载失败。',
              '用于检查进度关闭、错误提示和原有变量保留。',
            );
          }
        }
        _loadFixture(dense: scenario == UiTestScenario.dense);
        controller.addLog('模拟符号加载完成。');
      case BackendMethod.setConfig:
        controller.applySnapshot(call!.params);
      case BackendMethod.setSamplingPaused:
        if (call!.params['paused'] != true && recording.failure != null) {
          _recordingFailed(recording.failure!);
          return;
        }
        controller.applySnapshot({'samplingPaused': call.params['paused']});
      case BackendMethod.setRtt:
        controller.applySnapshot({
          'rttEnabled': call!.params['enabled'],
          'rttProtocol': call.params['protocol'],
          'rttSampleRateHz': call.params['rateHz'],
        });
      case BackendMethod.setWatches:
        // Watch membership, sampling and colors already live in the controller.
        break;
      case BackendMethod.clearSamples:
        if (!_rotateRecording()) return;
        controller.applyBackendSamplesCleared();
        controller.applySnapshot({'samplingElapsedSeconds': 0});
        _sampleRemainder = 0;
      case BackendMethod.writeWatch:
        final key = call!.params['key'];
        final value = double.tryParse(call.params['value'].toString());
        final watch = controller.watches
            .where((watch) => watch.symbol.key == key)
            .firstOrNull;
        if (controller.connectionStatus != ConnectionStatus.connected ||
            !controller.supportsMemoryWrite ||
            watch == null ||
            !watch.symbol.writable ||
            value == null ||
            !value.isFinite) {
          throw const BackendException(
            'ui_test_write_failed',
            '模拟变量写入失败。',
            '请连接模拟探针并输入有效数值。',
          );
        }
        _writtenValues[watch.symbol.key] = value;
        controller.applyWatchValues({
          'values': [
            {
              'key': watch.symbol.key,
              'value': value,
              'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
            },
          ],
        });
        controller.addLog('模拟写入 ${watch.symbol.name} = $value。');
      case BackendMethod.readWatch:
        final key = call!.params['key'];
        final index = controller.watches.indexWhere(
          (watch) => watch.symbol.key == key,
        );
        if (index < 0 ||
            controller.connectionStatus != ConnectionStatus.connected) {
          _error('ui_test_read_failed', '请先连接模拟探针。', '变量读取失败。');
          return;
        }
        final watch = controller.watches[index];
        controller.applyWatchValues({
          'values': [
            {
              'key': watch.symbol.key,
              'value':
                  _writtenValues[watch.symbol.key] ??
                  _value(watch.symbol, controller.elapsedSeconds, index),
              'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
            },
          ],
        });
      case BackendMethod.resetTarget:
        _sourceLine = 10;
        _debug(call!.params['halt'] == true ? 'halted' : 'running');
      case BackendMethod.debugControl:
        if (controller.connectionStatus != ConnectionStatus.connected) return;
        final action = call!.params['action'];
        if (action == 'step') {
          _sourceLine = _sourceLine >= 13 ? 10 : _sourceLine + 1;
        }
        _debug(action == 'resume' ? 'running' : 'halted');
      case BackendMethod.setBreakpoints:
        _debug(controller.debugState.executionState.name);
      case BackendMethod.exportCsv:
        try {
          final count = await recording.exportCsv(
            call!.params['path']! as String,
          );
          if (!_disposed) controller.addLog('已导出 $count 帧完整原始采样 CSV。');
        } catch (error) {
          if (!_disposed) {
            _error('ui_test_export_failed', 'CSV 导出失败。', '$error');
          }
        }
      default:
        _error('ui_test_unsupported', '测试版暂未模拟此操作。', command.name);
    }
    if (!_disposed) controller.signals.stateSync.emit();
  }

  void _debug(String execution) {
    final breakpoints = [
      for (final entry in controller.debugState.requestedBreakpoints.entries)
        for (final line in entry.value)
          {
            'path': entry.key,
            'requestedLine': line,
            'actualLine': line,
            'verified': true,
            'address': 0x08000100 + line * 2,
          },
    ];
    controller.applyBackendEvent(BackendEventType.debug, {
      'executionState': execution,
      'sourceFiles': [sourcePath],
      'executableLines': {
        sourcePath: [10, 11, 12, 13],
      },
      'breakpoints': breakpoints,
      'registers': execution == 'halted'
          ? {
              'r0': 1000,
              'r1': 42,
              'sp': 0x20010000,
              'pc': 0x08000100 + _sourceLine * 2,
            }
          : <String, int>{},
      'stoppedLocation': execution == 'halted'
          ? {
              'path': sourcePath,
              'line': _sourceLine,
              'address': 0x08000100 + _sourceLine * 2,
            }
          : null,
    });
  }

  void _tick() {
    if (_disposed ||
        controller.connectionStatus != ConnectionStatus.connected) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final monitored = <Map<String, Object>>[];
    for (final (index, watch) in controller.watches.indexed) {
      if (watch.readMode != WatchReadMode.monitor) continue;
      if (watch.updatedAtMs != null &&
          now - watch.updatedAtMs! < 1000 / controller.monitorRateFor(watch)) {
        continue;
      }
      monitored.add({
        'key': watch.symbol.key,
        'value':
            _writtenValues[watch.symbol.key] ??
            _value(watch.symbol, controller.elapsedSeconds, index),
        'updatedAtMs': now,
      });
    }
    if (monitored.isNotEmpty) {
      controller.applyWatchValues({'values': monitored});
    }
    if (controller.samplingPaused ||
        controller.debugState.executionState == DebugExecutionState.halted) {
      return;
    }
    final rate =
        (controller.rttEnabled
                ? controller.rttSampleRateHz
                : controller.sampleRateHz)
            .clamp(1, 10000)
            .toDouble();
    _sampleRemainder += rate * 0.02;
    final count = _sampleRemainder.floor();
    _sampleRemainder -= count;
    if (count > 0) _appendFrames(count, rate);
  }

  void _appendFrames(int count, double rate) {
    final start = controller.elapsedSeconds;
    final watches = controller.watches
        .where((watch) => watch.samplingEnabled)
        .toList();
    if (watches.isEmpty) return;
    final frames = <Map<String, Object>>[
      for (var frame = 1; frame <= count; frame++)
        {
          'elapsed': start + frame / rate,
          'values': {
            for (var index = 0; index < watches.length; index++)
              watches[index].symbol.key:
                  _writtenValues[watches[index].symbol.key] ??
                  _value(watches[index].symbol, start + frame / rate, index),
          },
        },
    ];
    _publishFrames(frames);
  }

  void _publishFrames(List<Map<String, Object>> frames) {
    final labels = {
      for (final watch in controller.watches)
        if (watch.samplingEnabled) watch.symbol.key: watch.symbol.name,
    };
    final recorded = [
      for (final frame in frames)
        {
          'elapsed': frame['elapsed']!,
          'values': <String, double>{
            for (final entry
                in (frame['values']! as Map<String, double>).entries)
              if (labels.containsKey(entry.key)) entry.key: entry.value,
          },
        },
    ];
    try {
      final previousPath = recording.path;
      recording.append(recorded, labels);
      controller.state.acquisition.rawRecording = recording.status;
      if (recording.path != previousPath) {
        controller.addLog('原始采样持续保存：${recording.path}');
      }
      controller.applyBackendSamples({'frames': frames, 'captureOnly': true});
    } catch (error) {
      _recordingFailed(error);
    }
  }

  bool _rotateRecording() {
    try {
      recording.rotate();
      controller.state.acquisition.rawRecording = recording.status;
      return true;
    } catch (error) {
      _recordingFailed(error);
      return false;
    }
  }

  void _recordingFailed(Object error) {
    controller.applySnapshot({
      'samplingPaused': true,
      'rawRecording': recording.status,
    });
    _error('raw_recording_failed', '原始记录写入失败，已暂停采样。', '$error');
  }

  double _value(SymbolItem symbol, double time, int index) {
    if (symbol.type == 'bool') return (time.floor() % 2).toDouble();
    if (symbol.type.contains('int')) {
      return (time * (index + 1)).floorToDouble();
    }
    return math.sin(time * (index + 1) * 1.7) * (index + 1) +
        math.cos(time * 13) * 0.12;
  }

  void recordError(Object error, StackTrace? stack) {
    if (errors.length >= 100) errors.removeAt(0);
    errors.add({
      'time': DateTime.now().toIso8601String(),
      'message': '$error',
      'stack': '$stack',
    });
  }

  Map<String, Object?> diagnostics() => {
    'mode': 'ui-test-synthetic',
    'capturedAt': DateTime.now().toIso8601String(),
    'scenario': scenario.name,
    'frameworkErrors': List.of(errors),
    // Do not export connection credentials or arbitrary user source text.
    'connectionStatus': controller.connectionStatus.name,
    'symbolCount': controller.symbols.length,
    'uiScale': controller.uiScale,
    'samplingPaused': controller.samplingPaused,
    'rawRecording': recording.status,
    'plotRetentionSeconds': controller.plotRetentionSeconds,
    'watches': [
      for (final watch in controller.watches)
        {
          'name': watch.symbol.name,
          'samples': watch.totalSampleCount,
          'plotSamples': watch.samples.length,
          'plotCapacity': watch.samples.capacity,
          'plotFirstTime': watch.samples.isEmpty
              ? null
              : watch.samples.first.dx,
          'plotLastTime': watch.samples.isEmpty ? null : watch.samples.last.dx,
          'sampling': watch.samplingEnabled,
        },
    ],
    'logs': [for (final entry in controller.logs) entry.toJson()],
  };

  Future<void> writeDiagnostics(File file, {bool? smokePassed}) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({...diagnostics(), 'smokePassed': ?smokePassed}),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _ticker.cancel();
    try {
      recording.close();
    } catch (error, stack) {
      recordError(error, stack);
    }
    controller.dispose();
    super.dispose();
  }
}
