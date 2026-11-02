import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showWatchWidget(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scroll = tester
        .widget<ListView>(find.byKey(const ValueKey('compact-watch-list')))
        .controller!;
    scroll.jumpTo(0);
    await tester.pump();
    while (finder.evaluate().isEmpty &&
        scroll.offset < scroll.position.maxScrollExtent) {
      scroll.jumpTo(
        (scroll.offset + 80).clamp(0, scroll.position.maxScrollExtent),
      );
      await tester.pump();
    }
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

Future<Finder> editWatchValue(
  WidgetTester tester,
  String key, {
  bool pinned = false,
}) async {
  final prefix = pinned ? 'pinned' : 'compact';
  final value = find.byKey(ValueKey('$prefix-watch-value-$key'));
  await tester.pump(const Duration(milliseconds: 320));
  await showWatchWidget(tester, value);
  await tester.tap(value);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(value);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump();
  return find.byKey(ValueKey('$prefix-watch-input-$key'));
}
