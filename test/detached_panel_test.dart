import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  test('detached panel arguments preserve the source workspace size', () {
    const sourceSize = Size(647, 391);
    final arguments = encodePanelArguments(WorkspacePanelId.plot, sourceSize);
    final launch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      '1',
      arguments,
    ]);

    expect(launch, isNotNull);
    expect(launch!.panel, WorkspacePanelId.plot);
    expect(launch.groupPanels, [WorkspacePanelId.plot]);
    expect(launch.initialSize, sourceSize);
  });

  test('detached panel arguments preserve the complete source group', () {
    const sourceSize = Size(520, 250);
    const panels = <WorkspacePanelId>[
      WorkspacePanelId.header,
      WorkspacePanelId.runControl,
      WorkspacePanelId.sampling,
    ];
    final arguments = encodePanelArguments(
      WorkspacePanelId.runControl,
      sourceSize,
      panels: panels,
    );
    final launch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      '1',
      arguments,
    ]);

    expect(launch, isNotNull);
    expect(launch!.panel, WorkspacePanelId.runControl);
    expect(launch.groupPanels, panels);
    expect(launch.initialSize, sourceSize);
  });

  testWidgets('detached group keeps all tabs in one window', (tester) async {
    final controller = TakeALookController();
    const panels = <WorkspacePanelId>[
      WorkspacePanelId.header,
      WorkspacePanelId.runControl,
      WorkspacePanelId.sampling,
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: DetachedPanelWindow(
          controller: controller,
          panel: WorkspacePanelId.header,
          panels: panels,
        ),
      ),
    );

    for (final panel in panels) {
      expect(find.text(panel.title), findsWidgets);
    }
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    expect(find.byIcon(Icons.call_split), findsNothing);

    await tester.tap(find.text(WorkspacePanelId.runControl.title).last);
    await tester.pump();
    final frame = tester.widget<TalPanelFrame>(find.byType(TalPanelFrame));
    expect(frame.panel, WorkspacePanelId.runControl);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('every workspace panel can render in an isolated window shell', (
    tester,
  ) async {
    for (final panel in WorkspacePanelId.values) {
      final controller = TakeALookController();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: SizedBox(
            width: panel.preferredWindowSize.width,
            height: panel.preferredWindowSize.height,
            child: DetachedPanelWindow(controller: controller, panel: panel),
          ),
        ),
      );

      expect(find.text(panel.title), findsWidgets);
      expect(tester.takeException(), isNull);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('connection serial number follows synchronized state', (
    tester,
  ) async {
    final controller = TakeALookController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: DetachedPanelWindow(
          controller: controller,
          panel: WorkspacePanelId.connection,
        ),
      ),
    );

    controller.applySnapshot({
      ...controller.snapshot(),
      'serialNumber': 'remote-probe-42',
    });
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'remote-probe-42');
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
