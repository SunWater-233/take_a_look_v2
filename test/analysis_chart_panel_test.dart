import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  testWidgets(
    'analysis panel imports realtime samples and reports selection statistics',
    (tester) async {
      final controller = TakeALookController()..loadDemoSymbols();
      controller.selectSymbols([demoSymbols.first.key]);
      controller.addSelectedToWatch();
      final key = controller.watches.single.symbol.key;
      controller.applyTelemetrySnapshot({
        'elapsedSeconds': 4,
        'watches': [
          {
            'key': key,
            'value': 4,
            'samples': [
              [0, 0],
              [1, 1],
              [2, 2],
              [3, 3],
              [4, 4],
            ],
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 700,
              child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
            ),
          ),
        ),
      );

      expect(find.text('导入数据'), findsNWidgets(2));
      await tester.tap(find.text('导入数据').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前实时数据'));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前实时数据'), findsOneWidget);
      final chart = find.byType(CustomPaint).last;
      final chartRect = tester.getRect(chart);
      final drag = await tester.startGesture(
        chartRect.centerLeft + const Offset(70, 0),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await drag.moveTo(chartRect.centerRight - const Offset(70, 0));
      await drag.up();
      await tester.pump();

      expect(find.text('样本数'), findsOneWidget);
      expect(find.text('平均值'), findsOneWidget);
      expect(find.text('峰峰值'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets('analysis panel parses a local CSV through the injected picker', (
    tester,
  ) async {
    final controller = TakeALookController(
      csvImportContentsPicker: () async => 'time,signal\n0,1\n1,3\n2,2\n',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本地 CSV'), findsOneWidget);
    controller.dispose();
  });
}
