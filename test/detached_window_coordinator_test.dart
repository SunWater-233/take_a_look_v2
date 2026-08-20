import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/detached_window_coordinator.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/tab_drag_preview_coordinator.dart';
import 'package:take_a_look_v2/src/window_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('released detached windows are reconfigured and reused', () async {
    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var createCount = 0;
    final configurations = <DetachedPanelLaunch>[];
    final invokedMethods = <String>[];
    String? launchArguments;

    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') {
        createCount += 1;
        final configuration = Map<String, dynamic>.from(call.arguments as Map);
        launchArguments = configuration['arguments'] as String;
        return 'pooled_window';
      }
      if (call.method == 'getAllWindows') {
        return <Map<String, dynamic>>[
          {
            'windowId': 'pooled_window',
            'windowArgument': launchArguments ?? '',
          },
        ];
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method == 'invokeMethod') {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        invokedMethods.add(arguments['method'] as String);
        final configuration = detachedPanelLaunchFromJson(
          arguments['arguments'],
        );
        if (configuration != null) configurations.add(configuration);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final controller = TakeALookController();
    final windowSync = MainWindowSync(controller);
    final coordinator = DetachedWindowCoordinator(windowSync);
    addTearDown(() async {
      await coordinator.dispose();
      await windowSync.dispose();
      controller.dispose();
    });

    await coordinator.prewarm();
    final firstWindow = await coordinator.acquire(
      activePanel: WorkspacePanelId.sampling,
      panels: const <WorkspacePanelId>[WorkspacePanelId.sampling],
      initialSize: const Size(520, 330),
    );
    expect(createCount, 1);
    expect(firstWindow.windowId, 'pooled_window');
    expect(configurations.single.panel, WorkspacePanelId.sampling);
    expect(invokedMethods, contains(configureDetachedPanelMethod));

    windowSync.reportDetachedWindowReleased('pooled_window');
    expect(await coordinator.reconcile(), [WorkspacePanelId.sampling]);

    final reusedWindow = await coordinator.acquire(
      activePanel: WorkspacePanelId.plot,
      panels: const <WorkspacePanelId>[WorkspacePanelId.plot],
      initialSize: const Size(1050, 700),
    );
    expect(createCount, 1);
    expect(reusedWindow.windowId, firstWindow.windowId);
    expect(configurations.last.panel, WorkspacePanelId.plot);
    expect(coordinator.windows[WorkspacePanelId.plot], reusedWindow);
  });

  test('drag preview owns a dedicated reusable window', () async {
    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var createCount = 0;
    String? launchArguments;
    DetachedPanelLaunch? previewConfiguration;
    final invokedMethods = <String>[];

    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') {
        createCount += 1;
        final configuration = Map<String, dynamic>.from(call.arguments as Map);
        launchArguments = configuration['arguments'] as String;
        return 'drag_preview_window';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method != 'invokeMethod') return null;
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final method = arguments['method'] as String;
      invokedMethods.add(method);
      if (method == prepareTabDragPreviewMethod) {
        previewConfiguration = detachedPanelLaunchFromJson(
          arguments['arguments'],
        );
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final coordinator = TabDragPreviewCoordinator();
    addTearDown(coordinator.dispose);
    await coordinator.prewarm();
    await coordinator.prepare(
      panel: WorkspacePanelId.symbols,
      size: const Size(540, 700),
    );
    await coordinator.showAt(const Offset(120, 80));
    await coordinator.hide();

    final initialLaunch = detachedPanelLaunchFromEntrypointArguments([
      'multi_window',
      'drag_preview_window',
      launchArguments!,
    ]);
    expect(createCount, 1);
    expect(initialLaunch!.role, SecondaryWindowRole.dragPreview);
    expect(previewConfiguration!.role, SecondaryWindowRole.dragPreview);
    expect(previewConfiguration!.panel, WorkspacePanelId.symbols);
    expect(previewConfiguration!.initialSize, const Size(540, 700));
    expect(invokedMethods, contains(prepareTabDragPreviewMethod));
    expect(invokedMethods, contains(showTabDragPreviewMethod));
    expect(invokedMethods, contains(hideTabDragPreviewMethod));
  });

  test('drag preview hide bypasses an in-flight pointer move', () async {
    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final moveEntered = Completer<void>();
    final releaseMove = Completer<void>();
    final calls = <String>[];
    int? showSession;
    int? hideSession;
    var nativeHideCount = 0;

    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') return 'racing_preview_window';
      if (call.method == 'window_hide') nativeHideCount += 1;
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method != 'invokeMethod') return null;
      final envelope = Map<String, dynamic>.from(call.arguments as Map);
      final method = envelope['method'] as String;
      final arguments = envelope['arguments'];
      if (method == showTabDragPreviewMethod) {
        calls.add('show');
        showSession = (arguments as Map)[tabDragPreviewSessionKey] as int;
        if (!moveEntered.isCompleted) moveEntered.complete();
        await releaseMove.future;
      } else if (method == hideTabDragPreviewMethod) {
        calls.add('hide');
        hideSession = (arguments as Map)[tabDragPreviewSessionKey] as int;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final coordinator = TabDragPreviewCoordinator();
    addTearDown(coordinator.dispose);
    await coordinator.prewarm();
    await coordinator.prepare(
      panel: WorkspacePanelId.connection,
      size: const Size(440, 560),
    );
    final move = coordinator.showAt(const Offset(320, 180));
    await moveEntered.future;
    final hide = coordinator.hide();
    await Future<void>.delayed(Duration.zero);

    expect(calls, ['show', 'hide']);
    expect(hideSession, showSession);
    expect(nativeHideCount, greaterThanOrEqualTo(1));

    releaseMove.complete();
    await move;
    await hide;
  });

  test('an old delayed hide cannot hide the next drag preview', () async {
    const desktopChannel = MethodChannel('mixin.one/desktop_multi_window');
    const channelsChannel = MethodChannel(
      'mixin.one/desktop_multi_window/channels',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final firstHideEntered = Completer<void>();
    final releaseFirstHide = Completer<void>();
    var hideMessageCount = 0;
    var nativeHideCount = 0;

    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'createWindow') return 'next_preview_window';
      if (call.method == 'window_hide') nativeHideCount += 1;
      return null;
    });
    messenger.setMockMethodCallHandler(channelsChannel, (call) async {
      if (call.method != 'invokeMethod') return null;
      final envelope = Map<String, dynamic>.from(call.arguments as Map);
      if (envelope['method'] == hideTabDragPreviewMethod) {
        hideMessageCount += 1;
        if (hideMessageCount == 1) {
          firstHideEntered.complete();
          await releaseFirstHide.future;
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(desktopChannel, null);
      messenger.setMockMethodCallHandler(channelsChannel, null);
    });

    final coordinator = TabDragPreviewCoordinator();
    addTearDown(coordinator.dispose);
    await coordinator.prewarm();
    await coordinator.prepare(
      panel: WorkspacePanelId.connection,
      size: const Size(440, 560),
    );
    await coordinator.showAt(const Offset(100, 100));
    await coordinator.hide();
    await firstHideEntered.future;

    await coordinator.prepare(
      panel: WorkspacePanelId.watch,
      size: const Size(520, 620),
    );
    await coordinator.showAt(const Offset(640, 180));
    final hidesBeforeOldReply = nativeHideCount;
    releaseFirstHide.complete();
    await Future<void>.delayed(Duration.zero);

    expect(nativeHideCount, hidesBeforeOldReply);
  });
}
