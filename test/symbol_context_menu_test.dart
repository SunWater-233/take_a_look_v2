import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

final _fileRow = find.byKey(
  const ValueKey('symbol-tree-row-source/control/foc_current.c'),
);
final _tableContent = find.byKey(const ValueKey('symbol-table-content'));
final _fileMenu = find.text('添加到源码调试');

void _testSymbols(
  String description,
  Future<void> Function(WidgetTester, TakeALookController) body,
) {
  testWidgets(description, (tester) async {
    final controller = TakeALookController()..loadDemoSymbols();
    try {
      await _pumpSymbols(tester, controller);
      await body(tester, controller);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });
}

Future<void> _pumpSymbols(
  WidgetTester tester,
  TakeALookController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(),
      home: Scaffold(
        body: buildWorkspacePanel(WorkspacePanelId.symbols, controller),
      ),
    ),
  );
  await tester.tap(find.text('control'));
  await tester.pumpAndSettle();
}

void main() {
  for (final delta in [
    Offset.zero,
    const Offset(1, 1),
    const Offset(4, 0),
    const Offset(3, 4),
  ]) {
    _testSymbols('file right click with $delta jitter opens only on release', (
      tester,
      _,
    ) async {
      final initialRowSize = tester.getSize(_fileRow);
      final initialTableSize = tester.getSize(_tableContent);
      final click = await tester.startGesture(
        tester.getTopLeft(_fileRow) + const Offset(150, 15),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(_fileMenu, findsNothing);
      await click.moveBy(delta);
      await tester.pump();
      expect(_fileMenu, findsNothing);
      expect(tester.getSize(_fileRow), initialRowSize);
      expect(tester.getSize(_tableContent), initialTableSize);

      await click.up();
      await tester.pumpAndSettle();
      expect(_fileMenu, findsOneWidget);
      expect(tester.getSize(_fileRow), initialRowSize);
      expect(tester.getSize(_tableContent), initialTableSize);
    });
  }

  for (final scenario in [
    (hold: Duration.zero, delta: const Offset(6, 0)),
    (hold: const Duration(milliseconds: 250), delta: const Offset(24, 16)),
    (hold: Duration.zero, delta: const Offset(0, 8)),
  ]) {
    _testSymbols(
      'file right drag ${scenario.delta} after ${scenario.hold} resizes without a menu',
      (tester, controller) async {
        final initialHeight = tester.getSize(_fileRow).height;
        final initialWidth = tester.getSize(_tableContent).width;
        final drag = await tester.startGesture(
          tester.getTopLeft(_fileRow) + const Offset(150, 15),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump(scenario.hold);
        expect(_fileMenu, findsNothing);
        await drag.moveBy(scenario.delta);
        await tester.pump();
        expect(
          tester.getSize(_tableContent).width,
          closeTo(initialWidth + scenario.delta.dx * 0.75 * 5, 0.001),
        );
        expect(
          tester.getSize(_fileRow).height,
          closeTo(initialHeight + scenario.delta.dy * 0.75, 0.001),
        );
        expect(_fileMenu, findsNothing);

        await drag.up();
        await tester.pumpAndSettle();
        expect(_fileMenu, findsNothing);
        expect(controller.selectedSymbols, isEmpty);
        expect(controller.sourceWorkspace.openPaths, isEmpty);
      },
    );
  }

  _testSymbols(
    'returning a right drag to its origin still suppresses the menu',
    (tester, _) async {
      final initialHeight = tester.getSize(_fileRow).height;
      final initialWidth = tester.getSize(_tableContent).width;
      final start = tester.getTopLeft(_fileRow) + const Offset(150, 15);
      final drag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await drag.moveBy(const Offset(24, 16));
      await tester.pump();
      expect(tester.getSize(_fileRow).height, greaterThan(initialHeight));
      await drag.moveTo(start);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(_fileMenu, findsNothing);
      expect(tester.getSize(_fileRow).height, initialHeight);
      expect(tester.getSize(_tableContent).width, initialWidth);

      await tester.tap(
        find.text('foc_speed.c'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('speed_rpm'), findsOneWidget);
      expect(find.text('iq_ref'), findsNothing);
    },
  );

  for (final resizeBeforeCancel in [false, true]) {
    _testSymbols(
      'cancelling a right ${resizeBeforeCancel ? 'drag' : 'click'} never opens a menu',
      (tester, _) async {
        final gesture = await tester.startGesture(
          tester.getTopLeft(_fileRow) + const Offset(150, 15),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        if (resizeBeforeCancel) {
          await gesture.moveBy(const Offset(24, 16));
        }
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(_fileMenu, findsNothing);

        await tester.tap(
          find.text('foc_current.c'),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(_fileMenu, findsOneWidget);
      },
    );
  }

  _testSymbols(
    'directory right click jitter leaves table dimensions unchanged',
    (tester, _) async {
      final folder = find.byKey(
        const ValueKey('symbol-tree-row-source/control'),
      );
      final initialSize = tester.getSize(folder);
      final initialTableSize = tester.getSize(_tableContent);
      final click = await tester.startGesture(
        tester.getTopLeft(folder) + const Offset(150, 15),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.moveBy(const Offset(1, 1));
      await click.up();
      await tester.pumpAndSettle();
      expect(tester.getSize(folder), initialSize);
      expect(tester.getSize(_tableContent), initialTableSize);
      expect(_fileMenu, findsNothing);
    },
  );

  _testSymbols('touch long press still opens the file menu without resizing', (
    tester,
    _,
  ) async {
    final initialSize = tester.getSize(_fileRow);
    final touch = await tester.startGesture(
      tester.getTopLeft(_fileRow) + const Offset(150, 15),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(_fileMenu, findsOneWidget);
    expect(tester.getSize(_fileRow), initialSize);
    await touch.up();
  });
}
