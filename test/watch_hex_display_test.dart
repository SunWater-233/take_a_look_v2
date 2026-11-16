import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/controller/controller_command_router.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

import 'watch_browser_test.dart' as browser;
import 'watch_value_test_helpers.dart';

TakeALookController fixture() {
  final c = TakeALookController(backendCommand: (_, _) async {});
  final definitions = <(String, String, int)>[
    ('motor', 'Motor_t', 4),
    ('motor.id', 'uint16_t', 2),
    ('motor.config', 'Config_t', 4),
    ('motor.config.limit', 'int32_t', 4),
    ('motor.items', 'Item_t[2]', 16),
    for (var i = 0; i < 2; i++) ...[
      ('motor.items[$i]', 'Item_t', 8),
      ('motor.items[$i].code', 'uint16_t', 2),
      ('motor.items[$i].gain', 'float', 4),
    ],
    ('motor.gain', 'float', 4),
    ('samples', 'uint8_t[70]', 70),
    for (var i = 0; i < 70; i++) ('samples[$i]', 'uint8_t', 1),
    ('other', 'uint16_t', 2),
    ('float_only', 'float[2]', 8),
    ('float_only[0]', 'float', 4),
    ('float_only[1]', 'float', 4),
  ];
  c.applySnapshot({
    'symbols': [
      for (final (index, definition) in definitions.indexed)
        {
          'key': definition.$1,
          'source': 'test.c',
          'name': definition.$1,
          'address': 0x20000000 + index * 4,
          'type': definition.$2,
          'size': definition.$3,
        },
    ],
  });
  c.selectSymbols(['motor', 'samples', 'other', 'float_only']);
  c.addSelectedToWatch(mode: WatchReadMode.monitor);
  c.compactExpandedWatches.clear();
  return c;
}

void main() {
  test(
    'nested groups and overlapping selections change only scalar leaves',
    () {
      final c = fixture();
      addTearDown(c.dispose);
      var notifications = 0;
      c.watchChanges.addListener(() => notifications++);
      final keys = ['motor', 'motor.config', 'motor.items[0]', 'samples'];
      final targets = c.watchesForHexDisplay(keys);
      expect(targets, hasLength(74));
      expect(targets.toSet(), hasLength(74));
      c.setWatchesHexDisplay(keys, true);
      expect(notifications, 1);
      expect(targets.every((w) => w.displayHex), isTrue);
      expect(
        c.watches.where((w) => !targets.contains(w)).any((w) => w.displayHex),
        isFalse,
      );
      c.setWatchesHexDisplay(keys, true);
      expect(notifications, 1);
      c.setWatchHexDisplay('motor.items', false);
      expect(notifications, 2);
      expect(
        c.watchesForHexDisplay(['motor.items']).every((w) => !w.displayHex),
        isTrue,
      );
      expect(
        c.watchesForHexDisplay(['samples']).every((w) => w.displayHex),
        isTrue,
      );
      expect(c.compactExpandedWatches, isEmpty);
    },
  );

  test('detached windows send a single command for multiple groups', () async {
    final c = fixture();
    addTearDown(c.dispose);
    final calls = <(ControllerCommand, Object?)>[];
    final remote = TakeALookController(
      remoteCommand: (command, arguments) async {
        calls.add((command, arguments));
      },
    )..applySnapshot(c.stateSnapshot());
    addTearDown(remote.dispose);
    remote.setWatchesHexDisplay(['motor', 'samples'], true);
    expect(calls, hasLength(1));
    expect(calls.single.$1, ControllerCommand.setWatchesHexDisplay);
    await executeControllerCommand(
      c,
      calls.single.$1,
      calls.single.$2,
      includeResultState: false,
    );
    remote.applySnapshot(c.stateSnapshot());
    expect(
      remote
          .watchesForHexDisplay(['motor', 'samples'])
          .every((w) => w.displayHex),
      isTrue,
    );
    expect(remote.watchesForHexDisplay(['other']).single.displayHex, isFalse);
  });

  testWidgets(
    'mixed selection and collapsed structures and arrays toggle as groups',
    (tester) async {
      final c = fixture();
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.setWatchHexDisplay('other', true);
      await browser.mount(tester, c, width: 640);
      Finder row(String key) => find.descendant(
        of: find.byKey(ValueKey('compact-watch-$key')),
        matching: find.text(key),
      );
      Future<void> menu(String key) async {
        await showWatchWidget(tester, row(key));
        await tester.tap(row(key), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
      }

      Future<void> choose(String label) async {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      expect(
        find.byKey(const ValueKey('compact-watch-motor.id')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('compact-watch-samples[0]')),
        findsNothing,
      );
      await tester.tap(row('other'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(row('motor'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await menu('other');
      // A mixed selection offers hex even when its right-clicked row is hex.
      expect(find.text('十进制显示'), findsNothing);
      await choose('十六进制显示');
      expect(
        c.watchesForHexDisplay(['motor', 'other']).every((w) => w.displayHex),
        isTrue,
      );
      expect(
        c.watches.where((w) => w.isFloatingPoint).any((w) => w.displayHex),
        isFalse,
      );

      await menu('motor');
      await choose('十进制显示');
      expect(c.watches.any((w) => w.displayHex), isFalse);
      await menu('samples');
      await choose('十六进制显示');
      expect(c.watchesForHexDisplay(['samples']), hasLength(70));
      expect(
        c.watchesForHexDisplay(['samples']).every((w) => w.displayHex),
        isTrue,
      );
      expect(
        c.watchesForHexDisplay(['motor', 'other']).any((w) => w.displayHex),
        isFalse,
      );
      await menu('samples');
      await choose('十进制显示');
      expect(c.watches.any((w) => w.displayHex), isFalse);

      await menu('float_only');
      final item = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('十六进制显示'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
