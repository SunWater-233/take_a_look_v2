import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/telemetry/telemetry_store.dart';

import 'watch_browser_test.dart' as browser;

const speed = SymbolItem(
  source: 'main.c',
  name: 'speed',
  address: 0x20000000,
  type: 'Speed_t',
  size: 4,
  encoding: 'float',
  backendKey: 'speed',
);

void main() {
  test('typedef display names retain scalar formatting and wire metadata', () {
    final symbol = SymbolItem.fromJson(speed.toJson());
    final watch = WatchItem(symbol: symbol, color: Colors.orange)
      ..applyValue(1.2345678);
    expect(watch.isFloatingPoint, isTrue);
    expect(double.parse(watch.editValueLabel), closeTo(1.2345678, 1e-7));
    expect(symbol.type, 'Speed_t');
    expect(symbol.encoding, 'float');
  });

  test('undecodable samples never create zero or repeated-value history', () {
    final watch = WatchItem(symbol: speed, color: Colors.orange);
    final store = TelemetryStore();
    double apply(Object raw, int stamp) => store.applyJsonFrames(
      {
        'updatedAtMs': stamp,
        'frames': [
          {
            'elapsed': stamp.toDouble(),
            'values': {'speed': raw},
          },
        ],
      },
      [watch],
      currentElapsed: 0,
    );
    apply('00 00 80 3F', 1);
    expect(watch.valueLabel, '无法解码');
    expect(watch.samples, isEmpty);
    expect(watch.totalSampleCount, 0);
    apply(1.5, 2);
    apply('00 00 00 40', 3);
    expect(watch.samples.single.dy, 1.5);
    expect(watch.totalSampleCount, 1);
    expect(watch.valueLabel, '无法解码');
    apply(2.5, 4);
    expect(watch.valueIssue, isNull);
    expect(watch.value, 2.5);
    expect(watch.samples.length, 2);
  });

  test(
    'decode issues survive full snapshots and telemetry synchronization',
    () {
      final owner = TakeALookController(backendCommand: (_, _) async {});
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(owner.dispose);
      addTearDown(detached.dispose);
      owner.applySnapshot({
        'symbols': [speed.toJson()],
        'watches': [
          {'key': speed.key, 'value': 'bad bytes', 'updatedAtMs': 1},
        ],
      });
      detached.applySnapshot(owner.snapshot());
      expect(detached.watches.single.valueLabel, '无法解码');
      owner.applyWatchValues({
        'values': [
          {'key': speed.key, 'value': 3.5, 'updatedAtMs': 2},
        ],
      });
      detached.applyTelemetrySnapshot(owner.telemetrySnapshot());
      expect(detached.watches.single.value, 3.5);
      expect(detached.watches.single.valueIssue, isNull);
      owner.applyWatchValues({
        'values': [
          {'key': speed.key, 'value': 'bad again', 'updatedAtMs': 3},
        ],
      });
      detached.applyTelemetryDelta(
        owner.telemetryDeltaSnapshot(detached.telemetryCursors()),
      );
      expect(detached.watches.single.valueLabel, '无法解码');
    },
  );

  testWidgets('a parse failure is visible before any sample arrives', (
    tester,
  ) async {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    controller.applySnapshot({
      'symbols': [
        {...speed.toJson(), 'diagnostic': '类型匹配有歧义', 'writable': false},
      ],
      'watches': [
        {'key': speed.key},
      ],
    });
    await browser.mount(tester, controller);
    final cell = find.byKey(const ValueKey('compact-watch-value-speed'));
    expect(tester.widget<Text>(cell).data, '解析失败');
    expect(controller.watches.single.updatedAtMs, isNull);
  });

  testWidgets(
    'an explicit unread snapshot clears the previous value timestamp',
    (tester) async {
      final controller = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(controller.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      controller.applySnapshot({
        'symbols': [speed.toJson()],
        'watches': [
          {'key': speed.key, 'value': 5.0, 'updatedAtMs': 1},
        ],
      });
      controller.applySnapshot({
        'watches': [
          {'key': speed.key, 'value': '', 'updatedAtMs': null},
        ],
      });
      await browser.mount(tester, controller);
      final cell = find.byKey(const ValueKey('compact-watch-value-speed'));
      expect(tester.widget<Text>(cell).data, '—');
      expect(controller.watches.single.updatedAtMs, isNull);
    },
  );
}
