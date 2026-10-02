import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/chart/chart.dart';

void main() {
  test(
    'chart downsampling bounds point count and preserves visible extrema',
    () {
      final samples = [
        for (var index = 0; index < 1000; index += 1)
          Offset(
            index / 100,
            index == 444
                ? 100
                : index == 555
                ? -100
                : index % 10 / 10,
          ),
      ];

      final reduced = downsampleTelemetrySamples(
        samples,
        xMin: 2,
        xMax: 8,
        pixelWidth: 50,
      );

      expect(reduced.length, lessThanOrEqualTo(101));
      expect(reduced.every((point) => point.dx >= 2 && point.dx <= 8), isTrue);
      expect(reduced.map((point) => point.dy), containsAll([100, -100]));
      for (var index = 1; index < reduced.length; index += 1) {
        expect(reduced[index].dx, greaterThanOrEqualTo(reduced[index - 1].dx));
      }
    },
  );

  test('small visible series is returned without reduction', () {
    final samples = [const Offset(0, 1), const Offset(1, 2)];
    expect(
      downsampleTelemetrySamples(samples, xMin: 0, xMax: 1, pixelWidth: 100),
      samples,
    );
  });
}
