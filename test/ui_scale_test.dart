import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';

void main() {
  test('UI scale is included in synchronized controller snapshots', () {
    final source = TakeALookController()..setUiScale(1.45);
    final target = TakeALookController()..applySnapshot(source.snapshot());

    expect(target.uiScale, 1.45);

    source.dispose();
    target.dispose();
  });

  testWidgets('UI scale resizes the logical viewport and preserves hit tests', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Size logicalSize;
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: TalUiScaleViewport(
          scale: 1.25,
          child: LayoutBuilder(
            builder: (context, constraints) {
              logicalSize = constraints.biggest;
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 40,
                  child: TextButton(
                    onPressed: () => tapped = true,
                    child: const Text('Scale target'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(logicalSize, const Size(400, 320));
    expect(tester.getSize(find.byType(TextButton)), const Size(100, 40));
    expect(tester.getRect(find.byType(TextButton)).size, const Size(125, 50));

    await tester.tap(find.byType(TextButton));
    expect(tapped, isTrue);
  });

  testWidgets('changing scale through 100% preserves child state', (
    tester,
  ) async {
    Future<void> pumpScale(double scale) => tester.pumpWidget(
      MaterialApp(
        home: TalUiScaleViewport(
          scale: scale,
          child: const Scaffold(body: TextField()),
        ),
      ),
    );

    await pumpScale(1);
    final initialState = tester.state(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'preserved');
    for (final scale in [1.25, 1.0, 0.85, 1.0]) {
      await pumpScale(scale);
      expect(tester.state(find.byType(TextField)), same(initialState));
      expect(find.text('preserved'), findsOneWidget);
    }
  });
}
