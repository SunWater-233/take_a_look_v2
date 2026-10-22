import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
