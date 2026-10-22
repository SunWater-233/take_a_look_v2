import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Finder> editWatchValue(
  WidgetTester tester,
  String key, {
  bool pinned = false,
}) async {
  final prefix = pinned ? 'pinned' : 'compact';
  final value = find.byKey(ValueKey('$prefix-watch-value-$key'));
  await tester.pump(const Duration(milliseconds: 320));
  await tester.ensureVisible(value);
  await tester.tap(value);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(value);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump();
  return find.byKey(ValueKey('$prefix-watch-input-$key'));
}
