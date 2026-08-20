import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';
import 'package:take_a_look_v2/src/window_sync.dart';
import 'package:take_a_look_v2/src/workspace.dart';

void main() {
  testWidgets('symbol panel groups variables into an expandable source tree', (
    tester,
  ) async {
    final controller = TakeALookController()..loadDemoSymbols();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 850,
            height: 600,
            child: buildWorkspacePanel(WorkspacePanelId.symbols, controller),
          ),
        ),
      ),
    );

    expect(find.text('来源文件 / 变量'), findsOneWidget);
    expect(find.text('地址'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('段'), findsOneWidget);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('control'), findsOneWidget);
    expect(find.text('foc_current.c'), findsNothing);
    expect(find.text('iq_ref'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('symbol-tree-toggle-source/control')),
    );
    await tester.pump();
    expect(find.text('foc_current.c'), findsOneWidget);
    expect(find.text('iq_ref'), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey('symbol-tree-toggle-source/control/foc_current.c'),
      ),
    );
    await tester.pump();
    expect(find.text('iq_ref'), findsOneWidget);
    expect(find.text('.bss'), findsWidgets);

    await tester.tap(
      find.byKey(
        const ValueKey('symbol-tree-toggle-source/control/foc_current.c'),
      ),
    );
    await tester.pump();
    expect(find.text('iq_ref'), findsNothing);
    await tester.tap(
      find.byKey(
        const ValueKey('symbol-tree-toggle-source/control/foc_current.c'),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('iq_ref'));
    await tester.pump();
    expect(controller.selectedSymbols, contains(demoSymbols.first.key));

    await tester.tap(find.text('foc_current.c'));
    await tester.pump();
    await tester.tap(find.text('iq_ref'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('iq_ref'));
    await tester.pump();
    expect(controller.watches, hasLength(1));
    expect(controller.selectedSymbols, isEmpty);

    await tester.tap(find.text('control'));
    await tester.pump();
    expect(controller.selectedSymbols, hasLength(4));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'symbol columns resize independently and right drag scales rows',
    (tester) async {
      final controller = TakeALookController()..loadDemoSymbols();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 850,
              height: 600,
              child: buildWorkspacePanel(WorkspacePanelId.symbols, controller),
            ),
          ),
        ),
      );

      final content = find.byKey(const ValueKey('symbol-table-content'));
      final resizeRegion = find.byKey(
        const ValueKey('symbol-table-resize-region'),
      );
      final row = find.byKey(const ValueKey('symbol-tree-row-source/control'));
      final initialWidth = tester.getSize(content).width;
      final initialRowHeight = tester.getSize(row).height;
      for (var index = 0; index < 5; index += 1) {
        expect(
          find.byKey(ValueKey('symbol-column-resize-$index')),
          findsOneWidget,
        );
      }
      final columnGesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('symbol-column-resize-0'))),
        kind: PointerDeviceKind.mouse,
      );
      await columnGesture.moveBy(const Offset(24, 0));
      await columnGesture.up();
      await tester.pump();

      expect(tester.getSize(content).width, closeTo(initialWidth + 24, 0.01));
      expect(tester.getSize(row).height, initialRowHeight);

      final widthAfterColumnResize = tester.getSize(content).width;
      final gesture = await tester.startGesture(
        tester.getCenter(resizeRegion),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.moveBy(const Offset(20, 12));
      await tester.pump();

      expect(
        tester.getSize(content).width,
        closeTo(widthAfterColumnResize + 75, 0.01),
      );
      expect(tester.getSize(row).height, closeTo(initialRowHeight + 9, 0.01));

      await gesture.up();
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('symbol search keeps matching variables and their ancestors', (
    tester,
  ) async {
    final controller = TakeALookController()..loadDemoSymbols();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 520,
            child: buildWorkspacePanel(WorkspacePanelId.symbols, controller),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'speed_rpm');
    await tester.pump();
    final searchField = tester.widget<TextField>(
      find.byKey(const ValueKey('symbol-search-field')),
    );
    expect(searchField.focusNode!.hasFocus, isTrue);
    expect(find.text('control'), findsOneWidget);
    expect(find.text('foc_speed.c'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'speed_rpm',
      ),
      findsOneWidget,
    );
    expect(find.text('iq_ref'), findsNothing);

    controller.selectSymbols([demoSymbols.first.key]);
    await tester.pump();
    expect(searchField.focusNode!.hasFocus, isTrue);
    expect(searchField.controller!.text, 'speed_rpm');

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('symbol search keeps focus when its workspace comes to front', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TakeALookController()..loadDemoSymbols();
    final windowSync = MainWindowSync(controller);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            controller: controller,
            windowSync: windowSync,
          ),
        ),
      ),
    );

    final fieldFinder = find.byKey(const ValueKey('symbol-search-field'));
    await tester.tap(fieldFinder);
    await tester.pump();
    final field = tester.widget<TextField>(fieldFinder);
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.enterText(fieldFinder, 'speed_rpm');
    await tester.pump(const Duration(milliseconds: 100));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.text, 'speed_rpm');

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
