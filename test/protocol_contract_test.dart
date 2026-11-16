import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';

void main() {
  test('Dart protocol enums match the shared backend manifest', () async {
    final manifest =
        jsonDecode(await File('backend/protocol_manifest.json').readAsString())
            as Map<String, dynamic>;
    expect(manifest['version'], 3);
    expect((manifest['methods'] as List).toSet(), {
      for (final method in BackendMethod.values) method.wireName,
    });
    expect((manifest['events'] as List).toSet(), {
      for (final event in BackendEventType.values) event.wireName,
      'sampleSchema',
    });
  });
}
