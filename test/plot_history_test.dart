import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/telemetry/numeric_history.dart';
import 'package:take_a_look_v2/src/telemetry/plot_history.dart';

void main() {
  testWidgets(
    'drag requests are throttled, single-flight, prefetched and replaced by the latest viewport',
    (tester) async {
      final requests = <HistoryRequest>[];
      final results = <Completer<HistoryWindow>>[];
      final history = PlotHistory(
        onChanged: () {},
        reader: (request) {
          requests.add(request);
          final result = Completer<HistoryWindow>();
          results.add(result);
          return result.future;
        },
      );
      addTearDown(history.dispose);
      void view(double start, double end, {String path = 'session'}) =>
          history.update(
            path: path,
            keys: ['a'],
            start: start,
            end: end,
            sourceEnd: 1000,
            pixelWidth: 500,
            enabled: true,
          );
      void complete(int index, {bool reduced = false}) =>
          results[index].complete(
            HistoryWindow(
              request: requests[index],
              series: {
                'a': Float64List.fromList([
                  requests[index].start,
                  10,
                  requests[index].end,
                  20,
                ]),
              },
              reduced: reduced,
            ),
          );

      view(10, 20);
      await tester.pump(const Duration(milliseconds: 60));
      expect(requests, hasLength(1));
      expect(requests.first.start, 5);
      expect(requests.first.end, 25);
      for (var i = 0; i < 100; i++) {
        view(100 + i.toDouble(), 110 + i.toDouble());
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(requests, hasLength(1));
      complete(0);
      await tester.pump();
      expect(
        history.samplesFor('a'),
        isNull,
      ); // No stale curve at the new time.
      await tester.pump(const Duration(milliseconds: 60));
      expect(requests, hasLength(2));
      expect(requests[1].start, 194);
      complete(1);
      await tester.pump();
      expect(history.samplesFor('a')!.first.dx, 194);
      view(200, 210); // Entire viewport fits the prefetched margin.
      await tester.pump(const Duration(seconds: 1));
      expect(requests, hasLength(2));

      view(0, 500);
      await tester.pump(const Duration(milliseconds: 60));
      complete(2, reduced: true);
      await tester.pump();
      view(300, 300.2); // Same covered range, but zoom needs original samples.
      await tester.pump(const Duration(milliseconds: 60));
      expect(requests, hasLength(4));
      view(1, 2, path: 'new-session');
      complete(3);
      await tester.pump();
      expect(history.samplesFor('a'), isNull);
      await tester.pump(const Duration(milliseconds: 60));
      expect(requests.last.path, 'new-session');
      complete(4);
      await tester.pump();
      expect(history.retainedPoints, 2);
    },
  );

  testWidgets(
    'clearing and disposal discard asynchronous results and surface read errors',
    (tester) async {
      final results = <Completer<HistoryWindow>>[];
      var notifications = 0;
      final history = PlotHistory(
        onChanged: () => notifications++,
        reader: (request) {
          final result = Completer<HistoryWindow>();
          results.add(result);
          return result.future;
        },
      );
      history.update(
        path: 'path',
        keys: ['a'],
        start: 0,
        end: 10,
        sourceEnd: 20,
        pixelWidth: 100,
        enabled: true,
      );
      await tester.pump(const Duration(milliseconds: 60));
      results.single.completeError(const FormatException('missing index'));
      await tester.pump();
      expect(history.error, contains('missing index'));
      expect(history.loading, isFalse);
      history.clear();
      expect(history.error, isNull);
      history.update(
        path: 'path',
        keys: ['a'],
        start: 0,
        end: 10,
        sourceEnd: 20,
        pixelWidth: 100,
        enabled: true,
      );
      await tester.pump(const Duration(milliseconds: 60));
      final previous = notifications;
      history.dispose();
      results.last.completeError(const FormatException('late error'));
      await tester.pump();
      expect(notifications, previous);
      expect(history.retainedPoints, 0);
    },
  );
}
