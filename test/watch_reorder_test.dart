import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

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

  testWidgets('dragging a watch row changes its section order', (tester) async {
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
      ValueKey<String>(
        'watch-reorder-members-${controller.watches.first.symbol.key}',
      ),
    );
    final secondRow = find.byKey(
      ValueKey<String>(
        'watch-reorder-members-${controller.watches[1].symbol.key}',
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(firstRow),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump();
    final target = tester.getBottomLeft(secondRow) + const Offset(40, -2);
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.compactWatchSectionOrders['members'], [
      controller.watches[1].symbol.key,
      controller.watches[0].symbol.key,
      controller.watches[2].symbol.key,
    ]);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
