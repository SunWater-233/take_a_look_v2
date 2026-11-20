import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';

void main() {
  testWidgets('batched waveform stays clipped across gaps at high DPI', (
    tester,
  ) async {
    await tester.runAsync(() async {
      const size = Size(64, 64);
      const viewport = CartesianPlotViewport(
        plot: Rect.fromLTWH(0, 0, 60, 60),
        xMin: 0,
        xMax: 6,
        yMin: 0,
        yMax: 6,
      );
      final geometry = WaveformGeometry();
      ui.Picture record(double low, double high) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(2);
        CartesianChartRenderer(
          canvas: canvas,
          size: size,
          viewport: viewport,
        ).drawPolyline(
          [
            for (var i = 0; i <= 200; i++) Offset(i / 100, low),
            const Offset(3, double.nan),
            for (var i = 400; i <= 600; i++) Offset(i / 100, high),
          ],
          Colors.red,
          strokeWidth: 2,
          useMesh: true,
          devicePixelRatio: 2,
          geometry: geometry,
        );
        return recorder.endRecording();
      }

      // Both pictures must remain valid when the same scratch space is reused.
      final first = record(1, 5);
      final second = record(2, 4);
      for (final (picture, y1, y2) in [(first, 100, 20), (second, 80, 40)]) {
        final image = await picture.toImage(128, 128);
        final pixels = (await image.toByteData())!;
        int rgba(int x, int y) => pixels.getUint32((y * 128 + x) * 4);
        expect(rgba(20, y1) & 0xff, greaterThan(200));
        expect(rgba(100, y2) & 0xff, greaterThan(200));
        expect(rgba(20, y1 - 5) & 0xff, 0);
        expect(rgba(60, 60) & 0xff, 0);
        image.dispose();
        picture.dispose();
      }
    });
  });

  testWidgets(
    'fast polyline keeps both finite runs without bridging missing samples',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        CartesianChartRenderer(
          canvas: Canvas(recorder),
          size: const Size(64, 64),
          viewport: const CartesianPlotViewport(
            plot: Rect.fromLTWH(0, 0, 60, 60),
            xMin: 0,
            xMax: 6,
            yMin: 0,
            yMax: 6,
          ),
        ).drawPolyline(
          const [
            Offset(0, 1),
            Offset(2, 1),
            Offset(3, double.nan),
            Offset(4, 5),
            Offset(6, 5),
          ],
          Colors.red,
          strokeWidth: 2,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        final pixels = (await image.toByteData())!;
        int alpha(int x, int y) => pixels.getUint8((y * 64 + x) * 4 + 3);
        expect(alpha(10, 50), greaterThan(0));
        expect(alpha(50, 10), greaterThan(0));
        expect(alpha(30, 30), 0);
        image.dispose();
        picture.dispose();
      });
    },
  );
}
