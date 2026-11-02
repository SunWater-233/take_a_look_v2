import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/panels/source_documents.dart';
import 'package:take_a_look_v2/src/panels/source_search.dart';
import 'package:take_a_look_v2/src/panels/source_search_controller.dart';

void main() {
  test(
    'new query suppresses an older scan waiting for its file index',
    () async {
      final search = SourceSearchController(SourceDocuments());
      addTearDown(search.dispose);
      final oldIndex = Completer<List<SourceSearchFile>>();
      final finished = Completer<void>();
      final published = <String>[];
      search.queue(
        'old',
        immediate: true,
        getFiles: () => oldIndex.future,
        readDocument: (_) async => SourceSearchText('old contents'),
        beforeContents: () async {},
        publish: (_, _) => published.add('old'),
      );
      search.queue(
        'new',
        immediate: true,
        getFiles: () async => [SourceSearchFile(path: 'new.c')],
        readDocument: (_) async => null,
        beforeContents: () async {},
        publish: (results, searching) {
          published.addAll(results.map((r) => r.path));
          if (!searching) finished.complete();
        },
      );
      await finished.future;
      oldIndex.complete([SourceSearchFile(path: 'old.c')]);
      await Future<void>.delayed(Duration.zero);
      expect(published, isNotEmpty);
      expect(published, everyElement('new.c'));
    },
  );

  test('disposal suppresses results from an in-flight content read', () async {
    final search = SourceSearchController(SourceDocuments());
    final reading = Completer<void>();
    final document = Completer<SourceSearchText?>();
    var publications = 0;
    search.queue(
      'needle',
      immediate: true,
      getFiles: () async => [
        SourceSearchFile(path: 'file.c', searchContents: true),
      ],
      readDocument: (_) {
        reading.complete();
        return document.future;
      },
      beforeContents: () async {},
      publish: (_, _) => publications++,
    );
    await reading.future;
    search.dispose();
    final settled = publications;
    document.complete(SourceSearchText('needle'));
    await Future<void>.delayed(Duration.zero);
    expect(publications, settled);
  });
}
