import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
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
