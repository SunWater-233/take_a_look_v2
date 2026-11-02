import 'dart:io';

import 'package:flutter/foundation.dart';

import 'source_documents.dart';
import 'source_search.dart';

class SourceCodeLocation {
  const SourceCodeLocation({
    required this.path,
    required this.line,
    this.column = 1,
    this.length = 0,
    this.preview = '',
    this.label = '',
  });

  final String path;
  final int line;
  final int column;
  final int length;
  final String preview;
  final String label;

  Object get key => (path, line, column);
}

typedef SourceReferenceMatch = ({
  int line,
  int column,
  int length,
  String preview,
});

/// Exact C/C++ identifier occurrences, excluding comments and string literals.
/// These are name matches, not compiler-resolved C++ overload/member references.
List<SourceReferenceMatch> scanSourceReferences(
  String text,
  String name, {
  int limit = 2001,
}) {
  if (name.isEmpty || !text.contains(name) || limit <= 0) return const [];
  final source = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final matches = <SourceReferenceMatch>[];
  var index = 0;
  var line = 1;
  var lineStart = 0;
  void advance(int end) {
    while (index < end) {
      if (source.codeUnitAt(index++) == 10) {
        line++;
        lineStart = index;
      }
    }
  }

  bool identifierPart(int code) =>
      code >= 65 && code <= 90 ||
      code >= 97 && code <= 122 ||
      code >= 48 && code <= 57 ||
      code == 95;
  while (index < source.length && matches.length < limit) {
    if (source.startsWith('//', index)) {
      final end = source.indexOf('\n', index + 2);
      advance(end < 0 ? source.length : end);
      continue;
    }
    if (source.startsWith('/*', index)) {
      final end = source.indexOf('*/', index + 2);
      advance(end < 0 ? source.length : end + 2);
      continue;
    }
    final code = source.codeUnitAt(index);
    if (code == 35 && source.substring(lineStart, index).trim().isEmpty) {
      final end = source.indexOf('\n', index);
      final directive = source.substring(index, end < 0 ? source.length : end);
      if (RegExp(r'^#\s*(include|include_next|import)\b').hasMatch(directive)) {
        advance(end < 0 ? source.length : end);
        continue;
      }
    }
    if (code == 34 || code == 39) {
      var end = index + 1;
      while (end < source.length) {
        if (source.codeUnitAt(end) == 92) {
          end = (end + 2).clamp(0, source.length);
        } else if (source.codeUnitAt(end++) == code) {
          break;
        }
      }
      advance(end);
      continue;
    }
    if (identifierPart(code)) {
      final start = index;
      var end = index + 1;
      while (end < source.length && identifierPart(source.codeUnitAt(end))) {
        end++;
      }
      final word = source.substring(start, end);
      if (const {'R', 'u8R', 'uR', 'UR', 'LR'}.contains(word) &&
          end < source.length &&
          source[end] == '"') {
        final opening = source.indexOf('(', end + 1);
        if (opening >= 0 && opening - end <= 17) {
          final delimiter = source.substring(end + 1, opening);
          final closing = ')$delimiter"';
          final rawEnd = source.indexOf(closing, opening + 1);
          advance(rawEnd < 0 ? source.length : rawEnd + closing.length);
          continue;
        }
      }
      if (word == name) {
        final lineEnd = source.indexOf('\n', end);
        matches.add((
          line: line,
          column: start - lineStart + 1,
          length: name.length,
          preview: source.substring(
            lineStart,
            lineEnd < 0 ? source.length : lineEnd,
          ),
        ));
      }
      advance(end);
    } else {
      advance(index + 1);
    }
  }
  return matches;
}

class SourceReferenceResults {
  const SourceReferenceResults({
    required this.locations,
    required this.searching,
    this.truncated = false,
    this.unreadableFiles = 0,
  });
  final List<SourceCodeLocation> locations;
  final bool searching;
  final bool truncated;
  final int unreadableFiles;
}

