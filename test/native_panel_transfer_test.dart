import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/detached_window_coordinator.dart';
import 'package:take_a_look_v2/src/workspace/panel_transfer.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const desktop = MethodChannel('mixin.one/desktop_multi_window');
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'Wayland transfers and reorders retain window sizes without global positions',
    () async {
      final configurations = <String, DetachedPanelLaunch>{};
      var created = 0;
      messenger.setMockMethodCallHandler(desktop, (call) async {
        if (call.method == 'createWindow') return 'window_${++created}';
        return null;
      });
      messenger.setMockMethodCallHandler(channels, (call) async {
        if (call.method != 'invokeMethod') return null;
        final data = call.arguments as Map;
        final id = (data['channel'] as String).split('/').last;
        if (data['method'] == configureDetachedPanelMethod) {
          configurations[id] = detachedPanelLaunchFromJson(data['arguments'])!;
        }
        if (data['method'] == getDetachedWindowBoundsMethod) {
          // Native Wayland provides a size, with no invented desktop origin.
          return <String, double>{'width': 777, 'height': 555};
        }
        return null;
      });
      final controller = TakeALookController();
      final sync = MainWindowSync(controller);
      final coordinator = DetachedWindowCoordinator(sync);
      final source = await coordinator.acquire(
        activePanel: WorkspacePanelId.sampling,
        panels: [WorkspacePanelId.header, WorkspacePanelId.sampling],
        initialSize: const Size(640, 480),
      );
      final target = await coordinator.acquire(
        activePanel: WorkspacePanelId.plot,
        panels: [WorkspacePanelId.plot],
        initialSize: const Size(900, 600),
      );
      final payload = NativePanelPayload(
        windowId: source.windowId,
        fromMainWindow: false,
        groupId: 'detached-window',
        panel: WorkspacePanelId.sampling,
      );
      expect(
        await coordinator.acceptNativeTransfer(
          NativePanelTransfer(
            source: payload,
            targetWindowId: target.windowId,
            targetIsMainWindow: false,
            insertionIndex: 0,
          ),
        ),
        isTrue,
      );
      expect(configurations[target.windowId]!.groupPanels, [
        WorkspacePanelId.sampling,
        WorkspacePanelId.plot,
      ]);
      expect(
        configurations[target.windowId]!.initialSize,
        const Size(777, 555),
      );
      expect(configurations[source.windowId]!.groupPanels, [
        WorkspacePanelId.header,
      ]);
      expect(
        configurations[source.windowId]!.initialSize,
        const Size(777, 555),
      );
      expect(
        coordinator.windows[WorkspacePanelId.sampling]!.windowId,
        target.windowId,
      );

      expect(
        await coordinator.acceptNativeTransfer(
          NativePanelTransfer(
            source: NativePanelPayload(
              windowId: target.windowId,
              fromMainWindow: false,
              groupId: 'detached-window',
              panel: WorkspacePanelId.sampling,
            ),
            targetWindowId: target.windowId,
            targetIsMainWindow: false,
            insertionIndex: 2,
          ),
        ),
        isTrue,
      );
      expect(configurations[target.windowId]!.groupPanels, [
        WorkspacePanelId.plot,
        WorkspacePanelId.sampling,
      ]);
      expect(
        await coordinator.acceptNativeTransfer(
          NativePanelTransfer(
            source: payload,
            targetWindowId: 'closed',
            targetIsMainWindow: false,
          ),
        ),
        isFalse,
      );
      expect(
        coordinator.windows[WorkspacePanelId.sampling]!.windowId,
        target.windowId,
      );

      await coordinator.dispose();
      await sync.dispose();
      controller.dispose();
      messenger.setMockMethodCallHandler(desktop, null);
      messenger.setMockMethodCallHandler(channels, null);
    },
  );
}
