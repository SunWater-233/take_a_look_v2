import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

Future<Color> rowBackground(WidgetTester tester, String rowKey) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('watch-preview')),
  );
  final row = tester.getRect(find.byKey(ValueKey(rowKey)));
  // Sample the empty indentation, away from text, icons and the selection border.
  final point = boundary.globalToLocal(Offset(row.left + 6, row.center.dy));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return Color.fromARGB(
        bytes!.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  for (final prefix in ['pinned', 'capture', 'compact']) {
    for (final submit in [false, true]) {
      testWidgets(
        '$prefix deselection restores normal background after ${submit ? 'submitting' : 'blurring'} its editor',
        (tester) async {
          final writes = <Object?>[];
          final controller = TakeALookController(
            backendCommand: (command, args) async {
              if (command == ControllerCommand.writeWatch) writes.add(args);
            },
          );
          try {
            controller.applySnapshot({
              'connectionStatus': 'connected',
              'symbols': [
                for (final (index, definition) in [
                  ('zero_force', 'uint8_t'),
                  ('speed_pid', 'PID_t'),
                  ('speed_pid.kp', 'float'),
                ].indexed)
                  {
                    'key': definition.$1,
                    'name': definition.$1,
                    'source': 'motor.c',
                    'type': definition.$2,
                    'address': 0x20000000 + index * 4,
                    'size': 4,
                  },
              ],
            });
            controller.selectSymbols(['zero_force', 'speed_pid']);
            controller.addSelectedToWatch(mode: WatchReadMode.monitor);
            controller.setWatchPinned('zero_force', true);
            controller.setWatchReadMode('zero_force', WatchReadMode.capture);
            controller.applyWatchValues({
              'values': [
                {'key': 'zero_force', 'value': 1, 'updatedAtMs': 1},
              ],
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildTalTheme(),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 430,
                      height: 600,
                      child: RepaintBoundary(
                        key: const ValueKey('watch-preview'),
                        child: buildWorkspacePanelBody(
                          WorkspacePanelId.watch,
                          controller,
                          workbench: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final value = find.byKey(
              ValueKey('$prefix-watch-value-zero_force'),
            );
            await tester.tap(value, kind: PointerDeviceKind.mouse);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tap(value, kind: PointerDeviceKind.mouse);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.pump();
            final input = find.byKey(
              ValueKey('$prefix-watch-input-zero_force'),
            );
            expect(input, findsOneWidget);
            await tester.enterText(input, '0');
            // Text entry alone does not send hardware events in widget tests.
            // Exercise the keyboard focus highlight that appears in the desktop app.
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pumpAndSettle();
            final nextRow = find.byKey(
              const ValueKey('compact-watch-speed_pid'),
            );
            // Move off the old row before clicking, so its hover animation has
            // finished and cannot conceal a leftover focus highlight.
            await tester.sendEventToBinding(
              PointerHoverEvent(
                position: tester.getCenter(nextRow),
                kind: PointerDeviceKind.mouse,
                device: 1,
              ),
            );
            await tester.pumpAndSettle();
            if (submit) {
              await tester.testTextInput.receiveAction(TextInputAction.done);
              await tester.pump();
              expect(input, findsNothing);
              expect(controller.compactWatchSelection, 'zero_force');
              expect(Focus.of(tester.element(value)).hasFocus, isFalse);
            }
            await tester.tap(nextRow, kind: PointerDeviceKind.mouse);
            await tester.pump();
            expect(controller.compactWatchSelection, 'speed_pid');
            expect(input, findsNothing);
            expect(Focus.of(tester.element(value)).hasFocus, isFalse);
            expect(
              writes,
              submit
                  ? [
                      {'key': 'zero_force', 'value': '0'},
                    ]
                  : isEmpty,
            );
            expect(
              controller.watchInputDrafts['zero_force'],
              submit ? isNull : '0',
            );

            // The old row must be normal in the first deselected frame, even
            // when editing already finished before the selection changed.
            expect(
              await rowBackground(tester, '$prefix-watch-zero_force'),
              TalColors.surface,
            );
            expect(
              await rowBackground(tester, 'compact-watch-speed_pid'),
              TalColors.selection,
            );
            await tester.sendEventToBinding(
              const PointerHoverEvent(
                position: Offset(700, 550),
                kind: PointerDeviceKind.mouse,
                device: 1,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              await rowBackground(tester, '$prefix-watch-zero_force'),
              TalColors.surface,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
          }
        },
      );
    }
  }
}
