import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/models.dart';

void main() {
  test('controller maps backend state, commands, and sample events', () async {
    final commands = <(String, Object?)>[];
    final controller = TakeALookController(
      backendCommand: (method, arguments) async {
        commands.add((method, arguments));
      },
      symbolFilePicker: () async => r'C:\firmware\motor.axf',
      csvExportPathPicker: () async => r'C:\capture\samples.csv',
    );
    addTearDown(controller.dispose);

    await controller.chooseSymbolFile();
    expect(commands.removeAt(0), ('loadSymbols', r'C:\firmware\motor.axf'));

    controller.applyBackendEvent('state', {
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
    expect(commands.single.$1, 'setWatches');
    final watchPayload = Map<String, dynamic>.from(commands.single.$2! as Map);
    expect(watchPayload['watches'], hasLength(1));
    commands.clear();

    controller.applyBackendEvent('samples', {
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

    controller.applyBackendEvent('samplesCleared', const <String, Object?>{});
    expect(controller.elapsedSeconds, 0);
    expect(controller.watches.single.samples, isEmpty);

    controller.applyBackendEvent('perf', {
      'effectiveHz': 198.5,
      'sampleCount': 199,
      'readBlockCount': 1,
    });
    expect(controller.performanceStats['effectiveHz'], 198.5);
    expect(controller.logs.last.message, contains('采样性能'));

    controller.applyBackendEvent('error', {
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
      'writeWatch',
      'setRttProtocol',
      'exportCsv',
    ]);
  });

  test('backend state updates do not reset local plot controls', () {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.togglePlotting();
    controller.toggleFollowLatest();

    controller.applyBackendEvent('state', {
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
