import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

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

  testWidgets('connection dropdown uses the compact anchored menu style', (
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

    final anchor = find.byKey(const ValueKey<String>('compact-dropdown-auto'));
    final anchorRect = tester.getRect(anchor);
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
      const ValueKey<String>('dropdown-item-auto'),
    );
    final selectedRect = tester.getRect(selectedItem);
    expect(selectedRect.left, closeTo(anchorRect.left, 1));
    expect(selectedRect.width, closeTo(anchorRect.width, 1));
    expect(selectedRect.height, closeTo(32, 1));

    final selectedSurface = tester.widget<Container>(
      find.byKey(const ValueKey<String>('dropdown-selected-auto')),
    );
    final decoration = selectedSurface.decoration! as BoxDecoration;
    expect(
      decoration.border,
      const Border(left: BorderSide(color: TalColors.accent, width: 3)),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dropdown-item-stm32f407vg')),
    );
    await tester.pump();
    final closingStartHeight = tester.getSize(animationFinder).height;
    await tester.pump(const Duration(milliseconds: 90));
    final closingHalfwayHeight = tester.getSize(animationFinder).height;
    expect(closingHalfwayHeight, lessThan(closingStartHeight));
    expect(animationFinder, findsOneWidget);
    await tester.pumpAndSettle();
    expect(animationFinder, findsNothing);
    expect(controller.targetName, 'stm32f407vg');

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
