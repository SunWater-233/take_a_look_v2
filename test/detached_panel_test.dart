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
    expect(launch.role, SecondaryWindowRole.detachedPanel);
  });

  test('drag preview arguments preserve role and screen position', () {
    const position = Offset(1180, 240);
    final arguments = encodePanelArguments(
      WorkspacePanelId.symbols,
      const Size(540, 700),
      role: SecondaryWindowRole.dragPreview,
      initialPosition: position,
    );
    final launch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      'preview',
      arguments,
    ]);

    expect(launch!.role, SecondaryWindowRole.dragPreview);
    expect(launch.initialPosition, position);
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
    final initialFrame = tester.widget<TalPanelFrame>(
      find.byType(TalPanelFrame),
    );
    expect(initialFrame.chrome!.tabsDraggable, isTrue);
    expect(initialFrame.chrome!.draggable, isFalse);

    await tester.tap(find.text(WorkspacePanelId.runControl.title).last);
    await tester.pump();
    final frame = tester.widget<TalPanelFrame>(find.byType(TalPanelFrame));
    expect(frame.panel, WorkspacePanelId.runControl);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('detached window can replace its assigned panel', (tester) async {
    final controller = TakeALookController();

    Future<void> pumpPanel(WorkspacePanelId panel) {
      return tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: DetachedPanelWindow(controller: controller, panel: panel),
        ),
      );
    }

    await pumpPanel(WorkspacePanelId.sampling);
    final samplingFrame = tester.widget<TalPanelFrame>(
      find.byType(TalPanelFrame),
    );
    expect(samplingFrame.panel, WorkspacePanelId.sampling);
    expect(samplingFrame.chrome!.draggable, isTrue);
    expect(samplingFrame.chrome!.tabsDraggable, isFalse);

    await pumpPanel(WorkspacePanelId.plot);
    expect(
      tester.widget<TalPanelFrame>(find.byType(TalPanelFrame)).panel,
      WorkspacePanelId.plot,
    );

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detached title bar fits a narrow window', (tester) async {
    await tester.binding.setSurfaceSize(const Size(340, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TalWindowTitleBar(subtitle: '实时调参'),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('drag preview contains only the selected tab and its body', (
    tester,
  ) async {
    final controller = TakeALookController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: SizedBox(
          width: 440,
          height: 560,
          child: TabContentDragPreviewWindow(
            controller: controller,
            panel: WorkspacePanelId.connection,
          ),
        ),
      ),
    );

    expect(find.byType(TalPanelTabSurface), findsOneWidget);
    expect(find.byType(TalPanelFrame), findsNothing);
    expect(find.byType(TalWindowTitleBar), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('tab-content-drag-preview-body')),
      findsOneWidget,
    );
    expect(find.text(WorkspacePanelId.connection.title), findsOneWidget);
    expect(find.text('探针'), findsOneWidget);
    expect(find.text(WorkspacePanelId.watch.title), findsNothing);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
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
