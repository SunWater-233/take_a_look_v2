import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/panels/source_documents.dart';
import 'package:take_a_look_v2/src/panels/source_references.dart';
import 'package:take_a_look_v2/src/panels/source_search.dart';
import 'package:take_a_look_v2/src/panels/source_search_controller.dart';

void main() {
  final projectRoot = Platform.environment['TAL_REFERENCE_SOURCE_ROOT'];
  final projectSymbol = Platform.environment['TAL_REFERENCE_SYMBOL'];
  test(
    'reference lookup works across an actual source project',
    () async {
      final documents = SourceDocuments();
      final index = SourceSearchController(documents);
      final references = SourceReferencesController(documents);
      addTearDown(index.dispose);
      addTearDown(references.dispose);
      final states = <SourceReferenceResults>[];
      await references.search(
        projectSymbol!,
        sourceRoot: projectRoot!,
        currentPath:
            Platform.environment['TAL_REFERENCE_CURRENT_FILE'] ??
            '$projectRoot/main.c',
        getFiles: () => index.files(sourcePaths: [], sourceRoot: projectRoot),
        publish: states.add,
      );
      expect(states.last.searching, isFalse);
      expect(states.last.locations, isNotEmpty);
      final expectedCount = int.tryParse(
        Platform.environment['TAL_REFERENCE_EXPECTED_COUNT'] ?? '',
      );
      if (expectedCount != null) {
        expect(states.last.locations.length, expectedCount);
      }
      expect(
        states.last.locations.every(
          (location) =>
              location.preview.substring(
                location.column - 1,
                location.column - 1 + location.length,
              ) ==
              projectSymbol,
        ),
        isTrue,
      );
    },
    skip: projectRoot == null || projectSymbol == null
        ? 'Optional source-project integration fixture.'
        : false,
  );

  test('references match whole identifiers and preserve each occurrence', () {
    final matches = scanSourceReferences(
      'int gain;\r\n  gain += gain; gain_extra = GAIN;\r\n',
      'gain',
    );
    expect(matches.map((match) => (match.line, match.column)), [
      (1, 5),
      (2, 3),
      (2, 11),
    ]);
    expect(matches.last.preview, '  gain += gain; gain_extra = GAIN;');
    expect(matches.every((match) => match.length == 4), isTrue);
  });

  test(
    'references ignore strings, comments, includes and C++ raw literals',
    () {
      const text = r'''
#include <gain.h>
// gain
/* gain
gain */ gain;
const char *message = "gain \" gain";
const char *raw = u8R"tag(gain
// gain)tag";
char letter = 'g'; gain;
''';
      final matches = scanSourceReferences(text, 'gain');
      expect(matches.map((match) => match.line), [4, 8]);
      expect(matches.map((match) => match.preview.trim()), [
        'gain */ gain;',
        "char letter = 'g'; gain;",
      ]);
    },
  );

  test(
    'reference search deduplicates local/debug aliases and skips binary files',
    () async {
      final root = await Directory.systemTemp.createTemp('tal_references_');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/motor.c');
      await file.writeAsString('int gain;\nvoid step(void) { gain++; }\n');
      final documents = SourceDocuments();
      final references = SourceReferencesController(documents);
      addTearDown(references.dispose);
      final states = <SourceReferenceResults>[];
      final directoryName = root.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      await references.search(
        'gain',
        sourceRoot: root.path,
        currentPath: file.path,
        getFiles: () async => [
          SourceSearchFile(path: file.path),
          SourceSearchFile(
            path: 'Z:/build/motor.c',
            localPath: '${root.path}/../$directoryName/motor.c',
            searchContents: true,
          ),
          SourceSearchFile(path: '${root.path}/not_readable.c'),
          SourceSearchFile(path: '${root.path}/motor.o'),
        ],
        publish: states.add,
      );
      expect(states.last.searching, isFalse);
      expect(states.last.locations.map((match) => match.line), [1, 2]);
      expect(
        states.last.locations.every(
          (match) => match.path == 'Z:/build/motor.c',
        ),
        isTrue,
      );
      expect(states.last.unreadableFiles, 1);
    },
  );

  test('closing cancels work waiting for the source file index', () async {
    final files = Completer<List<SourceSearchFile>>();
    final references = SourceReferencesController(SourceDocuments());
    addTearDown(references.dispose);
    final states = <SourceReferenceResults>[];
    final search = references.search(
      'gain',
      sourceRoot: '',
      currentPath: 'motor.c',
      getFiles: () => files.future,
      publish: states.add,
    );
    references.cancel();
    files.complete([]);
    await search;
    expect(states, isEmpty);
  });

  test('reference limits explicitly report truncation', () async {
    final root = await Directory.systemTemp.createTemp('tal_reference_limit_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/motor.c');
    await file.writeAsString(List.filled(2020, 'gain;').join('\n'));
    final references = SourceReferencesController(SourceDocuments());
    addTearDown(references.dispose);
    final states = <SourceReferenceResults>[];
    await references.search(
      'gain',
      sourceRoot: root.path,
      currentPath: file.path,
      getFiles: () async => [SourceSearchFile(path: file.path)],
      publish: states.add,
    );
    expect(
      states.last.locations.length,
      SourceReferencesController.resultLimit,
    );
    expect(states.last.truncated, isTrue);
    expect(states.last.searching, isFalse);
  });
}
