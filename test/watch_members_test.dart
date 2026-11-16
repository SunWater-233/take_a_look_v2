import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/models/watch_tree.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final commands = <(ControllerCommand, Object?)>[];
  final definitions = <(String, String, String)>[
    ('motor', 'motor.c', 'struct Motor'),
    ('motor.speed', 'motor.c', 'float'),
    ('motor.current', 'motor.c', 'struct Current'),
    ('motor.current.q', 'motor.c', 'float'),
    ('motor.samples', 'motor.c', 'float[2]'),
    ('motor.samples[0]', 'motor.c', 'float'),
    ('motor.samples[1]', 'motor.c', 'float'),
    ('motor.samplesExtra', 'motor.c', 'float'),
    ('motor.samples', 'other.c', 'float[1]'),
    ('motor.samples[0]', 'other.c', 'float'),
    ('other', 'motor.c', 'float'),
  ];

  TakeALookController fixture({
    List<String> roots = const ['motor', 'other:8', 'other'],
  }) {
    commands.clear();
    final c = TakeALookController(
      backendCommand: (command, args) async => commands.add((command, args)),
    );
    addTearDown(c.dispose);
    c.applySnapshot({
      'symbols': [
        for (final (i, definition) in definitions.indexed)
          {
            'key': definition.$2 == 'other.c' ? 'other:$i' : definition.$1,
            'source': definition.$2,
            'name': definition.$1,
            'type': definition.$3,
            'address': 0x20000000 + i * 4,
            'size': 4,
          },
      ],
    });
    c.selectSymbols(roots);
    c.addSelectedToWatch();
    return c;
  }

  List<String> keys(TakeALookController c) => [
    for (final watch in c.watches) watch.symbol.key,
  ];

  test('array removal deletes its subtree as one undo and redo batch', () {
    final c = fixture()..samplingPaused = true;
    final original = c.watches;
    c.compactExpandedWatches.add('motor.samples');
    c.setPlotHighlightedWatch('motor.samples[1]');
    c.removeWatch('motor.samples');
    expect(
      keys(c),
      isNot(
        contains(
          anyOf('motor.samples', 'motor.samples[0]', 'motor.samples[1]'),
        ),
      ),
    );
    expect(keys(c), containsAll(['motor.samplesExtra', 'other:8', 'other:9']));
    expect(c.plotHighlightedWatchKey, isNull);
    expect(buildWatchTree(c.watches).first.children.map((node) => node.label), [
      'speed',
      'current',
      'samplesExtra',
    ]);
    c.undoWatchDeletion();
    expect(c.watches, orderedEquals(original));
    expect(c.compactExpandedWatches, contains('motor.samples'));
    expect(c.plotHighlightedWatchKey, 'motor.samples[1]');
    expect(c.canUndoWatchDeletion, isFalse);
    c.redoWatchDeletion();
    expect(keys(c), isNot(contains('motor.samples[1]')));
    c.undoWatchDeletion();
    expect(c.watches, orderedEquals(original));
  });

  test(
    'overlapping branch removal leaves other sources and variables intact',
    () {
      final c = fixture();
      final original = c.watches;
      c.removeWatches(['motor', 'motor.current', 'motor.samples[0]']);
      expect(keys(c), ['other:8', 'other:9', 'other']);
      expect(c.isAggregateWatch('motor'), isFalse);
      c.restoreWatchMembers('motor');
      expect(keys(c), ['other:8', 'other:9', 'other']);
      c.undoWatchDeletion();
      expect(c.watches, orderedEquals(original));
    },
  );

  test(
    'restore fills nested branches in order and retains settings and data',
    () {
      final c = fixture()..samplingPaused = true;
      final original = c.watches;
      final sample = c.watches.firstWhere(
        (w) => w.symbol.key == 'motor.samples[1]',
      );
      c.setWatchReadMode(sample.symbol.key, WatchReadMode.capture);
      c.setWatchColor(sample.symbol.key, Colors.pink);
      c.setWatchPinned(sample.symbol.key, true);
      c.setWatchMonitorRate(sample.symbol.key, 5);
      c.watchInputDrafts[sample.symbol.key] = '12.5';
      c.compactExpandedWatches.addAll(['motor.current', 'motor.samples']);
      c.applyBackendSamples({
        'captureOnly': true,
        'frames': [
          {
            'elapsed': 1.0,
            'values': {sample.symbol.key: 42.0},
          },
        ],
      });
      c.removeWatches(['motor.speed', 'motor.current', 'motor.samples']);
      c.selectSymbols(['other']);
      expect(c.canRestoreWatchMembers('motor'), isTrue);
      c.restoreWatchMembers('motor');
      expect(c.watches, orderedEquals(original));
      expect(sample.samples.single.dy, 42);
      expect(sample.color, Colors.pink);
      expect(sample.readMode, WatchReadMode.capture);
      expect(sample.plotted, isTrue);
      expect(sample.pinned, isTrue);
      expect(sample.monitorRateHz, 5);
      expect(c.watchInputDrafts[sample.symbol.key], '12.5');
      expect(
        c.compactExpandedWatches,
        containsAll(['motor.current', 'motor.samples']),
      );
      expect(c.selectedSymbols, {'other'});
      expect(c.canUndoWatchDeletion, isFalse);
      expect(c.canRestoreWatchMembers('motor'), isFalse);
      c.restoreWatchMembers('motor');
      expect(c.watches, orderedEquals(original));
      expect(
        ((commands.last.$2 as Map)['watches'] as List).map(
          (w) => (w as Map)['key'],
        ),
        keys(c),
      );
    },
  );

  test(
    'restoring one branch preserves unrelated undo history and clears redo',
    () {
      final c = fixture();
      c.removeWatches(['motor.speed', 'other']);
      c.removeWatch('motor.current');
      c.undoWatchDeletion();
      expect(c.canRedoWatchDeletion, isTrue);
      c.restoreWatchMembers('motor');
      expect(keys(c), contains('motor.speed'));
      expect(keys(c), isNot(contains('other')));
      expect(c.canRedoWatchDeletion, isFalse);
      expect(c.canUndoWatchDeletion, isTrue);
      c.undoWatchDeletion();
      expect(keys(c), contains('other'));
      expect(keys(c).where((key) => key == 'motor.speed'), hasLength(1));
    },
  );

  testWidgets('expired captured members return as fresh monitor watches', (
    tester,
  ) async {
    final c = fixture();
    const key = 'motor.samples[1]';
    final removed = c.watches.firstWhere((w) => w.symbol.key == key);
    c.setWatchReadMode(key, WatchReadMode.capture);
    c.applyBackendSamples({
      'captureOnly': true,
      'frames': [
        {
          'elapsed': 2.0,
          'values': {key: 20.0},
        },
      ],
    });
    c.removeWatch('motor.samples');
    await tester.pump(const Duration(seconds: 10));
    c.restoreWatchMembers('motor');
    final restored = c.watches.firstWhere((w) => w.symbol.key == key);
    expect(restored, isNot(same(removed)));
    expect(restored.readMode, WatchReadMode.monitor);
    expect(restored.samples, isEmpty);
    expect(restored.historyStartSeconds, greaterThan(2));
    expect(c.canRestoreWatchMembers('motor'), isFalse);
  });

  test(
    'a partial saved watch list can restore members using the symbol table',
    () {
      final c = fixture();
      c.removeWatches(['motor.current', 'motor.samples']);
      final restored = TakeALookController()..applySnapshot(c.stateSnapshot());
      addTearDown(restored.dispose);
      final speed = restored.watches.firstWhere(
        (w) => w.symbol.key == 'motor.speed',
      );
      restored.restoreWatchMembers('motor');
      expect(keys(restored).take(8), definitions.take(8).map((d) => d.$1));
      expect(restored.watches[1], same(speed));
      expect(restored.canRestoreWatchMembers('motor'), isFalse);
    },
  );

  test(
    'a separately added leaf cannot restore its absent parent or siblings',
    () {
      final c = fixture(roots: ['motor.speed']);
      expect(c.isAggregateWatch('motor.speed'), isFalse);
      expect(c.canRestoreWatchMembers('motor.speed'), isFalse);
      c.restoreWatchMembers('motor.speed');
      c.restoreWatchMembers('motor');
      expect(keys(c), ['motor.speed']);
    },
  );

  testWidgets(
    'detached windows route subtree deletion and member restoration',
    (tester) async {
      final c = fixture();
      final remote = TakeALookController(
        remoteCommand: (command, args) async {
          await c.handleCommand(command, args);
        },
      )..applySnapshot(c.stateSnapshot());
      addTearDown(remote.dispose);
      remote.removeWatch('motor.samples');
      await tester.pump();
      remote.applySnapshot(c.stateSnapshot());
      expect(keys(remote), isNot(contains('motor.samples[0]')));
      expect(remote.canRestoreWatchMembers('motor'), isTrue);
      remote.restoreWatchMembers('motor');
      await tester.pump();
      remote.applySnapshot(c.stateSnapshot());
      expect(keys(remote), keys(c));
      expect(
        keys(remote),
        containsAll(['motor.samples', 'motor.samples[0]', 'motor.samples[1]']),
      );
      expect(remote.canRestoreWatchMembers('motor'), isFalse);
      expect(remote.canUndoWatchDeletion, isFalse);
    },
  );
}
