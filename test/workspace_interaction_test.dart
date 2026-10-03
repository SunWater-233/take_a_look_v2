import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';

void main() {
  testWidgets(
    'small mouse jitter does not turn a neighboring tab click into a drag',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

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
      final samplingTab = find.descendant(
        of: headerGroup,
        matching: find.byKey(const ValueKey('panel-tab-sampling')),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(samplingTab),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(4, 1));
      await tester.pump();

      expect(
        find.descendant(
          of: headerGroup,
          matching: find.byKey(
            const ValueKey<String>('panel-tab-drag-source-sampling'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('panel-tab-drag-feedback-sampling')),
        findsNothing,
      );

      await gesture.up();
      await tester.tap(samplingTab);
      await tester.pump();
      expect(
        tester
            .widget<TalPanelFrame>(
              find.descendant(
                of: headerGroup,
                matching: find.byType(TalPanelFrame),
              ),
            )
            .panel,
        WorkspacePanelId.sampling,
      );

      await windowSync.dispose();
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dragging a tab animates neighboring tabs before reordering', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final windowSync = MainWindowSync(controller);
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
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

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    Finder tab(WorkspacePanelId panel) => find.descendant(
      of: headerGroup,
      matching: find.byKey(ValueKey('panel-tab-${panel.name}')),
    );

    expect(
      tester.getCenter(tab(WorkspacePanelId.header)).dx,
      lessThan(tester.getCenter(tab(WorkspacePanelId.sampling)).dx),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(tab(WorkspacePanelId.header)),
    );
    final samplingRect = tester.getRect(tab(WorkspacePanelId.sampling));
    await gesture.moveTo(
      Offset(samplingRect.right - 2, samplingRect.center.dy),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('panel-tab-drag-feedback-header')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (var index = 0; index < 4; index++) {
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(
      tester
          .getSize(
            find.descendant(
              of: headerGroup,
              matching: find.byKey(const ValueKey('panel-tab-gap-3')),
            ),
          )
          .width,
      greaterThan(0),
    );
    expect(
      tester.getCenter(tab(WorkspacePanelId.sampling)).dx,
      lessThan(samplingRect.center.dx),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(tab(WorkspacePanelId.header)).dx,
      greaterThan(tester.getCenter(tab(WorkspacePanelId.sampling)).dx),
    );
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('dragging a tab onto another tab strip combines panels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TakeALookController();
    final windowSync = MainWindowSync(controller);
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
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
    await tester.pumpAndSettle();

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
    expect(
      tester
          .getSize(
            find.descendant(
              of: symbolsGroup,
              matching: find.byKey(const ValueKey('panel-tab-slot-runControl')),
            ),
          )
          .width,
      greaterThan(0),
    );
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('dragging beyond the app keeps feedback and opens a window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var windowWasShown = false;
    Map<String, dynamic>? assignedPanel;
    DetachedPanelLaunch? previewConfiguration;
    final invokedMethods = <String>[];
    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') return 'short_drop_window';
      if (call.method == 'window_show') windowWasShown = true;
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method != 'invokeMethod') return null;
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      invokedMethods.add(arguments['method'] as String);
      if (arguments['method'] == prepareTabDragPreviewMethod) {
        previewConfiguration = detachedPanelLaunchFromJson(
          arguments['arguments'],
        );
      }
      if (arguments['method'] == configureDetachedPanelMethod) {
        assignedPanel = Map<String, dynamic>.from(
          arguments['arguments'] as Map,
        );
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final controller = TakeALookController();
    final windowSync = MainWindowSync(controller);
    final workspaceKey = GlobalKey<DockingWorkspaceState>();
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
    workspaceKey.currentState!.setGridMode(true);
    await tester.pump();

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final sourceTab = find.descendant(
      of: headerGroup,
      matching: find.text(WorkspacePanelId.sampling.title),
    );
    await tester.tap(sourceTab);
    await tester.pump();
    expect(
      tester
          .widget<TalPanelFrame>(
            find.descendant(
              of: headerGroup,
              matching: find.byType(TalPanelFrame),
            ),
          )
          .panel,
      WorkspacePanelId.sampling,
    );
    final gesture = await tester.startGesture(tester.getCenter(sourceTab));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(const Offset(1700, 450));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(
      find.descendant(
        of: headerGroup,
        matching: find.byKey(
          const ValueKey<String>('panel-tab-drag-source-sampling'),
        ),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<TalPanelFrame>(
            find.descendant(
              of: headerGroup,
              matching: find.byType(TalPanelFrame),
            ),
          )
          .panel,
      isNot(WorkspacePanelId.sampling),
    );
    expect(invokedMethods, contains(showTabDragPreviewMethod));
    expect(previewConfiguration!.role, SecondaryWindowRole.dragPreview);
    expect(previewConfiguration!.panel, WorkspacePanelId.sampling);
    expect(previewConfiguration!.initialSize.width, greaterThan(300));
    expect(previewConfiguration!.initialSize.height, greaterThan(100));
    expect(previewConfiguration!.initialSize.height, lessThan(150));
    await gesture.up();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(windowWasShown, isTrue);
    expect(
      detachedPanelLaunchFromJson(assignedPanel)!.panel,
      WorkspacePanelId.sampling,
    );
    expect(
      detachedPanelLaunchFromJson(assignedPanel)!.initialPosition,
      isNotNull,
    );
    expect(
      find.byKey(const ValueKey('workspace-group-separated_100')),
      findsNothing,
    );
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('moving within a target still highlights and merges the tab', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') return 'merge_preview_window';
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

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

    final headerGroup = find.byKey(const ValueKey('workspace-group-header'));
    final plotGroup = find.byKey(const ValueKey('workspace-group-plot'));
    final sourceTab = find.descendant(
      of: headerGroup,
      matching: find.text(WorkspacePanelId.sampling.title),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(sourceTab),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(plotGroup));
    await tester.pump();
    expect(workspaceKey.currentState!.debugTabMergeCandidate, 'plot');

    TalPanelFrame plotFrame() => tester.widget<TalPanelFrame>(
      find.descendant(of: plotGroup, matching: find.byType(TalPanelFrame)),
    );
    expect(plotFrame().chrome!.highlighted, isFalse);
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(plotFrame().chrome!.highlighted, isFalse);
    }
    await tester.pump(const Duration(milliseconds: 49));
    expect(plotFrame().chrome!.highlighted, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(plotFrame().chrome!.highlighted, isTrue);
    final frameContainer = tester.widget<Container>(
      find.byKey(const ValueKey('panel-frame-group-plot')),
    );
    final decoration = frameContainer.foregroundDecoration! as BoxDecoration;
    expect(decoration.border, Border.all(color: TalColors.accent, width: 3));
    await gesture.moveBy(const Offset(20, 10));
    await tester.pump();
    expect(plotFrame().chrome!.highlighted, isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(plotFrame().chrome!.highlighted, isFalse);

    expect(
      find.descendant(
        of: headerGroup,
        matching: find.text(WorkspacePanelId.sampling.title),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: plotGroup,
        matching: find.text(WorkspacePanelId.sampling.title),
      ),
      findsOneWidget,
    );

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving or switching tab targets resets their highlight', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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

    Finder group(String id) => find.byKey(ValueKey('workspace-group-$id'));
    bool highlighted(String id) => tester
        .widget<TalPanelFrame>(
          find.descendant(of: group(id), matching: find.byType(TalPanelFrame)),
        )
        .chrome!
        .highlighted;
    final sourceTab = find.byKey(const ValueKey('panel-tab-sampling'));
    final gesture = await tester.startGesture(
      tester.getCenter(sourceTab),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(group('plot')));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(group('symbols')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(highlighted('plot'), isFalse);
    expect(highlighted('symbols'), isFalse);

    await gesture.moveTo(const Offset(1700, 450));
    await tester.pump(const Duration(milliseconds: 500));
    expect(highlighted('symbols'), isFalse);
    await gesture.moveTo(tester.getCenter(group('symbols')));
    await tester.pump(const Duration(milliseconds: 299));
    expect(highlighted('symbols'), isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(highlighted('symbols'), isTrue);

    await gesture.moveTo(tester.getCenter(group('plot')));
    await tester.pump(const Duration(milliseconds: 299));
    expect(highlighted('symbols'), isFalse);
    expect(highlighted('plot'), isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(highlighted('plot'), isTrue);

    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('panel-tab-header'))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(highlighted('plot'), isFalse);
    expect(highlighted('header'), isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(TalPanelFrame), findsNWidgets(4));
    expect(
      find.descendant(
        of: group('header'),
        matching: find.byKey(const ValueKey('panel-tab-sampling')),
      ),
      findsOneWidget,
    );

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
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
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    Map<String, dynamic>? configuration;
    Map<String, dynamic>? assignedPanel;
    var windowWasShown = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') {
        configuration = Map<String, dynamic>.from(call.arguments as Map);
        return 'tab_window';
      }
      if (call.method == 'window_show') windowWasShown = true;
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method == 'invokeMethod') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        if (arguments['method'] == configureDetachedPanelMethod) {
          assignedPanel = Map<String, dynamic>.from(
            arguments['arguments'] as Map,
          );
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(createChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final controller = TakeALookController();
    final initialLogCount = controller.logs.length;
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
    expect(windowWasShown, isTrue);
    final launch = detachedPanelLaunchFromJson(assignedPanel);
    expect(launch!.groupPanels, [WorkspacePanelId.sampling]);
    expect(find.byType(TalPanelFrame), findsNWidgets(4));
    expect(
      find.descendant(
        of: headerGroup,
        matching: find.text(WorkspacePanelId.sampling.title),
      ),
      findsNothing,
    );
    expect(controller.logs, hasLength(initialLogCount));

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
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    Map<String, dynamic>? configuration;
    Map<String, dynamic>? assignedPanel;
    var windowWasShown = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') {
        configuration = Map<String, dynamic>.from(call.arguments as Map);
        return 'group_window';
      }
      if (call.method == 'window_show') windowWasShown = true;
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method == 'invokeMethod') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        if (arguments['method'] == configureDetachedPanelMethod) {
          assignedPanel = Map<String, dynamic>.from(
            arguments['arguments'] as Map,
          );
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(createChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final controller = TakeALookController();
    final initialLogCount = controller.logs.length;
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
      for (var attempt = 0; attempt < 50 && assignedPanel == null; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(configuration, isNotNull);
    expect(assignedPanel, isNotNull);
    expect(windowWasShown, isTrue);
    final launch = detachedPanelLaunchFromJson(assignedPanel);
    expect(launch!.groupPanels, [
      WorkspacePanelId.header,
      WorkspacePanelId.runControl,
      WorkspacePanelId.sampling,
    ]);
    expect(find.byType(TalPanelFrame), findsNWidgets(3));
    expect(controller.logs, hasLength(initialLogCount));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('workspace panels resize, merge, split, hide, and restore', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const createChannel = MethodChannel('mixin.one/desktop_multi_window');
    const windowChannel = MethodChannel(
      'mixin.one/window_controller/newly_opened_panel_window',
    );
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    Map<String, dynamic>? assignedPanel;
    var windowWasShown = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(createChannel, (call) async {
      if (call.method == 'createWindow') return 'newly_opened_panel_window';
      if (call.method == 'window_show') windowWasShown = true;
      if (call.method == 'getAllWindows') return <Map<String, dynamic>>[];
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async => null);
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method == 'invokeMethod') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        if (arguments['method'] == configureDetachedPanelMethod) {
          assignedPanel = Map<String, dynamic>.from(
            arguments['arguments'] as Map,
          );
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(createChannel, null);
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final controller = TakeALookController();
    final initialLogCount = controller.logs.length;
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

    await tester.runAsync(
      () => workspaceKey.currentState!.showPanel(WorkspacePanelId.header),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TalPanelFrame), findsNWidgets(3));
    expect(windowWasShown, isTrue);
    final launch = detachedPanelLaunchFromJson(assignedPanel);
    expect(launch, isNotNull);
    expect(launch!.groupPanels, [WorkspacePanelId.header]);
    expect(launch.initialSize, WorkspacePanelId.header.preferredWindowSize);
    expect(
      workspaceKey.currentState!.isPanelVisible(WorkspacePanelId.header),
      isTrue,
    );
    expect(controller.logs, hasLength(initialLogCount));

    windowSync.reportDetachedWindowReleased('newly_opened_panel_window');
    await tester.pumpAndSettle();
    expect(find.byType(TalPanelFrame), findsNWidgets(3));
    expect(
      workspaceKey.currentState!.isPanelVisible(WorkspacePanelId.header),
      isFalse,
    );

    workspaceKey.currentState!.resetLayout();
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    final resetHeaderGroup = find.byKey(
      const ValueKey('workspace-group-header'),
    );
    final resetHeaderSplitButton = find.descendant(
      of: resetHeaderGroup,
      matching: find.byIcon(Icons.call_split),
    );
    final resetHeaderSplitControl = find.ancestor(
      of: resetHeaderSplitButton,
      matching: find.byType(IconButton),
    );
    tester.widget<IconButton>(resetHeaderSplitControl).onPressed!();
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(5));

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
    expect(find.byType(TalPanelFrame), findsNWidgets(4));

    await tester.runAsync(workspaceKey.currentState!.restoreLayout);
    await tester.pump();
    expect(find.byType(TalPanelFrame), findsNWidgets(5));
    expect(controller.uiScale, 1.25);

    await windowSync.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
