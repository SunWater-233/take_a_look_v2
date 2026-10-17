import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';
import 'package:take_a_look_v2/src/chart/hover.dart';
import 'package:take_a_look_v2/src/chart/painter.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

TakeALookController controllerWithSeries(Map<String, List<Offset>> samples) {
  final controller = TakeALookController();
  controller.applySnapshot({
    'symbols': [
      for (final (index, name) in samples.keys.indexed)
        {
          'source': 'test.c',
          'name': name,
          'key': name,
          'address': 0x20000000 + index * 4,
          'type': 'float',
          'size': 4,
        },
    ],
    'watches': <Object?>[],
  });
  controller.selectSymbols(samples.keys);
  controller.addSelectedToWatch();
  for (final watch in controller.watches) {
    controller.setWatchReadMode(watch.symbol.key, WatchReadMode.capture);
  }
  controller.setAllWatchesPlotted(true);
  updateSamples(controller, samples);
  controller.configurePlotView({
    'followLatest': false,
    'xMin': 0,
    'xMax': 10,
    'plotAutoY': false,
    'yMin': 0,
    'yMax': 10,
    'plotShowLegend': false,
  });
  return controller;
}

void updateSamples(
  TakeALookController controller,
  Map<String, List<Offset>> samples,
) {
  controller.applyTelemetrySnapshot({
    'elapsedSeconds': 10,
    'watches': [
      for (final entry in samples.entries)
        {
          'key': entry.key,
          'value': 999,
          'samples': [
            for (final point in entry.value) [point.dx, point.dy],
          ],
        },
    ],
  });
}

CartesianPlotViewport mappingFor(
  TakeALookController controller, [
  Size size = const Size(720, 480),
]) {
  final viewport = telemetryViewport(controller, size);
  return CartesianPlotViewport(
    plot: viewport.plot,
    xMin: viewport.xMin,
    xMax: viewport.xMax,
    yMin: viewport.yMin,
    yMax: viewport.yMax,
    invertX: controller.plotInvertX,
    invertY: controller.plotInvertY,
  );
}

Offset pixelFor(CartesianPlotViewport viewport, Offset sample) =>
    Offset(viewport.mapX(sample.dx), viewport.mapY(sample.dy));

TestRecordingCanvas recordPainter(TelemetryPainter painter, Size size) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  if (!painter.paintInspection) {
    TelemetryInspectionPainter(
      painter.controller,
      hoverPosition: painter.hoverPosition!,
      inspectionAnchorY: painter.inspectionAnchorY,
    ).paint(canvas, size);
  }
  return canvas;
}

