import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

void main() {
  testWidgets('GDB sampling mode hides executable and disables writes', (
    tester,
  ) async {
    final controller = TakeALookController();
    controller.setConnectionKind('gdb');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.connection, controller),
        ),
      ),
    );
    expect(find.text('GDB 程序'), findsOneWidget);
    controller.setRemoteConfig({'gdbMode': 'memory'});
    await tester.pump();
    expect(find.text('高速内存采样（只读）'), findsOneWidget);
    expect(find.text('GDB 程序'), findsNothing);
    expect(controller.supportsMemoryWrite, isFalse);
    expect(controller.supportsTargetControl, isFalse);
    final detached = TakeALookController();
    detached.applySnapshot(controller.snapshot(includeSamples: false));
    expect(detached.isGdbMemoryMode, isTrue);
    controller.setRemoteConfig({'gdbMode': 'debug'});
    await tester.pump();
    expect(find.text('GDB 程序'), findsOneWidget);
    expect(controller.supportsMemoryWrite, isTrue);
    await tester.pumpWidget(const SizedBox());
    detached.dispose();
    controller.dispose();
  });
}
