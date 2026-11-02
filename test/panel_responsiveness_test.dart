import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  testWidgets('panel frame draws a visible one-pixel outline above its body', (
    tester,
  ) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.runControl, controller),
        ),
      ),
    );

    final frame = tester.widget<Container>(
      find.byKey(const ValueKey<String>('panel-frame-runControl')),
    );
    final decoration = frame.foregroundDecoration! as BoxDecoration;
    expect(
      decoration.border,
      Border.all(color: TalColors.panelBorder, width: 1),
    );

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('header panel fits a narrow dock without overflow', (
    tester,
  ) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 150,
              child: buildWorkspacePanel(
                WorkspacePanelId.header,
                controller,
                chrome: PanelChrome(
                  tabs: [
                    WorkspacePanelId.header,
                    WorkspacePanelId.runControl,
                    WorkspacePanelId.sampling,
                  ],
                  activePanel: WorkspacePanelId.header,
                  highlighted: false,
                  onSelect: (_) {},
                  onFloat: () {},
                  onClose: () {},
                  onSeparate: () {},
                  onDragStart: (_) {},
                  onDragUpdate: (_) {},
                  onDragEnd: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('连接探针'), findsOneWidget);
    expect(find.text('采样率'), findsOneWidget);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('watch table remains horizontally scrollable in a narrow dock', (
    tester,
  ) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              height: 420,
              child: buildWorkspacePanel(WorkspacePanelId.watch, controller),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('绘制颜色'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('watch columns resize independently and right drag scales rows', (
    tester,
  ) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 420,
            child: buildWorkspacePanel(WorkspacePanelId.watch, controller),
          ),
        ),
      ),
    );

    final content = find.byKey(const ValueKey('watch-table-content'));
    final resizeRegion = find.byKey(
      const ValueKey('watch-table-resize-region'),
    );
    final row = find.byKey(ValueKey<String>(demoSymbols.first.key));
    final initialWidth = tester.getSize(content).width;
    final initialRowHeight = tester.getSize(row).height;
    for (var index = 0; index < 10; index += 1) {
      expect(
        find.byKey(ValueKey('watch-column-resize-$index')),
        findsOneWidget,
      );
    }
    final columnGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('watch-column-resize-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await columnGesture.moveBy(const Offset(24, 0));
    await columnGesture.up();
    await tester.pump();

    expect(tester.getSize(content).width, closeTo(initialWidth + 24, 0.01));
    expect(tester.getSize(row).height, initialRowHeight);

    final widthAfterColumnResize = tester.getSize(content).width;
    final gesture = await tester.startGesture(
      tester.getTopLeft(resizeRegion) + const Offset(250, 80),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.moveBy(const Offset(20, 10));
    await tester.pump();

    expect(
      tester.getSize(content).width,
      closeTo(widthAfterColumnResize + 170, 0.01),
    );
    expect(tester.getSize(row).height, closeTo(initialRowHeight + 8.5, 0.01));

    await gesture.up();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('watch color picker updates the plotted series color', (
    tester,
  ) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch();
    var plotEvents = 0;
    controller.plotChanges.addListener(() => plotEvents += 1);

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

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('watch-color-${demoSymbols.first.key}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择绘制颜色'), findsOneWidget);

    await tester.tap(
      find.byKey(
        ValueKey('watch-color-preset-${TalChartColors.blue.toARGB32()}'),
      ),
    );
    // Opening the picker may also highlight its watch row. Count the color
    // commit separately from that independent plot-selection notification.
    final eventsBeforeConfirm = plotEvents;
    await tester.tap(find.byKey(const ValueKey('watch-color-confirm')));
    await tester.pumpAndSettle();

    expect(controller.watches.single.color, TalChartColors.blue);
    expect(plotEvents - eventsBeforeConfirm, 1);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('panel buttons match the search field height', (tester) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              height: 500,
              child: buildWorkspacePanel(WorkspacePanelId.symbols, controller),
            ),
          ),
        ),
      ),
    );

    final button = find.widgetWithText(OutlinedButton, '选择文件');
    final searchField = find.byType(TextField);
    expect(tester.getSize(button).height, 32);
    expect(tester.getSize(button).height, tester.getSize(searchField).height);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('sampling controls stay aligned to the panel left edge', (
    tester,
  ) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              height: 220,
              child: buildWorkspacePanel(WorkspacePanelId.sampling, controller),
            ),
          ),
        ),
      ),
    );

    final frame = find.byKey(const ValueKey<String>('panel-frame-sampling'));
    final elapsed = find.text(controller.elapsedLabel);
    expect(
      tester.getTopLeft(elapsed).dx - tester.getTopLeft(frame).dx,
      closeTo(12, 1),
    );

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('probe dropdown uses the compact anchored menu style', (
    tester,
  ) async {
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              height: 500,
              child: buildWorkspacePanel(
                WorkspacePanelId.connection,
                controller,
              ),
            ),
          ),
        ),
      ),
    );

    final anchor = find.byKey(
      const ValueKey<String>('compact-dropdown-自动发现任意探针'),
    );
    final anchorRect = tester.getRect(anchor);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(anchorRect.center);
    await tester.pump();
    final hoveredAnchor = tester.widget<Container>(anchor);
    expect((hoveredAnchor.decoration! as BoxDecoration).color, TalColors.hover);

    await tester.tap(anchor);
    await tester.pump();
    final animationFinder = find.byKey(
      const ValueKey<String>('dropdown-menu-animation'),
    );
    final openingHeight = tester.getSize(animationFinder).height;
    await tester.pump(const Duration(milliseconds: 150));
    final halfwayHeight = tester.getSize(animationFinder).height;
    expect(halfwayHeight, greaterThan(openingHeight));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    final expandedHeight = tester.getSize(animationFinder).height;
    expect(expandedHeight, greaterThan(halfwayHeight));
    await tester.pumpAndSettle();

    final selectedItem = find.byKey(
      const ValueKey<String>('dropdown-item-自动发现任意探针'),
    );
    final selectedRect = tester.getRect(selectedItem);
    expect(selectedRect.left, closeTo(anchorRect.left, 1));
    expect(selectedRect.width, closeTo(anchorRect.width, 1));
    expect(selectedRect.height, closeTo(32, 1));

    final selectedSurface = tester.widget<Container>(
      find.byKey(const ValueKey<String>('dropdown-selected-自动发现任意探针')),
    );
    final decoration = selectedSurface.decoration! as BoxDecoration;
    expect(
      decoration.border,
      const Border(left: BorderSide(color: TalColors.accent, width: 3)),
    );

    await mouse.moveTo(selectedRect.center);
    await tester.pump();
    final hoveredSelectedSurface = tester.widget<Container>(
      find.byKey(const ValueKey<String>('dropdown-selected-自动发现任意探针')),
    );
    expect(
      (hoveredSelectedSurface.decoration! as BoxDecoration).color,
      TalColors.hover,
    );

    await mouse.moveTo(const Offset(800, 600));
    await tester.pump();
    final restoredSelectedSurface = tester.widget<Container>(
      find.byKey(const ValueKey<String>('dropdown-selected-自动发现任意探针')),
    );
    expect(
      (restoredSelectedSurface.decoration! as BoxDecoration).color,
      TalColors.selection,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dropdown-item-CMSIS-DAP')),
    );
    await tester.pump();
    final closingStartHeight = tester.getSize(animationFinder).height;
    await tester.pump(const Duration(milliseconds: 90));
    final closingHalfwayHeight = tester.getSize(animationFinder).height;
    expect(closingHalfwayHeight, lessThan(closingStartHeight));
    expect(animationFinder, findsOneWidget);
    await tester.pumpAndSettle();
    expect(animationFinder, findsNothing);
    expect(controller.probeType, 'CMSIS-DAP');

    await mouse.removePointer();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