List<Paint> curvePaints(TestRecordingCanvas canvas) => [
  for (final call in canvas.invocations)
    if (call.invocation.memberName == #drawRawPoints)
      call.invocation.positionalArguments[2] as Paint,
];

void main() {
  testWidgets('separate hover layer preserves pixels including the legend', (
    tester,
  ) async {
    final controller = controllerWithSeries({
      'signal': [const Offset(0, 9.5), const Offset(10, 9.5)],
    });
    controller.configurePlotView({
      'plotAutoY': false,
      'yMin': 0.0,
      'yMax': 10.0,
    });
    final position = ValueNotifier<Offset?>(const Offset(100, 61));
    controller.setPlotHighlightedWatch('signal');
    const size = Size(640, 360);
    try {
      await tester.runAsync(() async {
        Future<List<int>> pixels(bool split) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          TelemetryPainter(
            controller,
            hoverPosition: position,
            paintInspection: !split,
          ).paint(canvas, size);
          if (split) {
            TelemetryInspectionPainter(
              controller,
              hoverPosition: position,
            ).paint(canvas, size);
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(640, 360);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final result = bytes!.buffer.asUint8List().toList();
          image.dispose();
          picture.dispose();
          return result;
        }

        expect(await pixels(true), await pixels(false));
      });
    } finally {
      controller.dispose();
      position.dispose();
    }
  });
  test('curve hit reports the nearest real sample, not the latest value', () {
    final controller = controllerWithSeries({
      'signal': [const Offset(2, 2), const Offset(8, 8)],
    });
    addTearDown(controller.dispose);
    final viewport = mappingFor(controller);
    final hit = hitTestTelemetrySeries(
      telemetryPlotSeries(controller, viewport),
      viewport,
      pixelFor(viewport, const Offset(5.8, 5.8)),
    )!;
    expect(hit.sample, const Offset(8, 8));
    expect(hit.position, pixelFor(viewport, hit.sample));
    expect(hit.valueText, 't = 8 s\n采样值 = 8');
  });

  test('overlaps use the first curve; distinct curves use the nearest hit', () {
    final controller = controllerWithSeries({
      'first': [const Offset(0, 3), const Offset(10, 3)],
      'second': [const Offset(0, 3), const Offset(10, 3)],
      'nearby': [const Offset(0, 3.1), const Offset(10, 3.1)],
    });
    addTearDown(controller.dispose);
    final viewport = mappingFor(controller);
    final series = telemetryPlotSeries(controller, viewport);
    TelemetryHoverHit? hitAt(Offset sample) =>
        hitTestTelemetrySeries(series, viewport, pixelFor(viewport, sample));
    expect(hitAt(const Offset(5, 3))!.series.watch.symbol.key, 'first');
    expect(hitAt(const Offset(5, 3.1))!.series.watch.symbol.key, 'nearby');
    expect(hitAt(const Offset(5, 8)), isNull);
    expect(hitAt(const Offset(-1, 3)), isNull);
  });

  test('curve order follows grouped table rows after a root is reordered', () {
    final controller = controllerWithSeries({
      'motor': [],
      'motor.speed': [const Offset(0, 3), const Offset(10, 3)],
      'other': [const Offset(0, 3), const Offset(10, 3)],
      'motor.current[0]': [const Offset(0, 3), const Offset(10, 3)],
    });
    addTearDown(controller.dispose);
    controller.toggleWatchPlot('motor', false);
    final viewport = mappingFor(controller);
    var series = telemetryPlotSeries(controller, viewport);
    expect(series.map((item) => item.watch.symbol.key), [
      'motor.speed',
      'motor.current[0]',
      'other',
    ]);
    controller.reorderWatch(0, 2);
    series = telemetryPlotSeries(controller, viewport);
    expect(series.map((item) => item.watch.symbol.key), [
      'other',
      'motor.speed',
      'motor.current[0]',
    ]);
    expect(
      hitTestTelemetrySeries(
        series,
        viewport,
        pixelFor(viewport, const Offset(5, 3)),
      )!.series.watch.symbol.key,
      'other',
    );
  });

  test(
    'dense and inverted curves retain original samples for hover values',
    () {
      final controller = controllerWithSeries({
        'signal': [for (var i = 0; i <= 1000; i++) Offset(i / 100, i / 100)],
      });
      addTearDown(controller.dispose);
      controller.configurePlotView({'plotInvertX': true, 'plotInvertY': true});
      final viewport = mappingFor(controller, const Size(180, 200));
      final series = telemetryPlotSeries(controller, viewport);
      expect(
        series.single.points.length,
        lessThan(series.single.samples.length),
      );
      const sample = Offset(5.53, 5.53);
      final hit = hitTestTelemetrySeries(
        series,
        viewport,
        pixelFor(viewport, sample),
      )!;
      expect(hit.sample, sample);
      expect(hit.valueText, 't = 5.53 s\n采样值 = 5.53');
    },
  );

  test('paused plots inspect the frozen samples shown on screen', () {
    final controller = controllerWithSeries({
      'signal': [const Offset(0, 3), const Offset(10, 3)],
    });
    addTearDown(controller.dispose);
    controller.togglePlotting();
    updateSamples(controller, {
      'signal': [const Offset(0, 8), const Offset(10, 8)],
    });
    final viewport = mappingFor(controller);
    final hit = hitTestTelemetrySeries(
      telemetryPlotSeries(controller, viewport),
      viewport,
      pixelFor(viewport, const Offset(5, 3)),
    )!;
    expect(hit.sample.dy, 3);
    expect(controller.watches.single.samples.first.dy, 8);
  });

  Future<Finder> pumpChart(
    WidgetTester tester,
    TakeALookController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 480,
            child: TelemetryChart(controller: controller),
          ),
        ),
      ),
    );
    return find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is TelemetryPainter,
    );
  }

  testWidgets('hover highlights in list order and clears on exit or drag', (
    tester,
  ) async {
    final controller = controllerWithSeries({
      'first': [const Offset(0, 3), const Offset(10, 3)],
      'second': [const Offset(0, 3), const Offset(10, 3)],
    });
    final chart = await pumpChart(tester, controller);
    final render = tester.renderObject<RenderCustomPaint>(chart);
    final painter =
        tester.widget<CustomPaint>(chart).painter! as TelemetryPainter;
    final viewport = mappingFor(controller, render.size);
    final local = pixelFor(viewport, const Offset(5, 3));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getTopLeft(chart));
    await mouse.moveTo(tester.getTopLeft(chart) + local);
    expect(render.debugNeedsPaint, isFalse);
    expect(
      tester
          .renderObject<RenderCustomPaint>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter is TelemetryInspectionPainter,
            ),
          )
          .debugNeedsPaint,
      isTrue,
    );
    await tester.pump();

    var paints = curvePaints(recordPainter(painter, render.size));
    expect(paints, hasLength(4));
    expect(paints.last.strokeWidth, greaterThan(paints.first.strokeWidth));
    expect(
      paints.last.color,
      isSameColorAs(
        Color.lerp(controller.watches.first.color, Colors.white, 0.3)!,
      ),
    );
    controller.reorderWatch(0, 1);
    expect(render.debugNeedsPaint, isTrue);
    await tester.pump();
    paints = curvePaints(recordPainter(painter, render.size));
    expect(paints.first.color, isSameColorAs(controller.watches.first.color));
    expect(paints[1].color, isSameColorAs(controller.watches.last.color));
    expect(
      paints.last.color,
      isSameColorAs(
        Color.lerp(controller.watches.first.color, Colors.white, 0.3)!,
      ),
    );

    controller.toggleWatchPlot(controller.watches.first.symbol.key, false);
    await tester.pump();
    paints = curvePaints(recordPainter(painter, render.size));
    expect(paints, hasLength(3));
    expect(
      paints.last.color,
      isSameColorAs(
        Color.lerp(controller.watches.last.color, Colors.white, 0.3)!,
      ),
    );

    await mouse.down(tester.getTopLeft(chart) + local);
    await tester.pump();
    expect(curvePaints(recordPainter(painter, render.size)), hasLength(1));
    await mouse.moveTo(tester.getTopLeft(chart) + local + const Offset(10, 0));
    await mouse.up();
    expect(controller.plotHighlightedWatchKey, isNull);
    await mouse.moveTo(tester.getTopLeft(chart) + local + const Offset(1, 0));
    await tester.pump();
    expect(curvePaints(recordPainter(painter, render.size)), hasLength(3));
    await mouse.moveTo(const Offset(790, 590));
    await tester.pump();
    expect(curvePaints(recordPainter(painter, render.size)), hasLength(1));
    await mouse.removePointer();
    controller.dispose();
  });

  testWidgets('stationary hover follows telemetry changes and curve removal', (
    tester,
  ) async {
    final controller = controllerWithSeries({
      'first': [const Offset(0, 3), const Offset(10, 3)],
      'second': [const Offset(0, 6), const Offset(10, 6)],
    });
    final chart = await pumpChart(tester, controller);
    final size = tester.getSize(chart);
    final painter =
        tester.widget<CustomPaint>(chart).painter! as TelemetryPainter;
    final viewport = mappingFor(controller, size);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(
      tester.getTopLeft(chart) + pixelFor(viewport, const Offset(5, 3)),
    );
    await tester.pump();
    updateSamples(controller, {
      'first': [const Offset(0, 8), const Offset(10, 8)],
      'second': [const Offset(0, 3), const Offset(10, 3)],
    });
    expect(
      tester.renderObject<RenderCustomPaint>(chart).debugNeedsPaint,
      isTrue,
    );
    await tester.pump();
    final paints = curvePaints(recordPainter(painter, size));
    expect(
      paints.last.color,
      isSameColorAs(
        Color.lerp(controller.watches.last.color, Colors.white, 0.3)!,
      ),
    );
    controller.removeWatch('second');
    await tester.pump();
    final canvas = recordPainter(painter, size);
    expect(curvePaints(canvas), hasLength(1));
    expect(
      canvas.invocations.where(
        (call) => call.invocation.memberName == #drawRRect,
      ),
      isEmpty,
    );
    await mouse.removePointer();
    controller.dispose();
  });

  testWidgets('hover tooltip stays within the chart at every plot corner', (
    tester,
  ) async {
    final controller = controllerWithSeries({
      'signal': [
        const Offset(0, 0),
        const Offset(0, 10),
        const Offset(10, 10),
        const Offset(10, 0),
        const Offset(0, 0),
      ],
    });
    final chart = await pumpChart(tester, controller);
    final size = tester.getSize(chart);
    final painter =
        tester.widget<CustomPaint>(chart).painter! as TelemetryPainter;
    final plot = mappingFor(controller, size).plot.deflate(1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    for (final corner in [
      plot.topLeft,
      plot.topRight,
      plot.bottomLeft,
      plot.bottomRight,
    ]) {
      await mouse.moveTo(tester.getTopLeft(chart) + corner);
      await tester.pump();
      final canvas = recordPainter(painter, size);
      final box =
          canvas.invocations
                  .firstWhere(
                    (call) => call.invocation.memberName == #drawRRect,
                  )
                  .invocation
                  .positionalArguments
                  .first
              as RRect;
      expect(box.left, greaterThanOrEqualTo(8));
      expect(box.top, greaterThanOrEqualTo(8));
      expect(box.right, lessThanOrEqualTo(size.width - 8));
      expect(box.bottom, lessThanOrEqualTo(size.height - 8));
    }
    await mouse.removePointer();
    controller.dispose();
  });
}
