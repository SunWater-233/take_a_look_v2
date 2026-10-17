import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/viewport.dart';
import 'package:take_a_look_v2/src/chart/hover.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/telemetry/raw_recording.dart';

void main() {
  test(
    'controller and detached chart read evicted history, hover real samples, and show the entire session',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tal_chart_history_',
      );
      final recording = RawSampleRecording(directory);
      final controller = TakeALookController()..loadDemoSymbols();
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(() {
        controller.dispose();
        detached.dispose();
        recording.close();
        directory.deleteSync(recursive: true);
      });
      controller.selectSymbols([demoSymbols.first.key]);
      controller.addSelectedToWatch();
      controller.configurePlotView({'plotRetentionSeconds': 1});
      final watch = controller.watches.single;
      final frames = [
        for (var i = 0; i <= 2400; i++)
          {
            'elapsed': i / 10,
            'values': <String, double>{watch.symbol.key: i / 100},
          },
      ];
      recording.append(frames, {watch.symbol.key: 'Alpha'});
      controller.applySnapshot({'rawRecording': recording.status});
      controller.applyBackendSamples({'frames': frames});
      expect(watch.samples.first.dx, greaterThan(238));
      controller.setPlotViewport(xMin: 20, xMax: 22);
      await _settleHistory(controller);
      expect(controller.plotSamplesFor(watch).first.dx, 19);
      expect(controller.plotSamplesFor(watch).last.dx, 23);
      expect(watch.samples.first.dx, greaterThan(238));
      expect(controller.plotWindowEndSeconds, 22);

      final viewport = CartesianPlotViewport(
        plot: const Rect.fromLTWH(0, 0, 800, 400),
        xMin: 20,
        xMax: 22,
        yMin: 0,
        yMax: 4,
      );
      final hit = inspectTelemetrySeries(
        telemetryPlotSeries(controller, viewport),
        viewport,
        position: Offset(viewport.mapX(21.3), viewport.mapY(2.13)),
        highlightedWatchKey: watch.symbol.key,
      );
      expect(hit!.sample, const Offset(21.3, 2.13));

      detached.applySnapshot(controller.snapshot());
      await _settleHistory(detached);
      expect(
        detached.plotSamplesFor(detached.watches.single).toList(),
        controller.plotSamplesFor(watch).toList(),
      );
      controller.togglePlotting();
      final newer = [
        for (var second = 241; second <= 245; second++)
          {
            'elapsed': second.toDouble(),
            'values': <String, double>{watch.symbol.key: second / 10},
          },
      ];
      recording.append(newer, {watch.symbol.key: 'Alpha'});
      controller.applyBackendSamples({'frames': newer});
      controller.setPlotViewport(xMin: 239, xMax: 244);
      await _settleHistory(controller);
      // The pause snapshot covers the left edge, but not these newer records.
      expect(
        controller.plotSamplesFor(watch).any((point) => point.dx == 244),
        isTrue,
      );
      controller.setPlotViewport(xMin: 5, xMax: 7);
      await _settleHistory(controller);
      expect(controller.plotSamplesFor(watch).first.dx, 4);
      expect(controller.plottingPaused, isTrue);
      controller.showAllPlotSamples();
      await _settleHistory(controller);
      final all = telemetryViewport(controller, const Size(800, 400));
      expect(all.xMin, 0);
      expect(all.xMax, 245);
      expect(controller.plotSamplesFor(watch).first.dx, 0);
      expect(controller.plotSamplesFor(watch).last.dx, 245);
      controller.setPlotViewport(xMin: 0, xMax: 180);
      expect(controller.plotVisibleWindowSeconds, 180);

      controller.togglePlotting();
      controller.resetPlotView();
      // The default 12-second live window exceeds this test's 1-second cache;
      // restoring the usual retention returns immediately to the live buffer.
      controller.configurePlotView({'plotRetentionSeconds': 60});
      controller.setPlotViewport(
        xMin: 244.5,
        xMax: 245,
        preserveFollowLatest: true,
      );
      expect(
        identical(controller.plotSamplesFor(watch), watch.samples),
        isTrue,
      );
      controller.clearSamples();
      expect(controller.plotHistory.retainedPoints, 0);
      expect(controller.plotSamplesFor(watch), isEmpty);
      expect(controller.rawRecording, isEmpty);
    },
  );
}

Future<void> _settleHistory(TakeALookController controller) async {
  final ready = DateTime.now().add(const Duration(seconds: 10));
  while (controller.plotHistory.loading && DateTime.now().isBefore(ready)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(controller.plotHistory.error, isNull);
  expect(controller.plotHistory.loading, isFalse);
}
