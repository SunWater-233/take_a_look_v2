import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

Finder member(String label) => find.descendant(
  of: find.byKey(const ValueKey('compact-watch-list')),
  matching: find.text(label),
);

void main() {
  Future<TakeALookController> pumpWatchTable(WidgetTester tester) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((symbol) => symbol.key));
    controller.addSelectedToWatch();
    controller.setAllWatchesPlotted(true);
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
    return controller;
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  testWidgets('watch panel Delete and Ctrl+Z restore row selection and data', (
    tester,
  ) async {
    final controller = await pumpWatchTable(tester);
    final key = controller.watches.first.symbol.key;
    controller.applyBackendSamples({
      'frames': [
        {
          'elapsed': 1.0,
          'values': {key: 12.0},
        },
      ],
    });
    await tester.tap(member('iq_ref'));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(member('iq_ref'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(member('iq_ref'), findsOneWidget);
    expect(controller.watches.first.samples.single.dy, 12);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(member('iq_ref'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('watch row menus honor Ctrl Shift and Ctrl+A selections', (
    tester,
  ) async {
    final controller = await pumpWatchTable(tester);

    final first = member('iq_ref');
    final third = member('speed_rpm');
    await tester.tap(first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(third);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await rightClick(tester, third);
    expect(find.text('删除所选变量（3）'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    await tester.tap(first);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(third);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await rightClick(tester, first);
    expect(find.text('删除所选变量（2）'), findsOneWidget);
    await tester.tap(find.text('孤立'));
    await tester.pumpAndSettle();
    expect(controller.watches.map((watch) => watch.plotted), [
      true,
      false,
      true,
    ]);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await rightClick(tester, member('id_ref'));
    expect(find.text('删除所选变量（3）'), findsOneWidget);
    await tester.tap(find.text('颜色调整'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('watch-color-preset-${TalChartColors.blue.toARGB32()}'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('watch-color-confirm')));
    await tester.pumpAndSettle();
    expect(
      controller.watches.every((watch) => watch.color == TalChartColors.blue),
      isTrue,
    );

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'aggregate watches expand as a tree with sampling and visibility actions',
    (tester) async {
      final controller = TakeALookController();
      controller.applySnapshot({
        'symbols': [
          {
            'source': 'motor.c',
            'name': 'motor',
            'address': 0x20000000,
            'type': 'struct MotorState',
            'size': 8,
            'section': '.bss',
            'key': 'motor',
          },
          {
            'source': 'motor.c',
            'name': 'motor.speed',
            'address': 0x20000000,
            'type': 'float',
            'size': 4,
            'section': '.bss',
            'key': 'motor.speed',
          },
          {
            'source': 'motor.c',
            'name': 'motor.current',
            'address': 0x20000004,
            'type': 'float',
            'size': 4,
            'section': '.bss',
            'key': 'motor.current',
          },
        ],
        'watches': <Object?>[],
      });
      controller.selectSymbols(const ['motor']);
      controller.addSelectedToWatch();

      expect(controller.watches, hasLength(3));
      expect(
        controller.watches.every((watch) => !watch.samplingEnabled),
        isTrue,
      );
      expect(controller.watches.every((watch) => !watch.plotted), isTrue);

      controller.compactExpandedWatches.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 520,
              child: buildWorkspacePanel(WorkspacePanelId.watch, controller),
            ),
          ),
        ),
      );
      expect(member('speed'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('compact-watch-motor')));
      await tester.pump();
      expect(member('speed'), findsOneWidget);
      expect(member('current'), findsOneWidget);

      final mode = find.byKey(
        const ValueKey('compact-watch-capture-motor.speed'),
      );
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      final speed = controller.watches.firstWhere(
        (watch) => watch.symbol.key == 'motor.speed',
      );
      expect(speed.samplingEnabled, isTrue);
      expect(speed.plotted, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('compact-watch-plot-motor.speed')),
      );
      await tester.tap(
        find.byKey(const ValueKey('compact-watch-plot-motor.speed')),
      );
      await tester.pump();
      expect(speed.samplingEnabled, isTrue);
      expect(speed.plotted, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('compact-watch-plot-motor.speed')),
      );
      await tester.pump();
      expect(speed.samplingEnabled, isTrue);
      expect(speed.plotted, isTrue);
      expect(find.byType(Checkbox), findsNothing);

      await tester.ensureVisible(member('current'));
      await rightClick(tester, member('current'));
      expect(find.text('恢复成员'), findsNothing);
      await tester.tap(find.text('删除变量'));
      await tester.pumpAndSettle();
      expect(member('current'), findsNothing);
      await tester.ensureVisible(member('motor'));
      await rightClick(tester, member('motor'));
      expect(find.text('恢复成员'), findsOneWidget);
      await tester.tap(find.text('恢复成员'));
      await tester.pumpAndSettle();
      expect(member('current'), findsOneWidget);
      expect(controller.watches.map((w) => w.symbol.key), [
        'motor',
        'motor.speed',
        'motor.current',
      ]);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
