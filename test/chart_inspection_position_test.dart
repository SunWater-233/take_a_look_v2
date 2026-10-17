import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';
import 'package:take_a_look_v2/src/chart/painter.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

import 'chart_hover_test.dart'
    show controllerWithSeries, mappingFor, pixelFor, updateSamples;

final _chart = find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is TelemetryPainter,
);
final _inspection = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint && widget.painter is TelemetryInspectionPainter,
);

TestRecordingCanvas _recordInspection(WidgetTester tester) {
  final canvas = TestRecordingCanvas();
  tester
      .widget<CustomPaint>(_inspection)
      .painter!
      .paint(canvas, tester.getSize(_chart));
  return canvas;
}

Rect _tooltip(WidgetTester tester) =>
    (_recordInspection(tester).invocations
                .firstWhere((call) => call.invocation.memberName == #drawRRect)
                .invocation
                .positionalArguments
                .first
            as RRect)
        .outerRect;

Offset _marker(WidgetTester tester) =>
    _recordInspection(tester).invocations
            .firstWhere((call) => call.invocation.memberName == #drawCircle)
            .invocation
            .positionalArguments
            .first
        as Offset;

TakeALookController _controller() => controllerWithSeries({
  for (var i = 0; i < 12; i++)
    'signal_$i': [const Offset(0, 2), const Offset(10, 3)],
});

Future<void> _pumpPanels(
  WidgetTester tester,
  TakeALookController controller, {
  bool showWatch = true,
  bool compact = true,
  double scale = 1,
  double top = 0,
  TalInputMode inputMode = TalInputMode.mouseKeyboard,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(inputMode: inputMode),
      home: Scaffold(
        body: TalUiScaleViewport(
          scale: scale,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, top, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: TelemetryChart(controller: controller),
                  ),
                ),
                if (showWatch)
                  SizedBox(
                    width: compact ? 360 : 500,
                    child: buildWorkspacePanel(
                      WorkspacePanelId.watch,
                      controller,
                      workbench: compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectAtBottomRight(WidgetTester tester) {
  final plot = telemetryPlotRect(tester.getSize(_chart));
  final box = _tooltip(tester);
  expect(box.right, closeTo(plot.right - 8, 0.01));
  expect(box.bottom, closeTo(plot.bottom - 8, 0.01));
}

void _expectAligned(WidgetTester tester, String key, {bool compact = true}) {
  final row = find.byKey(
    ValueKey(compact ? 'compact-watch-$key' : 'watch-row-$key'),
  );
  final chart = tester.renderObject<RenderBox>(_chart);
  final center = chart.globalToLocal(tester.getCenter(row)).dy;
  final plot = telemetryPlotRect(chart.size);
  final box = _tooltip(tester);
  expect(box.center.dy, closeTo(center, 0.01));
  expect(box.right, closeTo(plot.right - 8, 0.01));
}

void _testWithController(
  String description,
  Future<void> Function(WidgetTester, TakeALookController) body,
) {
  testWidgets(description, (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    try {
      await body(tester, controller);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });
}

void main() {
  _testWithController(
    'without a watch panel latest samples stay in the bottom corner',
    (tester, controller) async {
      controller.setPlotHighlightedWatch('signal_3');
      await _pumpPanels(tester, controller, showWatch: false);
      _expectAtBottomRight(tester);
      final before = _marker(tester);
      updateSamples(controller, {
        'signal_3': [const Offset(0, 2), const Offset(10, 9)],
      });
      await tester.pumpAndSettle();
      _expectAtBottomRight(tester);
      expect(_marker(tester).dy, lessThan(before.dy));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  for (final mode in TalInputMode.values) {
    _testWithController(
      '$mode aligns with the selected row through updates and resize',
      (tester, controller) async {
        await _pumpPanels(tester, controller, inputMode: mode);
        await tester.tap(find.text('signal_3').first);
        await tester.pumpAndSettle();
        _expectAligned(tester, 'signal_3');

        updateSamples(controller, {
          'signal_3': [const Offset(0, 2), const Offset(10, 9)],
        });
        await tester.pumpAndSettle();
        _expectAligned(tester, 'signal_3');

        await _pumpPanels(
          tester,
          controller,
          inputMode: mode,
          top: 70,
          scale: 1.2,
        );
        _expectAligned(tester, 'signal_3');
        controller.setPlotHighlightedWatch('signal_2', selectWatchRow: true);
        await tester.pumpAndSettle();
        _expectAligned(tester, 'signal_2');

        await _pumpPanels(
          tester,
          controller,
          inputMode: mode,
          showWatch: false,
        );
        _expectAtBottomRight(tester);
        await _pumpPanels(tester, controller, inputMode: mode);
        _expectAligned(tester, 'signal_2');
        controller.setPlotHighlightedWatch('signal_0', selectWatchRow: true);
        await tester.pumpAndSettle();
        _expectAligned(tester, 'signal_0');
        expect(tester.takeException(), isNull);
      },
    );
  }

  _testWithController(
    'scrolling moves the anchor while clipped or removed rows fall back',
    (tester, controller) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      controller.setPlotHighlightedWatch('signal_3', selectWatchRow: true);
      await _pumpPanels(tester, controller);
      _expectAligned(tester, 'signal_3');
      final before = _tooltip(tester).center.dy;
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('compact-watch-list')),
        matching: find.byType(Scrollable),
      );
      final scroll = tester.state<ScrollableState>(scrollable.first).position;
      scroll.jumpTo(70);
      await tester.pumpAndSettle();
      _expectAligned(tester, 'signal_3');
      expect(_tooltip(tester).center.dy, closeTo(before - 70, 0.01));

      // Retained sliver cache children must not count as visible watch rows.
      controller.setPlotHighlightedWatch('signal_0');
      scroll.jumpTo(170);
      await tester.pumpAndSettle();
      _expectAtBottomRight(tester);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      controller.setPlotHighlightedWatch('signal_3');
      await tester.pumpAndSettle();
      _expectAligned(tester, 'signal_3');
      controller.reorderWatch(3, 2);
      await tester.pumpAndSettle();
      _expectAligned(tester, 'signal_3');
      controller.removeWatch('signal_3');
      await tester.pumpAndSettle();
      expect(
        _recordInspection(
          tester,
        ).invocations.where((call) => call.invocation.memberName == #drawRRect),
        isEmpty,
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  _testWithController(
    'pointer inspection takes over then restores watch row alignment',
    (tester, controller) async {
      controller.setPlotHighlightedWatch('signal_3', selectWatchRow: true);
      await _pumpPanels(tester, controller);
      _expectAligned(tester, 'signal_3');
      final mapping = mappingFor(controller, tester.getSize(_chart));
      final local = pixelFor(mapping, const Offset(3, 8));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getTopLeft(_chart) + local);
      await tester.pumpAndSettle();
      expect(_tooltip(tester).left, closeTo(local.dx + 14, 0.01));
      expect(_tooltip(tester).top, closeTo(local.dy + 14, 0.01));
      await mouse.moveTo(tester.getCenter(find.text('signal_3').first));
      await tester.pumpAndSettle();
      _expectAligned(tester, 'signal_3');
      await mouse.removePointer();
    },
  );

  _testWithController(
    'full watch table supplies the selected row position too',
    (tester, controller) async {
      controller.setPlotHighlightedWatch('signal_3', selectWatchRow: true);
      await _pumpPanels(tester, controller, compact: false);
      _expectAligned(tester, 'signal_3', compact: false);
    },
  );
}
