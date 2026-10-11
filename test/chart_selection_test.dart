import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';
import 'package:take_a_look_v2/src/chart/hover.dart';
import 'package:take_a_look_v2/src/chart/painter.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

import 'chart_hover_test.dart'
    show
        controllerWithSeries,
        curvePaints,
        mappingFor,
        pixelFor,
        recordPainter,
        updateSamples;

TakeALookController selectionController() => controllerWithSeries({
  'selected': [const Offset(0, 2), const Offset(5, 4), const Offset(10, 6)],
  'other': [const Offset(0, 8), const Offset(10, 8)],
});

void main() {
  test(
    'locked inspection follows time on one curve, including inverted axes',
    () {
      final controller = selectionController();
      addTearDown(controller.dispose);
      for (final inverted in [false, true]) {
        controller.configurePlotView({
          'plotInvertX': inverted,
          'plotInvertY': inverted,
        });
        final mapping = mappingFor(controller);
        final series = telemetryPlotSeries(controller, mapping);
        final inspection = inspectTelemetrySeries(
          series,
          mapping,
          highlightedWatchKey: 'selected',
          position: pixelFor(mapping, const Offset(5, 8)),
        )!;
        expect(inspection.series.watch.symbol.key, 'selected');
        expect(inspection.sample, const Offset(5, 4));
        expect(inspection.valueText, 't = 5 s\n采样值 = 4');
        expect(
          inspectTelemetrySeries(
            series,
            mapping,
            highlightedWatchKey: 'selected',
          )!.sample,
          const Offset(10, 6),
        );
      }
    },
  );

  test(
    'highlight survives reorder and visibility changes, and clears on removal',
    () {
      final controller = selectionController();
      addTearDown(controller.dispose);
      controller.setPlotHighlightedWatch('selected');
      controller.reorderWatch(0, 1);
      controller.toggleWatchPlot('selected', false);
      final mapping = mappingFor(controller);
      expect(controller.plotHighlightedWatchKey, 'selected');
      expect(
        inspectTelemetrySeries(
          telemetryPlotSeries(controller, mapping),
          mapping,
          highlightedWatchKey: controller.plotHighlightedWatchKey,
          position: pixelFor(mapping, const Offset(5, 8)),
        ),
        isNull,
      );
      controller.toggleWatchPlot('selected', true);
      expect(controller.plotHighlightedWatchKey, 'selected');
      controller.removeWatch('selected');
      expect(controller.plotHighlightedWatchKey, isNull);
      controller.setPlotHighlightedWatch('other');
      controller.clearWatches();
      expect(controller.plotHighlightedWatchKey, isNull);
    },
  );

  test('highlight-only snapshots preserve the manual viewport', () {
    final controller = selectionController();
    addTearDown(controller.dispose);
    controller.setPlotViewport(xMin: 1, xMax: 5, yMin: 0, yMax: 10);
    var repaints = 0;
    controller.plotChanges.addListener(() => repaints++);
    controller.applySnapshot({'plotHighlightedWatchKey': 'selected'});
    expect(controller.plotHighlightedWatchKey, 'selected');
    expect(controller.plotWindowEndSeconds, 5);
    expect(controller.plotVisibleWindowSeconds, 4);
    expect(repaints, 1);
    controller.applySnapshot({'plotHighlightedWatchKey': null});
    expect(controller.plotHighlightedWatchKey, isNull);
    expect(controller.plotWindowEndSeconds, 5);
    controller.applySnapshot({'plotHighlightedWatchKey': 'missing'});
    expect(controller.plotHighlightedWatchKey, isNull);
  });

  test(
    'detached selection and clearing synchronize through plot configuration',
    () async {
      final main = selectionController();
      final commands = <ControllerCommand>[];
      late final TakeALookController detached;
      detached = TakeALookController(
        remoteCommand: (command, arguments) async {
          commands.add(command);
          detached.applySnapshot(await main.handleCommand(command, arguments));
        },
      );
      addTearDown(main.dispose);
      addTearDown(detached.dispose);
      detached.applySnapshot(main.snapshot());
      detached.setPlotHighlightedWatch('selected', selectWatchRow: true);
      await Future<void>.delayed(Duration.zero);
      expect(main.plotHighlightedWatchKey, 'selected');
      expect(detached.plotHighlightedWatchKey, 'selected');
      expect(main.stateSnapshot()['plotHighlightedWatchKey'], 'selected');
      expect(main.plotWatchSelectionRevision, 1);
      expect(detached.plotWatchSelectionRevision, 1);
      detached.setPlotHighlightedWatch(null, selectWatchRow: true);
      await Future<void>.delayed(Duration.zero);
      expect(main.plotHighlightedWatchKey, isNull);
      expect(detached.plotHighlightedWatchKey, isNull);
      expect(main.plotWatchSelectionRevision, 2);
      expect(detached.plotWatchSelectionRevision, 2);
      expect(commands, [
        ControllerCommand.configurePlotView,
        ControllerCommand.configurePlotView,
      ]);
    },
  );

  Future<Finder> pumpPanels(
    WidgetTester tester,
    TakeALookController controller, {
    TakeALookController? watchController,
  }) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 500,
                child: buildWorkspacePanel(
                  WorkspacePanelId.watch,
                  watchController ?? controller,
                ),
              ),
              Expanded(child: TelemetryChart(controller: controller)),
            ],
          ),
        ),
      ),
    );
    return find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is TelemetryPainter,
    );
  }

  void expectRowSelected(WidgetTester tester, String key, bool selected) {
    final row = tester.widget<Container>(
      find.byKey(ValueKey('watch-row-$key')),
    );
    expect(
      (row.decoration! as BoxDecoration).color,
      selected ? TalColors.selection : TalColors.input,
    );
  }

  testWidgets(
    'clicking curves replaces table selection and only blank clicks clear it',
    (tester) async {
      final controller = selectionController();
      try {
        final chart = await pumpPanels(tester, controller);
        final mapping = mappingFor(controller, tester.getSize(chart));
        await tester.tap(find.text('selected'));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(find.text('other'));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expectRowSelected(tester, 'selected', true);
        expectRowSelected(tester, 'other', true);
        expect(controller.plotHighlightedWatchKey, 'other');

        // Clicking an already highlighted curve must still select just its row.
        await tester.tapAt(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 8)),
        );
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, 'other');
        expectRowSelected(tester, 'other', true);
        expectRowSelected(tester, 'selected', false);
        await tester.tapAt(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 4)),
        );
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, 'selected');
        expectRowSelected(tester, 'selected', true);
        expectRowSelected(tester, 'other', false);
        final painter =
            tester.widget<CustomPaint>(chart).painter! as TelemetryPainter;
        final hit = inspectTelemetrySeries(
          telemetryPlotSeries(controller, mapping),
          mapping,
          position: painter.hoverPosition!.value,
          highlightedWatchKey: controller.plotHighlightedWatchKey,
        )!;
        expect(hit.sample, const Offset(5, 4));

        await tester.tapAt(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(3, 9)),
        );
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, isNull);
        expectRowSelected(tester, 'selected', false);
        expectRowSelected(tester, 'other', false);
        expect(
          curvePaints(recordPainter(painter, tester.getSize(chart))),
          hasLength(2),
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets(
    'overlapping curve clicks follow table order with navigation disabled',
    (tester) async {
      final controller = controllerWithSeries({
        'first': [const Offset(0, 4), const Offset(10, 4)],
        'second': [const Offset(0, 4), const Offset(10, 4)],
      });
      try {
        controller.configurePlotView({
          'plotMouseXEnabled': false,
          'plotMouseYEnabled': false,
        });
        final chart = await pumpPanels(tester, controller);
        final mapping = mappingFor(controller, tester.getSize(chart));
        final point =
            tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 4));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, 'first');
        expectRowSelected(tester, 'first', true);
        controller.reorderWatch(0, 1);
        await tester.pump();
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, 'second');
        expectRowSelected(tester, 'second', true);
        expectRowSelected(tester, 'first', false);
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets(
    'clicking a member curve expands and selects its collapsed table row',
    (tester) async {
      final controller = controllerWithSeries({
        'motor': [],
        'motor.speed': [const Offset(0, 4), const Offset(10, 4)],
      });
      try {
        final chart = await pumpPanels(tester, controller);
        expect(find.text('speed'), findsNothing);
        final mapping = mappingFor(controller, tester.getSize(chart));
        await tester.tapAt(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 4)),
        );
        await tester.pumpAndSettle();
        expect(controller.plotHighlightedWatchKey, 'motor.speed');
        expect(find.text('speed'), findsOneWidget);
        expectRowSelected(tester, 'motor.speed', true);
        expectRowSelected(tester, 'motor', false);
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('clicking a curve scrolls its selected row into view', (
    tester,
  ) async {
    final controller = controllerWithSeries({
      for (var index = 0; index < 40; index++)
        'variable_$index': index == 39
            ? [const Offset(0, 4), const Offset(10, 4)]
            : [],
    });
    try {
      final chart = await pumpPanels(tester, controller);
      expect(find.text('variable_39').hitTestable(), findsNothing);
      final mapping = mappingFor(controller, tester.getSize(chart));
      await tester.tapAt(
        tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 4)),
      );
      await tester.pumpAndSettle();
      expect(controller.plotHighlightedWatchKey, 'variable_39');
      expect(find.text('variable_39').hitTestable(), findsOneWidget);
      expectRowSelected(tester, 'variable_39', true);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('curve clicks update a separately synchronized watch panel', (
    tester,
  ) async {
    final controller = selectionController();
    final detached = TakeALookController(remoteCommand: (_, _) async {});
    detached.applySnapshot(controller.snapshot());
    void synchronize() => detached.applySnapshot(controller.stateSnapshot());
    controller.stateSyncChanges.addListener(synchronize);
    try {
      final chart = await pumpPanels(
        tester,
        controller,
        watchController: detached,
      );
      final mapping = mappingFor(controller, tester.getSize(chart));
      await tester.tapAt(
        tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 8)),
      );
      await tester.pumpAndSettle();
      expectRowSelected(tester, 'other', true);
      expect(detached.plotHighlightedWatchKey, 'other');
      expect(
        detached.plotWatchSelectionRevision,
        controller.plotWatchSelectionRevision,
      );
      await tester.tapAt(
        tester.getTopLeft(chart) + pixelFor(mapping, const Offset(3, 9)),
      );
      await tester.pumpAndSettle();
      expectRowSelected(tester, 'other', false);
      expect(detached.plotHighlightedWatchKey, isNull);
    } finally {
      controller.stateSyncChanges.removeListener(synchronize);
      controller.dispose();
      detached.dispose();
    }
  });

  testWidgets(
    'selecting a row locks highlight and values until the chart is clicked',
    (tester) async {
      final controller = selectionController();
      try {
        final chart = await pumpPanels(tester, controller);
        final size = tester.getSize(chart);
        final mapping = mappingFor(controller, size);
        TelemetryPainter painter() =>
            tester.widget<CustomPaint>(chart).painter! as TelemetryPainter;
        await tester.tap(find.text('selected'));
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, 'selected');
        expect(curvePaints(recordPainter(painter(), size)), hasLength(4));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer();
        await mouse.moveTo(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(5, 8)),
        );
        await tester.pump();
        var canvas = recordPainter(painter(), size);
        expect(
          curvePaints(canvas).last.color,
          isSameColorAs(
            Color.lerp(controller.watches.first.color, Colors.white, 0.3)!,
          ),
        );
        Offset marker(TestRecordingCanvas canvas) =>
            canvas.invocations
                    .firstWhere(
                      (call) => call.invocation.memberName == #drawCircle,
                    )
                    .invocation
                    .positionalArguments
                    .first
                as Offset;
        expect(marker(canvas), pixelFor(mapping, const Offset(5, 4)));

        updateSamples(controller, {
          'selected': [
            const Offset(0, 2),
            const Offset(5, 4.5),
            const Offset(10, 6),
          ],
        });
        await tester.pump(const Duration(milliseconds: 20));
        canvas = recordPainter(painter(), size);
        expect(marker(canvas), pixelFor(mapping, const Offset(5, 4.5)));

        await mouse.moveTo(const Offset(10, 10));
        await tester.pump();
        expect(curvePaints(recordPainter(painter(), size)), hasLength(4));
        expect(
          marker(recordPainter(painter(), size)),
          pixelFor(mapping, const Offset(10, 6)),
        );
        await tester.tapAt(
          tester.getTopLeft(chart) + pixelFor(mapping, const Offset(3, 9)),
        );
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, isNull);
        expect(curvePaints(recordPainter(painter(), size)), hasLength(2));

        await tester.tap(find.text('other'));
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, 'other');
        await mouse.removePointer();
      } finally {
        controller.dispose();
      }
    },
  );

  for (final buttons in [
    kPrimaryMouseButton,
    kSecondaryMouseButton,
    kMiddleMouseButton,
  ]) {
    testWidgets(
      'dragging out and back preserves locked highlight (button $buttons)',
      (tester) async {
        final controller = selectionController();
        try {
          final chart = await pumpPanels(tester, controller);
          await tester.tap(find.text('selected'));
          await tester.pump();
          final start = tester.getCenter(chart);
          final drag = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
            buttons: buttons,
          );
          await drag.moveBy(const Offset(40, 20));
          await tester.pump();
          expect(controller.plotHighlightedWatchKey, 'selected');
          await drag.moveTo(start);
          await drag.up();
          await tester.pump();
          expect(controller.plotHighlightedWatchKey, 'selected');
          expectRowSelected(tester, 'selected', true);
          expectRowSelected(tester, 'other', false);
          expect(find.text('View All'), findsNothing);

          final cancel = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
            buttons: buttons,
          );
          await cancel.cancel();
          await tester.pump();
          expect(controller.plotHighlightedWatchKey, 'selected');
        } finally {
          controller.dispose();
        }
      },
    );
  }

  testWidgets(
    'wheel and disabled-axis drags preserve the lock; margin clicks clear it',
    (tester) async {
      final controller = selectionController();
      try {
        final chart = await pumpPanels(tester, controller);
        await tester.tap(find.text('selected'));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(chart),
            scrollDelta: const Offset(0, -40),
          ),
        );
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, 'selected');
        controller.configurePlotView({
          'plotMouseXEnabled': false,
          'plotMouseYEnabled': false,
        });
        final drag = await tester.startGesture(
          tester.getCenter(chart),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(30, 30));
        await drag.up();
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, 'selected');
        final click = await tester.startGesture(
          tester.getTopLeft(chart) + const Offset(20, 20),
          kind: PointerDeviceKind.mouse,
        );
        await click.moveBy(const Offset(1, 1));
        await click.up();
        await tester.pump();
        expect(controller.plotHighlightedWatchKey, isNull);
      } finally {
        controller.dispose();
      }
    },
  );
}
