// Entry for an isolated Flutter Windows release harness. TAL_HISTORY_BENCH_DIR
// points at the fixtures produced by history_benchmark.dart. Uses the production
// controller/chart, then saves frame timings and a rendered history screenshot.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode) throw StateError('Use a release build');
  final path = Platform.environment['TAL_HISTORY_BENCH_DIR']!;
  final controller = TakeALookController(backendCommand: (_, _) async {});
  final boundary = GlobalKey();
  controller.applySnapshot({
    'symbols': [
      for (var c = 0; c < 32; c++)
        {
          'key': 'c$c',
          'source': 'fixture.c',
          'name': 'Channel $c',
          'address': 0x20000000 + c * 4,
          'type': 'float',
          'size': 4,
        },
    ],
    'watches': [
      for (var c = 0; c < 32; c++)
        {
          'key': 'c$c',
          'plotted': true,
          'sampling': true,
          'color': Colors.primaries[c % Colors.primaries.length].toARGB32(),
        },
    ],
    'elapsedSeconds': 131.074,
    'rawRecording': {'historyPath': '$path/data-32'},
  });
  controller.setPlotViewport(xMin: 10, xMax: 22);
  runApp(
    MaterialApp(
      theme: buildTalTheme(),
      home: Scaffold(
        body: RepaintBoundary(
          key: boundary,
          child: TelemetryChart(controller: controller),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  final frames = <ui.FrameTiming>[];
  void collect(List<ui.FrameTiming> values) => frames.addAll(values);
  WidgetsBinding.instance.addTimingsCallback(collect);
  // Continuous viewport changes at frame cadence, across data long evicted
  // from a 60-second live cache, including rapid direction changes.
  for (var i = 0; i < 300; i++) {
    final position = i % 120;
    final start = 5 + (position < 60 ? position : 120 - position) * 1.4;
    controller.setPlotViewport(xMin: start, xMax: start + 12);
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  controller.setPlotViewport(xMin: 10, xMax: 22);
  await Future<void>.delayed(const Duration(seconds: 1));
  WidgetsBinding.instance.removeTimingsCallback(collect);
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$path/history-ui.png').writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
  double percentile(List<double> values, double fraction) {
    values.sort();
    return values[(values.length * fraction).floor().clamp(
      0,
      values.length - 1,
    )];
  }

  final build = [
    for (final frame in frames) frame.buildDuration.inMicroseconds / 1000,
  ];
  final raster = [
    for (final frame in frames) frame.rasterDuration.inMicroseconds / 1000,
  ];
  final result = {
    'mode':
        'Flutter Windows release; production chart; synthetic 32 x 131075 samples',
    'frames': frames.length,
    'buildP50Ms': percentile(build, 0.5),
    'buildP95Ms': percentile(build, 0.95),
    'buildMaxMs': build.reduce((a, b) => a > b ? a : b),
    'rasterP95Ms': percentile(raster, 0.95),
    'rasterMaxMs': raster.reduce((a, b) => a > b ? a : b),
    'buildOver16ms': build.where((ms) => ms > 16.667).length,
    'rasterOver16ms': raster.where((ms) => ms > 16.667).length,
    'historyError': controller.plotHistory.error,
    'cachedPoints': controller.plotHistory.retainedPoints,
    'loadedSeries': controller.watches
        .where((watch) => controller.plotSamplesFor(watch).isNotEmpty)
        .length,
  };
  File(
    '$path/history-ui-results.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  controller.dispose();
  exit(result['historyError'] == null && result['loadedSeries'] == 32 ? 0 : 1);
}
