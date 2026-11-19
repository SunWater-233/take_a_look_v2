import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

import 'watch_browser_test.dart' as browser;
import 'watch_value_test_helpers.dart';

WatchItem sample(String type, int size, double value) => WatchItem(
  symbol: SymbolItem(
    source: 'test.c',
    name: 'value',
    address: 0,
    type: type,
    size: size,
  ),
  color: Colors.orange,
)..value = value;

void main() {
  setUpAll(() async {
    for (final font in [
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
      ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
  });

  test(
    'edit text round-trips float32 and float64 without display rounding',
    () {
      for (final value in [
        -0.4842345714569092,
        1.23456789,
        1e-38,
        3.4028234e38,
        -0.0,
      ]) {
        final watch = sample('const float', 4, value);
        final original = Float32List.fromList([
          value,
        ]).buffer.asUint32List().single;
        final decoded = Float32List.fromList([
          double.parse(watch.editValueLabel),
        ]).buffer.asUint32List().single;
        expect(decoded, original);
      }
      for (final value in [
        1.2345678901234567,
        5e-324,
        1.7976931348623157e308,
        -0.0,
      ]) {
        final watch = sample('double', 8, value);
        final parsed = double.parse(watch.editValueLabel);
        expect(
          Float64List.fromList([parsed]).buffer.asUint64List().single,
          Float64List.fromList([value]).buffer.asUint64List().single,
        );
      }
      expect(sample('bool', 1, 1).editValueLabel, 'true');
      expect(sample('int32_t', 4, -123456).editValueLabel, '-123456');
    },
  );

  test('hex display uses target width and preserves decimal edit values', () {
    for (final (type, size, value, hex) in [
      ('uint8_t', 1, 255.0, '0xFF'),
      ('uint16_t', 2, 17.0, '0x0011'),
      ('int16_t', 2, -1.0, '0xFFFF'),
      ('int32_t', 4, -2.0, '0xFFFFFFFE'),
      ('void *', 4, 0x240005CC.toDouble(), '0x240005CC'),
      ('int64_t', 8, -1.0, '0xFFFFFFFFFFFFFFFF'),
    ]) {
      final watch = sample(type, size, value)..displayHex = true;
      expect(watch.valueLabel, hex);
      expect(watch.editValueLabel, value.round().toString());
      watch.displayHex = false;
      expect(watch.valueLabel, value.round().toString());
    }
    expect(sample('float', 4, 1.5).supportsHexDisplay, isFalse);
  });

  testWidgets(
    'hex menu toggles rows, pinned values and persisted preferences',
    (tester) async {
      final c = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(c.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      c.applySnapshot({
        'symbols': [
          {
            'key': 'counter',
            'source': 'test.c',
            'name': 'counter',
            'address': 0x20000000,
            'type': 'uint16_t',
            'size': 2,
          },
        ],
      });
      c.selectSymbols(['counter']);
      c.addSelectedToWatch(mode: WatchReadMode.monitor);
      c.applyTelemetrySnapshot({
        'watches': [
          {'key': 'counter', 'value': 17, 'updatedAtMs': 1},
        ],
      });
      c.setWatchPinned('counter', true);
      await browser.mount(tester, c, width: 640);

      Future<void> menu() async {
        final row = find.byKey(const ValueKey('compact-watch-counter'));
        await showWatchWidget(tester, row);
        await tester.tap(row, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
      }

      void expectValues(String value) {
        for (final key in [
          'compact-watch-value-counter',
          'pinned-watch-value-counter',
          'watch-detail-value-counter',
        ]) {
          expect(tester.widget<Text>(find.byKey(ValueKey(key))).data, value);
        }
      }

      await menu();
      expect(find.text('十六进制显示'), findsOneWidget);
      expect(find.text('十进制显示'), findsNothing);
      await tester.tap(find.text('十六进制显示'));
      await tester.pumpAndSettle();
      expectValues('0x0011');
      expect(c.watches.single.value, 17);
      expect(c.watches.single.editValueLabel, '17');

      final echo = c.stateSnapshot();
      for (final watch in echo['watches'] as List) {
        (watch as Map).remove('displayHex');
      }
      c.applySnapshot(echo);
      expect(c.watches.single.displayHex, isTrue);
      final restored = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(restored.dispose);
      restored.applySnapshot({
        'symbols': [for (final symbol in c.symbols) symbol.toJson()],
      });
      await restored.restoreProjectSettings(c.projectSettings());
      expect(restored.watches.single.displayHex, isTrue);
      final remote = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(remote.dispose);
      remote.applySnapshot(c.stateSnapshot());
      expect(remote.watches.single.valueLabel, '0x0011');

      await menu();
      expect(find.text('十进制显示'), findsOneWidget);
      expect(find.text('十六进制显示'), findsNothing);
      await tester.tap(find.text('十进制显示'));
      await tester.pumpAndSettle();
      expectValues('17');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode value column resizes pinned rows and preserves full edit precision',
      (tester) async {
        final c = browser.structureFixture();
        var disposed = false;
        addTearDown(() {
          if (!disposed) c.dispose();
        });
        addTearDown(() => tester.binding.setSurfaceSize(null));
        c.applySnapshot({'connectionStatus': 'connected'});
        final watch = c.watches.firstWhere(
          (w) => w.symbol.key == 'motor.speed',
        );
        watch.value = -0.4842345714569092;
        watch.updatedAtMs = 1;
        c.setWatchPinned(watch.symbol.key, true);
        await browser.mount(tester, c, width: 430, inputMode: mode);
        final normal = find.byKey(
          const ValueKey('compact-watch-value-motor.speed'),
        );
        final pinned = find.byKey(
          const ValueKey('pinned-watch-value-motor.speed'),
        );
        final handle = find.byKey(const ValueKey('watch-value-column-resize'));
        String displayed() => tester.widget<Text>(normal).data!;
        await tester.drag(handle, const Offset(35, 0));
        await tester.pump();
        final narrow = displayed();
        final narrowWidth = tester.getSize(normal).width;
        await tester.drag(handle, const Offset(-110, 0));
        await tester.pump();
        expect(tester.getSize(normal).width, greaterThan(narrowWidth));
        expect(displayed().length, greaterThan(narrow.length));
        expect(displayed(), tester.widget<Text>(pinned).data);
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('browser-preview')),
              )
              .toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory('build/watch_precision').createSync(recursive: true);
          File(
            'build/watch_precision/${mode.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        final wide = displayed();
        await tester.drag(handle, const Offset(500, 0));
        await tester.pump();
        expect(displayed().length, lessThan(wide.length));
        final shortened = displayed();
        final input = await editWatchValue(tester, watch.symbol.key);
        final full = tester.widget<TextField>(input).controller!.text;
        expect(full, '-0.484234571');
        expect(full.length, greaterThan(shortened.length));
        await tester.enterText(input, '0.123456789');
        await tester.drag(handle, const Offset(-110, 0));
        await tester.pump();
        // Resizing can blur the editor, but never truncates the draft or writes it.
        expect(c.watchInputDrafts[watch.symbol.key], '0.123456789');
        expect(watch.value, -0.4842345714569092);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        disposed = true;
        await tester.pump(const Duration(milliseconds: 400));
      },
    );
  }
}
