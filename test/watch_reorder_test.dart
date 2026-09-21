import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  TakeALookController controllerWithWatches() {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    return controller;
  }

  test('reordering watches also invalidates the plot in the same order', () {
    final controller = controllerWithWatches();
    var watchEvents = 0;
    var plotEvents = 0;
    controller.watchChanges.addListener(() => watchEvents += 1);
    controller.plotChanges.addListener(() => plotEvents += 1);

    controller.reorderWatch(0, 2);

    expect(controller.watches.map((watch) => watch.symbol.name), [
      'id_ref',
      'speed_rpm',
      'iq_ref',
    ]);
    expect(watchEvents, 1);
    expect(plotEvents, 1);
    expect(
      (controller.stateSnapshot()['watches'] as List).map(
        (watch) => (watch as Map)['key'],
      ),
      controller.watches.map((watch) => watch.symbol.key),
    );
    controller.dispose();
  });

  testWidgets('long pressing a watch row allows it to be dragged into order', (
    tester,
  ) async {
    final controller = controllerWithWatches();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 520,
            child: buildWorkspacePanel(WorkspacePanelId.watch, controller),
          ),
        ),
      ),
    );

    final firstRow = find.byKey(
      ValueKey<String>('watch-reorder-${controller.watches.first.symbol.key}'),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(firstRow),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    final dragProxy = find.byKey(const ValueKey('watch-drag-proxy'));
    expect(dragProxy, findsOneWidget);
    final proxyClip = tester.widget<ClipRect>(dragProxy);
    final proxySize = tester.getSize(dragProxy);
    expect(
      proxyClip.clipper!.getClip(proxySize).width,
      lessThan(proxySize.width),
    );
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.watches.map((watch) => watch.symbol.name), [
      'id_ref',
      'iq_ref',
      'speed_rpm',
    ]);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
