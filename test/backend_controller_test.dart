import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';

void main() {
  test('controller maps backend state, commands, and sample events', () async {
    final commands = <(ControllerCommand, Object?)>[];
    final controller = TakeALookController(
      backendCommand: (method, arguments) async {
        commands.add((method, arguments));
      },
      symbolFilePicker: () async => r'C:\firmware\motor.axf',
      csvExportPathPicker: () async => r'C:\capture\samples.csv',
    );
    addTearDown(controller.dispose);

    await controller.chooseSymbolFile();
    expect(commands.removeAt(0), (
      ControllerCommand.loadSymbols,
      r'C:\firmware\motor.axf',
    ));

    controller.applyBackendEvent(BackendEventType.state, {
      'connectionStatus': 'connected',
      'symbolFile': r'C:\firmware\motor.axf',
      'sampleRateHz': 200,
      'rttSampleRateHz': 1000,
      'samplingPaused': false,
      'rttEnabled': false,
      'rttProtocol': 'normal',
      'elapsedSeconds': 0,
      'symbols': [
        {
          'key': '20000000:speed',
          'source': 'main.c',
          'name': 'speed',
          'address': 0x20000000,
          'type': 'float',
          'size': 4,
        },
        {
          'key': 'rtt:1:JScope_f4:1',
          'source': 'RTT 数据/JScope_f4',
          'name': 'RTT Data 1 (float)',
          'address': 0,
          'type': 'float',
          'size': 4,
          'writable': false,
          'dataSource': 'rtt',
        },
      ],
      'watches': <Object>[],
    });
    expect(controller.connectionStatus, ConnectionStatus.connected);
    expect(controller.symbols.first.name, 'speed');
    expect(controller.symbols.last.key, 'rtt:1:JScope_f4:1');
    expect(controller.symbols.last.addressLabel, 'RTT');
    expect(controller.symbols.last.writable, isFalse);

    controller.toggleSymbol(controller.symbols.first.key);
    controller.addSelectedToWatch();
    expect(commands.single.$1, ControllerCommand.setWatches);
    final watchPayload = Map<String, dynamic>.from(commands.single.$2! as Map);
    expect(watchPayload['watches'], hasLength(1));
    commands.clear();

    controller.setWatchColor(
      controller.watches.single.symbol.key,
      const Color(0xFF2F6FED),
    );
    expect(commands.single.$1, ControllerCommand.setWatches);
    final colorPayload = Map<String, dynamic>.from(commands.single.$2! as Map);
    final colorWatches = (colorPayload['watches'] as List).cast<Map>();
    expect(colorWatches.single['color'], '#ff2f6fed');
    commands.clear();

    controller.toggleSampling();
    expect(controller.samplingPaused, isTrue);
    expect(commands.single, (ControllerCommand.setSamplingPaused, true));
    commands.clear();
    controller.applyBackendEvent(BackendEventType.state, {
      'samplingPaused': true,
      'elapsedSeconds': 0,
    });
    expect(controller.connectionStatus, ConnectionStatus.connected);
    expect(controller.symbols, hasLength(2));
    expect(controller.watches, hasLength(1));

    controller.applyBackendEvent(BackendEventType.samples, {
      'frames': [
        {
          'elapsed': 0.25,
          'values': {'20000000:speed': 12.5},
        },
      ],
    });
    expect(controller.elapsedSeconds, 0.25);
    expect(controller.watches.single.value, 12.5);
    expect(controller.watches.single.samples.single.dx, 0.25);

    controller.applyBackendEvent(
      BackendEventType.samplesCleared,
      const <String, Object?>{},
    );
    expect(controller.elapsedSeconds, 0);
    expect(controller.watches.single.samples, isEmpty);

    controller.applyBackendEvent(
      BackendEventType.samples,
      BackendSampleBatch(
        schemaId: 1,
        sequence: 1,
        keys: const ['20000000:speed'],
        elapsedSeconds: Float64List.fromList([0.5]),
        values: Float64List.fromList([13.25]),
        validity: Uint8List.fromList([1]),
        validityBytesPerFrame: 1,
      ),
    );
    expect(controller.elapsedSeconds, 0.5);
    expect(controller.watches.single.value, 13.25);
    expect(controller.watches.single.samples.single.dy, 13.25);

    controller.applyBackendEvent(BackendEventType.perf, {
      'effectiveHz': 198.5,
      'sampleCount': 199,
      'readBlockCount': 1,
    });
    expect(controller.performanceStats['effectiveHz'], 198.5);
    expect(controller.logs.last.message, contains('采样性能'));

    final logCountAfterPerformanceSample = controller.logs.length;
    controller.applyBackendEvent(BackendEventType.perf, {
      'effectiveHz': 0.0,
      'sampleCount': 0,
      'readBlockCount': 0,
    });
    expect(controller.logs, hasLength(logCountAfterPerformanceSample));

    controller.applyBackendEvent(BackendEventType.error, {
      'code': 'connect_failed',
      'message': '连接失败。',
      'details': '未找到探针',
    });
    expect(controller.lastBackendError?['code'], 'connect_failed');
    expect(controller.logs.last.message, contains('未找到探针'));

    controller.writeWatch(controller.watches.single.symbol.key, '13.5');
    controller.setRttProtocol('plus');
    await controller.exportCsv();
    expect(commands.map((item) => item.$1), [
      ControllerCommand.writeWatch,
      ControllerCommand.setRttProtocol,
      ControllerCommand.exportCsv,
    ]);
  });

  test('backend state updates do not reset local plot controls', () {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.togglePlotting();
    controller.toggleFollowLatest();

    controller.applyBackendEvent(BackendEventType.state, {
      'connectionStatus': 'disconnected',
      'sampleRateHz': 50,
      'rttSampleRateHz': 1000,
      'samplingPaused': false,
      'rttEnabled': false,
      'elapsedSeconds': 0,
      'symbols': <Object>[],
      'watches': <Object>[],
    });

    expect(controller.plottingPaused, isTrue);
    expect(controller.followLatest, isFalse);
  });
}
