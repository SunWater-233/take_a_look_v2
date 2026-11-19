import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/models/symbol_hierarchy.dart';
import 'package:take_a_look_v2/src/models/watch_tree.dart';

Map<String, dynamic> symbol(
  String name,
  int address, {
  String source = 'motor.c',
  String dataSource = 'memory',
  String encoding = 'unsigned',
  String diagnostic = '',
}) => {
  'key': '$dataSource:$address:$name',
  'source': source,
  'name': name,
  'address': address,
  'type': 'uint32_t',
  'size': 4,
  'dataSource': dataSource,
  'encoding': encoding,
  'diagnostic': diagnostic,
};

void main() {
  test('all member operations share array and record ancestry', () {
    final definitions = [
      'items',
      'items[0]',
      'items[0].matrix',
      'items[0].matrix[0]',
      'items[0].matrix[0][0]',
      'items[0].matrixExtra',
      'items[1]',
      'items[1].field',
      'itemsExtra',
    ];
    final c = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(c.dispose);
    c.applySnapshot({
      'symbols': [
        for (final (i, name) in definitions.indexed) symbol(name, i * 4),
      ],
    });
    final keys = {for (final s in c.symbols) s.name: s.key};
    c.selectSymbols([keys['items']!]);
    c.addSelectedToWatch();
    expect(c.watches.map((w) => w.symbol.name), definitions.take(8));
    final tree = buildWatchTree(c.watches).single;
    expect(tree.children.map((n) => n.label), ['[0]', '[1]']);
    expect(tree.children.first.children.first.children.single.label, '[0]');
    c.samplingPaused = true;
    c.removeWatch(keys['items[0].matrix']!);
    expect(c.watches.map((w) => w.symbol.name), [
      'items',
      'items[0]',
      'items[0].matrixExtra',
      'items[1]',
      'items[1].field',
    ]);
    c.restoreWatchMembers(keys['items[0]']!);
    expect(c.watches.map((w) => w.symbol.name), definitions.take(8));
    c.removeWatch(keys['items[0]']!);
    expect(c.watches.map((w) => w.symbol.name), [
      'items',
      'items[1]',
      'items[1].field',
    ]);
    c.undoWatchDeletion();
    expect(c.watches.map((w) => w.symbol.name), definitions.take(8));
  });

  test('watch ancestry separates data sources and ambiguous declarations', () {
    final definitions = [
      symbol('items', 0),
      symbol('items[0]', 4),
      symbol('items', 8, dataSource: 'rtt'),
      symbol('items[0]', 12, dataSource: 'rtt'),
      symbol('items[0]', 16, source: 'other.c'),
      symbol('duplicate', 20),
      symbol('duplicate', 24),
      symbol('duplicate.child', 28),
    ];
    final c = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(c.dispose);
    c.applySnapshot({'symbols': definitions});
    c.selectSymbols([c.symbols.first.key]);
    c.addSelectedToWatch();
    expect(c.watches.map((w) => w.symbol.dataSource).toSet(), {'memory'});
    expect(c.watches, hasLength(2));
    final hierarchy = SymbolHierarchy(c.symbols);
    expect(hierarchy.parentOf(c.symbols[3])?.key, c.symbols[2].key);
    expect(hierarchy.descendantsOf(c.symbols[5]), isEmpty);
    expect(hierarchy.parentOf(c.symbols.last), isNull);
    expect(splitSymbolPath('items[0].matrix[1][2]'), [
      'items',
      '[0]',
      'matrix',
      '[1]',
      '[2]',
    ]);
  });

  test(
    'refresh migrates local watch state and suppresses deleted subtrees',
    () {
      final c = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(c.dispose);
      final oldNames = [
        'motor',
        'motor.matrix',
        'motor.matrix[0]',
        'motor.matrix[0][0]',
        'motor.removed',
        'motor.hidden',
        'motor.hidden[0]',
      ];
      c.applySnapshot({
        'symbols': [
          for (final (i, name) in oldNames.indexed) symbol(name, i * 4),
        ],
      });
      var keys = {for (final s in c.symbols) s.name: s.key};
      c.selectSymbols([keys['motor']!]);
      c.addSelectedToWatch();
      final leaf = keys['motor.matrix[0][0]']!;
      c.setWatchReadMode(leaf, WatchReadMode.capture);
      c.setWatchColor(leaf, Colors.pink);
      c.setWatchMonitorRate(leaf, 5);
      c.setWatchPinned(leaf, true);
      c.setWatchHexDisplay(leaf, true);
      c.watchInputDrafts[leaf] = '42';
      c.compactWatchSelection = leaf;
      c.compactExpandedWatches.addAll([
        keys['motor']!,
        keys['motor.matrix']!,
        keys['motor.matrix[0]']!,
      ]);
      c.compactWatchSectionOrders['pinned'] = [leaf];
      c.setPlotHighlightedWatch(leaf);
      // A captured, deleted parent remains in backend acquisition during Undo's
      // grace period. New children returned by a refresh must stay hidden too.
      c.setWatchReadMode(keys['motor.hidden']!, WatchReadMode.capture);
      final oldByKey = {
        for (final raw in c.stateSnapshot()['watches'] as List)
          (raw as Map)['key']: raw,
      };
      final oldWatches = {
        for (final w in c.watches) w.symbol.name: oldByKey[w.symbol.key],
      };
      c.removeWatch(keys['motor.hidden']!);
      final nextNames = [
        'motor',
        'motor.matrix',
        'motor.matrix[0]',
        'motor.matrix[0][0]',
        'motor.matrix[1]',
        'motor.matrix[1][0]',
        'motor.hidden',
        'motor.hidden[0]',
        'motor.hidden[1]',
      ];
      final next = [
        for (final (i, name) in nextNames.indexed) symbol(name, 0x100 + i * 4),
      ];
      c.applySnapshot({
        'symbols': next,
        'watches': [
          for (final s in next)
            {
              'key': s['key'],
              'color': oldWatches[s['name']]?['color'],
              'readMode': oldWatches[s['name']]?['readMode'] ?? 'monitor',
              'monitorRateHz': oldWatches[s['name']]?['monitorRateHz'],
              'plotted': oldWatches[s['name']]?['plotted'] ?? false,
            },
        ],
      });
      keys = {for (final s in c.symbols) s.name: s.key};
      expect(c.watches.map((w) => w.symbol.name), nextNames.take(6));
      final retained = c.watches.firstWhere(
        (w) => w.symbol.name == 'motor.matrix[0][0]',
      );
      expect(retained.readMode, WatchReadMode.capture);
      expect(retained.color.toARGB32(), Colors.pink.toARGB32());
      expect(retained.monitorRateHz, 5);
      expect(retained.pinned, isTrue);
      expect(retained.displayHex, isTrue);
      expect(c.watchInputDrafts, {retained.symbol.key: '42'});
      expect(c.compactWatchSelection, retained.symbol.key);
      expect(c.plotHighlightedWatchKey, retained.symbol.key);
      expect(c.compactWatchSectionOrders['pinned'], [retained.symbol.key]);
      expect(c.compactExpandedWatches, {
        keys['motor'],
        keys['motor.matrix'],
        keys['motor.matrix[0]'],
      });
      final rows = buildWatchTree(c.watches).single.children.single.children;
      expect(rows.map((n) => n.label), ['[0]', '[1]']);
      expect(c.canUndoWatchDeletion, isFalse);
      c.restoreWatchMembers(keys['motor']!);
      expect(c.watches.map((w) => w.symbol.name), nextNames);
    },
  );

  test(
    'decoder-only changes refresh watches even without a watch-list patch',
    () {
      final c = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(c.dispose);
      c.applySnapshot({
        'symbols': [symbol('value', 0)],
      });
      c.selectSymbols([c.symbols.single.key]);
      c.addSelectedToWatch();
      final revision = c.symbolRevision;
      var watchEvents = 0;
      c.watchChanges.addListener(() => watchEvents++);
      c.applySnapshot({
        'symbols': [
          symbol(
            'value',
            0,
            encoding: 'unsupported',
            diagnostic: 'type changed',
          ),
        ],
      });
      expect(c.symbolRevision, revision + 1);
      expect(c.watches.single.symbol, same(c.symbols.single));
      expect(c.watches.single.valueDiagnostic, 'type changed');
      expect(watchEvents, 1);
    },
  );
}
