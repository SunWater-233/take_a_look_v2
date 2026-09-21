import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';

void main() {
  testWidgets(
    'source debugger highlights C code and toggles gutter breakpoints',
    (tester) async {
      final sourcePath =
          '${Directory.current.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}fixtures${Platform.pathSeparator}debug_source.c';
      final controller = TakeALookController();
      controller.applyDebugState({
        'executionState': 'halted',
        'sourceFiles': [sourcePath],
        'breakpoints': <Object?>[],
        'registers': {'pc': 0x08000100, 'sp': 0x20001000},
        'stoppedLocation': {
          'path': sourcePath,
          'line': 4,
          'address': 0x08000100,
        },
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: buildWorkspacePanel(
                WorkspacePanelId.sourceDebug,
                controller,
              ),
            ),
          ),
        ),
      );
      final sourceView = find.byKey(ValueKey('source-view-$sourcePath'));
      for (
        var attempt = 0;
        attempt < 10 && sourceView.evaluate().isEmpty;
        attempt += 1
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('已暂停'), findsOneWidget);
      expect(sourceView, findsOneWidget);
      final highlighted = tester
          .widgetList<Text>(find.byType(Text))
          .where(
            (widget) =>
                widget.textSpan?.toPlainText().contains('const char') ?? false,
          );
      expect(highlighted, isNotEmpty);
      final colors = <Color?>[];
      void collect(InlineSpan span) {
        if (span is TextSpan) {
          colors.add(span.style?.color);
          for (final child in span.children ?? const <InlineSpan>[]) {
            collect(child);
          }
        }
      }

      collect(highlighted.first.textSpan!);
      expect(colors.toSet().length, greaterThan(2));

      await tester.tap(find.byKey(const ValueKey('breakpoint-5')));
      await tester.pump();
      expect(controller.debugState.requestedBreakpoints[sourcePath], {5});

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
