import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
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
}
