import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/panels/source_navigation_history.dart';

void main() {
  test(
    'back/forward preserve locations and a new jump drops the forward branch',
    () {
      final history = SourceNavigationHistory<String>(limit: 3);
      for (final origin in ['old', 'a', 'b', 'c']) {
        history.record(origin);
      }
      expect(history.travel(back: true, current: 'd'), 'c');
      expect(history.travel(back: true, current: 'c'), 'b');
      expect(history.travel(back: false, current: 'b'), 'c');
      history.record('c');
      expect(history.canGoForward, isFalse);
      expect(history.travel(back: false, current: 'new'), isNull);
      expect(history.travel(back: true, current: 'new'), 'c');
      expect(history.travel(back: true, current: 'c'), 'b');
      expect(history.travel(back: true, current: 'b'), 'a');
      expect(history.travel(back: true, current: 'a'), isNull);
      history.clear();
      expect(history.canGoBack, isFalse);
      expect(history.canGoForward, isFalse);
    },
  );
}