class SourceReferencesController {
  SourceReferencesController(this.documents);
  final SourceDocuments documents;
  static const resultLimit = 2000;
  int _generation = 0;
  bool _disposed = false;

  void cancel() => _generation++;
  void dispose() {
    _disposed = true;
    cancel();
  }

  Future<void> search(
    String name, {
    required String sourceRoot,
    required String currentPath,
    required Future<List<SourceSearchFile>> Function() getFiles,
    required void Function(SourceReferenceResults results) publish,
  }) async {
    final generation = ++_generation;
    bool active() => !_disposed && generation == _generation;
    final filesByKey = <String, SourceSearchFile>{};
    for (final file in await getFiles()) {
      if (!active()) return;
      if (!RegExp(
        r'\.(c|h|cpp|hpp|cc|hh|cxx|hxx|inc|ipp|tpp|ino)$',
        caseSensitive: false,
      ).hasMatch(file.path)) {
        continue;
      }
      final key = _localKey(file.localPath);
      if (!filesByKey.containsKey(key) || file.searchContents) {
        filesByKey[key] = file;
      }
    }
    final currentKey = _localKey(
      await documents.resolve(currentPath, sourceRoot),
    );
    if (!active()) return;
    final files = filesByKey.values.toList()
      ..sort((a, b) {
        final current = (_localKey(a.localPath) == currentKey ? 0 : 1)
            .compareTo(_localKey(b.localPath) == currentKey ? 0 : 1);
        return current != 0 ? current : a.key.compareTo(b.key);
      });
    final locations = <SourceCodeLocation>[];
    var unreadable = 0;
    for (var start = 0; start < files.length; start += 8) {
      if (!active()) return;
      final batchFiles = files.skip(start).take(8).toList();
      final texts = await Future.wait(
        batchFiles.map((file) async {
          try {
            return (await documents.read(
              file.path,
              sourceRoot: sourceRoot,
              localPath: file.localPath,
            )).text;
          } on Object {
            return null;
          }
        }),
      );
      if (!active()) return;
      final batch = <({String path, String text})>[];
      for (var i = 0; i < texts.length; i++) {
        final text = texts[i];
        if (text == null) {
          unreadable++;
        } else if (text.contains(name)) {
          batch.add((path: batchFiles[i].path, text: text));
        }
      }
      final request = (
        name: name,
        files: batch,
        limit: resultLimit - locations.length + 1,
      );
      final matches =
          batch.fold<int>(0, (size, file) => size + file.text.length) >
              128 * 1024
          ? await compute(_scanBatch, request)
          : _scanBatch(request);
      if (!active()) return;
      locations.addAll(matches);
      final truncated = locations.length > resultLimit;
      if (truncated) locations.removeRange(resultLimit, locations.length);
      final done = truncated || start + 8 >= files.length;
      publish(
        SourceReferenceResults(
          locations: List.of(locations),
          searching: !done,
          truncated: truncated,
          unreadableFiles: unreadable,
        ),
      );
      if (done) return;
      await Future<void>.delayed(Duration.zero);
    }
    if (active()) {
      publish(
        SourceReferenceResults(
          locations: locations,
          searching: false,
          unreadableFiles: unreadable,
        ),
      );
    }
  }
}

typedef _ScanRequest = ({
  String name,
  List<({String path, String text})> files,
  int limit,
});

List<SourceCodeLocation> _scanBatch(_ScanRequest request) {
  final result = <SourceCodeLocation>[];
  for (final file in request.files) {
    for (final match in scanSourceReferences(
      file.text,
      request.name,
      limit: request.limit - result.length,
    )) {
      result.add(
        SourceCodeLocation(
          path: file.path,
          line: match.line,
          column: match.column,
          length: match.length,
          preview: match.preview,
        ),
      );
    }
    if (result.length >= request.limit) break;
  }
  return result;
}

String _localKey(String path) =>
    File(path).absolute.uri.normalizePath().toString().toLowerCase();
