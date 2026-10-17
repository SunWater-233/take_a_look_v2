import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/telemetry/numeric_history.dart';

void main() {
  final commands = <(ControllerCommand, Object?)>[];

  TakeALookController fixture() {
    commands.clear();
    final controller = TakeALookController(
      backendCommand: (command, args) async {
        commands.add((command, args));
      },
    )..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    addTearDown(controller.dispose);
    return controller;
  }

  List<String> backendKeys() => ((commands.last.$2 as Map)['watches'] as List)
      .map((watch) => (watch as Map)['key'] as String)
      .toList();

  void sample(TakeALookController controller, String key, double time) {
    controller.applyBackendSamples({
      'captureOnly': true,
      'frames': [
        {
          'elapsed': time,
          'values': {key: time * 10},
        },
      ],
    });
  }

  testWidgets(
    'capture deletion retains continuous data and original settings',
    (tester) async {
      final controller = fixture();
      final watch = controller.watches[1];
      final key = watch.symbol.key;
      controller.compactWatchSelection = key;
      controller.watchInputDrafts[key] = '12.5';
      controller.setPlotHighlightedWatch(key);
      controller.setWatchColor(key, Colors.blue);
      sample(controller, key, 1);
      final backendEcho = controller.stateSnapshot();
      controller.removeWatch(key);
      expect(controller.watches, hasLength(2));
      expect(controller.canUndoWatchDeletion, isTrue);
      expect(backendKeys(), contains(key));
      final hidden = ((commands.last.$2 as Map)['watches'] as List)
          .cast<Map>()
          .singleWhere((item) => item['key'] == key);
      expect(hidden['plotted'], isFalse);
      expect(hidden['readMode'], 'capture');
      controller.applySnapshot(backendEcho);
      expect(
        controller.watches.map((watch) => watch.symbol.key),
        isNot(contains(key)),
      );
      await tester.pump(const Duration(seconds: 9));
      sample(controller, key, 2);
      controller.undoWatchDeletion();
      expect(controller.watches[1], same(watch));
      expect(watch.samples.map((point) => point.dy), [10, 20]);
      expect(watch.color, Colors.blue);
      expect(watch.plotted, isTrue);
      expect(controller.watchInputDrafts[key], '12.5');
      expect(controller.compactWatchSelection, key);
      expect(controller.plotHighlightedWatchKey, key);
      expect(controller.canUndoWatchDeletion, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(watch.samples, hasLength(2));
      expect(backendKeys(), contains(key));
    },
  );

  testWidgets(
    'at ten seconds removal stops capture and releases retained data',
    (tester) async {
      final controller = fixture();
      final watch = controller.watches.first;
      final key = watch.symbol.key;
      sample(controller, key, 1);
      controller.removeWatch(key);
      await tester.pump(const Duration(milliseconds: 9999));
      expect(controller.canUndoWatchDeletion, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.canUndoWatchDeletion, isFalse);
      expect(backendKeys(), isNot(contains(key)));
      expect(controller.acquisitionWatches, isNot(contains(watch)));
      expect(watch.samples, isEmpty);
      sample(controller, key, 2);
      controller.undoWatchDeletion();
      expect(controller.watches, hasLength(2));
      controller.selectSymbols([key]);
      controller.addSelectedToWatch();
      expect(controller.watches.last, isNot(same(watch)));
      expect(controller.watches.last.samples, isEmpty);
      sample(controller, key, 1);
      expect(
        controller.watches.last.samples,
        isEmpty,
        reason: 'A late queued batch cannot revive permanently deleted data.',
      );
      expect(controller.watches.last.updatedAtMs, isNull);
    },
  );

  testWidgets('removals have independent deadlines and undo order', (
    tester,
  ) async {
    final controller = fixture();
    final first = controller.watches[0], second = controller.watches[1];
    controller.removeWatch(first.symbol.key);
    await tester.pump(const Duration(seconds: 5));
    controller.removeWatch(second.symbol.key);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.canUndoWatchDeletion, isTrue);
    expect(backendKeys(), isNot(contains(first.symbol.key)));
    expect(backendKeys(), contains(second.symbol.key));
    controller.undoWatchDeletion();
    expect(controller.watches, contains(second));
    expect(controller.watches, isNot(contains(first)));
    expect(controller.canUndoWatchDeletion, isFalse);
  });

  testWidgets(
    'paused deletion stays undoable and does not acquire hidden samples',
    (tester) async {
      final controller = fixture()..samplingPaused = true;
      final watch = controller.watches.first;
      sample(controller, watch.symbol.key, 1);
      controller.removeWatch(watch.symbol.key);
      expect(backendKeys(), isNot(contains(watch.symbol.key)));
      await tester.pump(const Duration(seconds: 30));
      sample(controller, watch.symbol.key, 2);
      controller.undoWatchDeletion();
      expect(controller.watches.first, same(watch));
      expect(watch.samples, hasLength(1));
    },
  );

  testWidgets(
    'mixed removal expires only captured variables and re-add restores retained capture',
    (tester) async {
      final controller = fixture();
      final first = controller.watches[0], second = controller.watches[1];
      controller.setWatchReadMode(first.symbol.key, WatchReadMode.monitor);
      controller.removeWatches([first.symbol.key, second.symbol.key]);
      await tester.pump(const Duration(seconds: 10));
      controller.undoWatchDeletion();
      expect(controller.watches, contains(first));
      expect(controller.watches, isNot(contains(second)));
      final watch = controller.watches.last;
      sample(controller, watch.symbol.key, 1);
      controller.removeWatch(watch.symbol.key);
      controller.selectSymbols([watch.symbol.key]);
      controller.addSelectedToWatch();
      expect(controller.watches.last, same(watch));
      expect(watch.samples, hasLength(1));
      expect(controller.canUndoWatchDeletion, isFalse);
    },
  );

  testWidgets(
    'detached window sees undo availability and routes undo to main',
    (tester) async {
      final main = fixture();
      final remote = TakeALookController(
        remoteCommand: (command, args) async {
          await main.handleCommand(command, args);
        },
      );
      addTearDown(remote.dispose);
      main.removeWatch(main.watches.first.symbol.key);
      remote.applySnapshot(main.stateSnapshot());
      expect(remote.canUndoWatchDeletion, isTrue);
      expect(remote.watches, hasLength(2));
      remote.undoWatchDeletion();
      await tester.pump();
      remote.applySnapshot(main.stateSnapshot());
      expect(remote.watches, hasLength(3));
      expect(remote.canUndoWatchDeletion, isFalse);
    },
  );

  testWidgets('clearing samples also clears paused undo history', (
    tester,
  ) async {
    final controller = fixture()..samplingPaused = true;
    final watch = controller.watches.first;
    sample(controller, watch.symbol.key, 1);
    controller.removeWatch(watch.symbol.key);
    controller.applyBackendSamplesCleared();
    controller.undoWatchDeletion();
    expect(watch.samples, isEmpty);
    expect(watch.totalSampleCount, 0);
  });

  testWidgets(
    'a new symbol table invalidates deletion history and pending captures',
    (tester) async {
      final controller = fixture();
      controller.removeWatch(controller.watches.first.symbol.key);
      controller.applySnapshot({
        'symbols': <Object?>[],
        'watches': <Object?>[],
      });
      expect(controller.canUndoWatchDeletion, isFalse);
      expect(controller.acquisitionWatches, isEmpty);
      expect(backendKeys(), isEmpty);
      final count = commands.length;
      await tester.pump(const Duration(seconds: 11));
      expect(commands, hasLength(count));
    },
  );

  testWidgets(
    'permanent removal never backfills old recording history after re-add',
    (tester) async {
      final controller = TakeALookController(
        backendCommand: (_, _) async {},
        historyReader: (request) async => HistoryWindow(
          request: request,
          reduced: false,
          series: {
            request.keys.single: Float64List.fromList([1, 11, 101, 22]),
          },
        ),
      );
      addTearDown(controller.dispose);
      controller.loadDemoSymbols();
      final key = demoSymbols.first.key;
      controller.selectSymbols([key]);
      controller.addSelectedToWatch();
      sample(controller, key, 100);
      controller.removeWatch(key);
      await tester.pump(const Duration(seconds: 10));
      controller.selectSymbols([key]);
      controller.addSelectedToWatch();
      controller.plottingPaused = true;
      controller.plotHistory.update(
        path: 'recording',
        keys: [key],
        start: 0,
        end: 200,
        sourceEnd: 200,
        pixelWidth: 400,
        enabled: true,
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        controller
            .plotSamplesFor(controller.watches.single)
            .map((point) => point.dy),
        [22],
      );
      final remote = TakeALookController(backendCommand: (_, _) async {})
        ..applySnapshot(controller.stateSnapshot());
      addTearDown(remote.dispose);
      expect(
        remote.watches.single.historyStartSeconds,
        controller.watches.single.historyStartSeconds,
      );
      controller.applyBackendSamplesCleared();
      expect(controller.watches.single.historyStartSeconds, 0);
    },
  );
}
