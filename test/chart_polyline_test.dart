import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/cartesian_renderer.dart';

void main() {
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
