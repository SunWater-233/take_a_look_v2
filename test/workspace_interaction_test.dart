import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';
import 'package:take_a_look_v2/src/window_sync.dart';
import 'package:take_a_look_v2/src/workspace.dart';

void main() {
  testWidgets('dragging a tab onto another tab strip combines panels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: MainWindowSync(controller),
          ),
        ),
      ),
    );
    workspaceKey.currentState!.setGridMode(true);
    await tester.pump();

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final symbolsGroup = find.byKey(const ValueKey('workspace-group-symbols'));
    final sourceTab = find.descendant(
      of: headerGroup,
      matching: find.text(WorkspacePanelId.runControl.title),
    );
    final targetTab = find.descendant(
      of: symbolsGroup,
      matching: find.text(WorkspacePanelId.watch.title),
    );
    await tester.dragFrom(
      tester.getCenter(sourceTab),
      tester.getCenter(targetTab) - tester.getCenter(sourceTab),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: headerGroup,
        matching: find.text(WorkspacePanelId.runControl.title),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: symbolsGroup,
        matching: find.text(WorkspacePanelId.runControl.title),
      ),
      findsOneWidget,
    );
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('dragging a tab out splits it while grid mode is enabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: MainWindowSync(controller),
          ),
        ),
      ),
    );
    workspaceKey.currentState!.setGridMode(true);
    await tester.pump();

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final plotGroup = find.byKey(const ValueKey('workspace-group-plot'));
    final sourceTab = find.descendant(
      of: headerGroup,
      matching: find.text(WorkspacePanelId.sampling.title),
    );
    await tester.dragFrom(
      tester.getCenter(sourceTab),
      tester.getCenter(plotGroup) - tester.getCenter(sourceTab),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('workspace-group-separated_100')),
      findsOneWidget,
    );
    expect(find.byType(TalPanelFrame), findsNWidgets(5));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('dragging a tab out opens only that panel in normal mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const createChannel = MethodChannel('mixin.one/desktop_multi_window');
    const windowChannel = MethodChannel(
      'mixin.one/window_controller/tab_window',
    );
    Map<String, dynamic>? configuration;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') {
        configuration = Map<String, dynamic>.from(call.arguments as Map);
        return 'tab_window';
      }
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(createChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
    });

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
    final windowSync = MainWindowSync(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: windowSync,
          ),
        ),
      ),
    );
    workspaceKey.currentState!.setGridMode(false);
    await tester.pump();

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final plotGroup = find.byKey(const ValueKey('workspace-group-plot'));
    final sourceTab = find.descendant(
      of: headerGroup,
      matching: find.text(WorkspacePanelId.sampling.title),
    );
    await tester.dragFrom(
      tester.getCenter(sourceTab),
      tester.getCenter(plotGroup) - tester.getCenter(sourceTab),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(configuration, isNotNull);
    final launch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      '1',
      configuration!['arguments'] as String,
    ]);
    expect(launch!.groupPanels, [WorkspacePanelId.sampling]);
    expect(find.byType(TalPanelFrame), findsNWidgets(4));
    expect(
      find.descendant(
        of: headerGroup,
        matching: find.text(WorkspacePanelId.sampling.title),
      ),
      findsNothing,
    );

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('panels only move while grid mode is enabled', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: MainWindowSync(controller),
          ),
        ),
      ),
    );

    final header = find.byKey(const ValueKey('workspace-group-header'));
    final headerTitle = find.text('${WorkspacePanelId.header.title} 组合');
    final initialRect = tester.getRect(header);

    expect(find.byKey(const ValueKey('workspace-grid')), findsNothing);
    workspaceKey.currentState!.setGridMode(false);
    await tester.pump();
    await tester.drag(headerTitle, const Offset(80, 60));
    await tester.pump();
    expect(tester.getRect(header), initialRect);

    workspaceKey.currentState!.setGridMode(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('workspace-grid')), findsOneWidget);
    await tester.drag(headerTitle, const Offset(80, 60));
    await tester.pump();
    expect(tester.getRect(header).topLeft, isNot(initialRect.topLeft));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('floating a grouped panel opens the complete group', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final createChannel = const MethodChannel('mixin.one/desktop_multi_window');
    final windowChannel = const MethodChannel(
      'mixin.one/window_controller/group_window',
    );
    Map<String, dynamic>? configuration;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') {
        configuration = Map<String, dynamic>.from(call.arguments as Map);
        return 'group_window';
      }
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(createChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
    });

    final controller = TakeALookController();
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

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final floatButton = find.descendant(
      of: headerGroup,
      matching: find.byIcon(Icons.open_in_new),
    );
    expect(floatButton, findsOneWidget);
    final floatControl = find.ancestor(
      of: floatButton,
      matching: find.byType(IconButton),
    );
    await tester.runAsync(() async {
      tester.widget<IconButton>(floatControl).onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(configuration, isNotNull);
    final launch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      '1',
      configuration!['arguments'] as String,
    ]);
    expect(launch!.groupPanels, [
      WorkspacePanelId.header,
      WorkspacePanelId.runControl,
      WorkspacePanelId.sampling,
    ]);
    expect(find.byType(TalPanelFrame), findsNWidgets(3));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('workspace panels resize, merge, split, hide, and restore', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
    final windowSync = MainWindowSync(controller);
    final tempDirectory = Directory.systemTemp.createTempSync(
      'tal_layout_test_',
    );
    addTearDown(() => tempDirectory.deleteSync(recursive: true));
    final layoutFile = File('${tempDirectory.path}/layout.json');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: DockingWorkspace(
            key: workspaceKey,
            controller: controller,
            windowSync: windowSync,
            layoutFile: layoutFile,
          ),
        ),
      ),
    );
    workspaceKey.currentState!.setGridMode(true);
    await tester.pump();

    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    final plotFrame = find.ancestor(
      of: find.text('实时图表'),
      matching: find.byType(TalPanelFrame),
    );
    final plotSizeBefore = tester.getSize(plotFrame);
    final plotResizeHandle = find.byKey(const ValueKey('resize-plot'));
    await tester.drag(plotResizeHandle, const Offset(-120, -80));
    await tester.pump();
    final plotSizeAfter = tester.getSize(plotFrame);
    expect(plotSizeAfter.width, lessThan(plotSizeBefore.width));
    expect(plotSizeAfter.height, lessThan(plotSizeBefore.height));

    await tester.drag(find.text('主标题 组合'), const Offset(760, 210));
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(3));
    final mergedFrame = find.ancestor(
      of: find.text('主标题 组合'),
      matching: find.byType(TalPanelFrame),
    );
    final mergedSplitButton = find.descendant(
      of: mergedFrame,
      matching: find.byIcon(Icons.call_split),
    );
    expect(mergedSplitButton, findsOneWidget);

    final splitControl = find.ancestor(
      of: mergedSplitButton,
      matching: find.byType(IconButton),
    );
    tester.widget<IconButton>(splitControl).onPressed!();
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    final separatedHeader = find.ancestor(
      of: find.text('主标题'),
      matching: find.byType(TalPanelFrame),
    );
    final hideButton = find.descendant(
      of: separatedHeader,
      matching: find.byTooltip('隐藏面板（可从“视图”恢复）'),
    );
    final hideControl = find.ancestor(
      of: hideButton,
      matching: find.byType(IconButton),
    );
    tester.widget<IconButton>(hideControl).onPressed!();
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(3));

    await workspaceKey.currentState!.showPanel(WorkspacePanelId.header);
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    controller.setUiScale(1.25);
    await tester.runAsync(workspaceKey.currentState!.saveLayout);
    expect(layoutFile.existsSync(), isTrue);
    controller.setUiScale(0.85);
    final restoredHeader = find.ancestor(
      of: find.text('主标题'),
      matching: find.byType(TalPanelFrame),
    );
    final restoredHideTooltip = find.descendant(
      of: restoredHeader,
      matching: find.byTooltip('隐藏面板（可从“视图”恢复）'),
    );
    final restoredHideControl = find.ancestor(
      of: restoredHideTooltip,
      matching: find.byType(IconButton),
    );
    tester.widget<IconButton>(restoredHideControl).onPressed!();
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(3));

    await tester.runAsync(workspaceKey.currentState!.restoreLayout);
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(4));
    expect(controller.uiScale, 1.25);

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
