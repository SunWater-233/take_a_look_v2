import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tal_drag_preview/tal_drag_preview.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/native_panel_drag.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/window_sync.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';

const _codec = StandardMethodCodec();
const _source = NativePanelPayload(
  windowId: 'main',
  fromMainWindow: true,
  groupId: 'header',
  panel: WorkspacePanelId.sampling,
);

Future<bool> event(
  WidgetTester tester,
  String phase,
  Offset position, {
  NativePanelPayload source = _source,
}) {
  final result = Completer<bool>();
  tester.binding.channelBuffers.push(
    'take_a_look/drag_preview_window',
    _codec.encodeMethodCall(
      MethodCall('nativeTabDrag', {
        'phase': phase,
        'payload': source.toJson(),
        'x': position.dx,
        'y': position.dy,
      }),
    ),
    (data) {
      try {
        result.complete(_codec.decodeEnvelope(data!) == true);
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    },
  );
  return result.future;
}

void main() {
  setUp(() => TalDragPreview.nativeWayland = true);
  tearDown(() {
    TalDragPreview.setNativeDragHandler(null);
    TalDragPreview.nativeWayland = false;
  });

  testWidgets('native tear-off requires the explicit drop target', (
    tester,
  ) async {
    NativePanelTransfer? received;
    await tester.pumpWidget(
      MaterialApp(
        home: NativePanelDragHost(
          windowId: 'main',
          isMainWindow: true,
          onTransfer: (value) async {
            received = value;
            return true;
          },
          child: const NativePanelDropRegion(child: SizedBox.expand()),
        ),
      ),
    );
    await event(tester, 'motion', const Offset(300, 300));
    await tester.pump();
    final target = find.byKey(const ValueKey('native-panel-detach-target'));
    expect(target, findsOneWidget);
    expect(await event(tester, 'drop', tester.getCenter(target)), isTrue);
    expect(received!.targetWindowId, 'new');
    expect(received!.source.panel, WorkspacePanelId.sampling);
    await tester.pump();
    expect(target, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final outcome in ['cancelled', 'outside']) {
    testWidgets('native $outcome preserves the distinct end result', (
      tester,
    ) async {
      bool? accepted;
      const channel = MethodChannel('take_a_look/drag_preview_window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'beginTabDrag');
        final arguments = call.arguments as Map;
        final payload = NativePanelPayload.parse(arguments['payload']);
        expect(payload!.panel, WorkspacePanelId.sampling);
        return outcome;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: NativePanelDragHost(
            windowId: 'main',
            isMainWindow: true,
            onTransfer: (_) async => true,
            child: Center(
              child: NativePanelDragSource(
                data: const PanelTabDragData(
                  sourceGroupId: 'header',
                  panel: WorkspacePanelId.sampling,
                ),
                tabKey: GlobalKey(),
                onStart: () {},
                onEnd: (value) => accepted = value,
                child: const SizedBox(width: 200, height: 80),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(NativePanelDragSource)),
      );
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await tester.pump();
      expect(accepted, outcome == 'cancelled');
      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
  }

  testWidgets(
    'native drops use transformed hit regions and preserve source metadata',
    (tester) async {
      NativePanelTransfer? received;
      final targetKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: NativePanelDragHost(
            windowId: 'detached',
            isMainWindow: false,
            onTransfer: (transfer) async {
              received = transfer;
              return true;
            },
            child: Builder(
              builder: (context) => Center(
                child: Transform.scale(
                  scale: 1.45,
                  child: NativePanelDropRegion(
                    onDrop: (payload, _) =>
                        nativePanelDragHostOf(context)!.transfer(
                          payload,
                          groupId: 'detached-window',
                          insertionIndex: 1,
                        ),
                    child: SizedBox(key: targetKey, width: 200, height: 100),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final position = tester.getCenter(find.byKey(targetKey));
      expect(await event(tester, 'motion', position), isTrue);
      expect(await event(tester, 'drop', position), isTrue);
      expect(received!.source.panel, WorkspacePanelId.sampling);
      expect(received!.source.windowId, 'main');
      expect(received!.targetWindowId, 'detached');
      expect(received!.targetIsMainWindow, isFalse);
      expect(received!.insertionIndex, 1);
      expect(await event(tester, 'drop', const Offset(2, 2)), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'GTK leave before drop retains dwell, real leave clears feedback',
    (tester) async {
      var moves = 0;
      var leaves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NativePanelDragHost(
            windowId: 'main',
            isMainWindow: true,
            onTransfer: (_) async => true,
            child: NativePanelDropRegion(
              onMove: (_, _) => moves++,
              onLeave: () => leaves++,
              onDrop: (_, _) async => true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      expect(await event(tester, 'motion', const Offset(100, 100)), isTrue);
      await event(tester, 'leave', Offset.zero);
      expect(leaves, 0);
      expect(await event(tester, 'drop', const Offset(100, 100)), isTrue);
      expect(leaves, 1);
      await tester.pump(const Duration(milliseconds: 60));
      expect(leaves, 1);
      await event(tester, 'motion', const Offset(100, 100));
      await event(tester, 'leave', Offset.zero);
      await tester.pump(const Duration(milliseconds: 60));
      expect(leaves, 2);
      expect(moves, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native tab drops reorder the real workspace without native window calls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TakeALookController();
      final sync = MainWindowSync(controller);
      final workspace = GlobalKey<DockingWorkspaceState>();
      final transfers = <NativePanelTransfer>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: NativePanelDragHost(
              windowId: 'main',
              isMainWindow: true,
              onTransfer: (transfer) {
                transfers.add(transfer);
                return sync.transferPanel(transfer);
              },
              child: DockingWorkspace(
                key: workspace,
                controller: controller,
                windowSync: sync,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final group = find.byKey(const ValueKey('workspace-group-header'));
      Finder tab(WorkspacePanelId id) => find.descendant(
        of: group,
        matching: find.byKey(ValueKey('panel-tab-${id.name}')),
      );
      final headerX = tester.getCenter(tab(WorkspacePanelId.header)).dx;
      final samplingX = tester.getCenter(tab(WorkspacePanelId.sampling)).dx;
      expect(headerX, lessThan(samplingX));
      final headerRect = tester.getRect(tab(WorkspacePanelId.header));
      final destination = Offset(
        headerRect.left + headerRect.width / 4,
        headerRect.center.dy,
      );
      expect(await event(tester, 'motion', destination), isTrue);
      expect(await event(tester, 'drop', destination), isTrue);
      expect(transfers, hasLength(1));
      expect(transfers.single.targetGroupId, 'header');
      expect(transfers.single.insertionIndex, 0);
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(tab(WorkspacePanelId.sampling)).dx,
        lessThan(tester.getCenter(tab(WorkspacePanelId.header)).dx),
      );
      expect(find.byType(TalPanelFrame), findsNWidgets(4));
      expect(
        await sync.transferPanel(
          const NativePanelTransfer(
            source: NativePanelPayload(
              windowId: 'missing',
              fromMainWindow: false,
              groupId: 'detached-window',
              panel: WorkspacePanelId.plot,
            ),
            targetWindowId: 'main',
            targetIsMainWindow: true,
            targetGroupId: 'header',
          ),
        ),
        isFalse,
      );
      expect(find.byType(TalPanelFrame), findsNWidgets(4));
      await tester.pumpWidget(const SizedBox.shrink());
      await sync.dispose();
      controller.dispose();
    },
  );

  testWidgets(
    'native single-panel detached windows expose a drag source and whole-window drop target',
    (tester) async {
      final controller = TakeALookController();
      NativePanelTransfer? transfer;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: NativePanelDragHost(
            windowId: 'target',
            isMainWindow: false,
            onTransfer: (value) async {
              transfer = value;
              return true;
            },
            child: DetachedPanelWindow(
              controller: controller,
              panel: WorkspacePanelId.sampling,
            ),
          ),
        ),
      );
      expect(find.byType(NativePanelDragSource), findsOneWidget);
      final body = tester.getCenter(find.byType(TalPanelFrame));
      expect(await event(tester, 'drop', body), isTrue);
      expect(transfer!.targetWindowId, 'target');
      expect(transfer!.targetGroupId, 'detached-window');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
