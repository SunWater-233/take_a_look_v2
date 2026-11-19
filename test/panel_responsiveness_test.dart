import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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

  testWidgets('watch panel fits a narrow dock', (tester) async {
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
    expect(find.byKey(const ValueKey('compact-watch-list')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('watch color picker updates the plotted series color', (
    tester,
  ) async {
    final controller = TakeALookController()..loadDemoSymbols();
    controller.selectSymbols([demoSymbols.first.key]);
    controller.addSelectedToWatch();
    controller.setAllWatchesPlotted(true);
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

    final color = find.byKey(
      ValueKey('compact-watch-color-${demoSymbols.first.key}'),
    );
    await tester.tap(color);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(color);
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
