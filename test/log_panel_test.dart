import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

Widget _logPanel(
  TakeALookController controller, {
  double width = 600,
  double height = 260,
}) => MaterialApp(
  theme: buildTalTheme(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: buildWorkspacePanel(WorkspacePanelId.log, controller),
      ),
    ),
  ),
);

TakeALookController _controller(WidgetTester tester, {int lines = 60}) {
  final controller = TakeALookController(backendCommand: (_, _) async {});
  for (var i = 0; i < lines; i++) {
    controller.addLog('Log line $i');
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return controller;
}

final _logScroll = find.byKey(const ValueKey('log-scroll'));

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _logScroll, matching: find.byType(Scrollable)),
    )
    .position;

Future<void> _wheel(WidgetTester tester, double delta) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(_logScroll),
      scrollDelta: Offset(0, delta),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('logs start at the latest entry and follow batches of new data', (
    tester,
  ) async {
    final controller = _controller(tester);
    await tester.pumpWidget(_logPanel(controller));
    await tester.pumpAndSettle();
    expect(_position(tester).maxScrollExtent, greaterThan(0));
    expect(_position(tester).extentAfter, closeTo(0, 1));

    for (var i = 0; i < 30; i++) {
      controller.addLog('Batch entry $i');
    }
    await tester.pumpAndSettle();
    expect(_position(tester).extentAfter, closeTo(0, 1));
    expect(find.textContaining('Batch entry 29').hitTestable(), findsOneWidget);
  });

  for (final touch in [false, true]) {
    testWidgets(
      '${touch ? 'touch' : 'mouse wheel'} pauses following until scrolled to bottom',
      (tester) async {
        final controller = _controller(tester);
        await tester.pumpWidget(_logPanel(controller));
        await tester.pumpAndSettle();

        if (touch) {
          await tester.drag(_logScroll, const Offset(0, 140));
          await tester.pumpAndSettle();
        } else {
          await _wheel(tester, -140);
        }
        final pausedOffset = _position(tester).pixels;
        expect(_position(tester).extentAfter, greaterThan(100));

        controller.addLog('New data while reading history');
        await tester.pumpAndSettle();
        expect(_position(tester).pixels, closeTo(pausedOffset, 1));

        // Returning partway toward the latest entry must still leave it paused.
        if (touch) {
          await tester.drag(_logScroll, const Offset(0, -50));
          await tester.pumpAndSettle();
        } else {
          await _wheel(tester, 50);
        }
        final partialOffset = _position(tester).pixels;
        controller.addLog('Still reading history');
        await tester.pumpAndSettle();
        expect(_position(tester).pixels, closeTo(partialOffset, 1));
        expect(_position(tester).extentAfter, greaterThan(0));

        if (touch) {
          await tester.drag(_logScroll, const Offset(0, -400));
          await tester.pumpAndSettle();
        } else {
          await _wheel(tester, 10000);
        }
        expect(_position(tester).extentAfter, closeTo(0, 1));
        controller.addLog('Following again');
        await tester.pumpAndSettle();
        expect(_position(tester).extentAfter, closeTo(0, 1));
        expect(
          find.textContaining('Following again').hitTestable(),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('resizing and wrapping preserve following or paused history', (
    tester,
  ) async {
    final controller = _controller(tester);
    controller.addLog(List.filled(15, 'Wrapping log message').join(' '));
    await tester.pumpWidget(_logPanel(controller));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_logPanel(controller, width: 380, height: 190));
    await tester.pumpAndSettle();
    expect(_position(tester).extentAfter, closeTo(0, 1));

    await _wheel(tester, -250);
    final pausedOffset = _position(tester).pixels;
    await tester.pumpWidget(_logPanel(controller, width: 360, height: 160));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(pausedOffset, 1));
    controller.addLog('After resizing while paused');
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(pausedOffset, 1));
  });

  testWidgets('following continues when the retained log buffer is full', (
    tester,
  ) async {
    final controller = _controller(tester, lines: 500);
    await tester.pumpWidget(_logPanel(controller));
    await tester.pumpAndSettle();

    controller.addLog(List.filled(20, 'New multiline log').join('\n'));
    await tester.pumpAndSettle();
    expect(controller.logs, hasLength(500));
    expect(_position(tester).extentAfter, closeTo(0, 1));

    await _wheel(tester, -200);
    final pausedOffset = _position(tester).pixels;
    controller.addLog('Retained log while paused');
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(pausedOffset, 1));
  });

  testWidgets('clearing paused logs restores following for new data', (
    tester,
  ) async {
    final controller = _controller(tester);
    await tester.pumpWidget(_logPanel(controller));
    await tester.pumpAndSettle();
    await _wheel(tester, -140);

    await tester.tap(find.byTooltip('清空日志'));
    await tester.pumpAndSettle();
    expect(controller.logs, isEmpty);
    for (var i = 0; i < 40; i++) {
      controller.addLog('After clearing $i');
    }
    await tester.pumpAndSettle();
    expect(_position(tester).extentAfter, closeTo(0, 1));
    expect(
      find.textContaining('After clearing 39').hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('log text supports selection, copy, and a context menu', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final controller = TakeALookController()..addLog('copyable log message');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: buildWorkspacePanel(WorkspacePanelId.log, controller),
          ),
        ),
      ),
    );
    await tester.pump();

    final selectionArea = tester.widget<SelectionArea>(
      find.byKey(const ValueKey('log-selection-area')),
    );
    expect(selectionArea.contextMenuBuilder, isNotNull);

    final selectableRegion = tester
        .state<SelectionAreaState>(
          find.byKey(const ValueKey('log-selection-area')),
        )
        .selectableRegion;
    selectableRegion.contextMenuButtonItems
        .singleWhere((item) => item.type == ContextMenuButtonType.selectAll)
        .onPressed!();
    await tester.pump();
    final contextMenu = selectionArea.contextMenuBuilder!(
      tester.element(find.byKey(const ValueKey('log-selection-area'))),
      selectableRegion,
    );
    expect(contextMenu, isA<TalSelectionContextMenu>());
    expect((contextMenu as TalSelectionContextMenu).touchOptimized, isFalse);
    selectableRegion.contextMenuButtonItems
        .singleWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();

    expect(copiedText, contains('copyable log message'));

    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
