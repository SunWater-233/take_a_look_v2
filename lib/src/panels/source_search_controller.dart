import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/source_definition.dart';
import 'source_documents.dart';
import 'source_search.dart';

/// Cached indexing and cancellable batched search, independent of panel lifecycle.
class SourceSearchController {
  SourceSearchController(this.documents);

  final SourceDocuments documents;
  static const _maxSearchResults = 1000;
  static const _searchReadBatchSize = 8;
  static final _binaryControlCharacters = RegExp(r'[\x00-\x08\x0E-\x1F\x7F]');
  List<String> _searchIndexPaths = const [];
  String _searchIndexRoot = '';
  Future<List<SourceSearchFile>>? _searchFileIndexFuture;
  int _searchIndexGeneration = 0;
  int _searchGeneration = 0;
  Timer? _debounce;
  bool _disposed = false;

  void cancel() {
    _debounce?.cancel();
    _debounce = null;
    _searchGeneration++;
  }

  void invalidateIndex() {
    _searchFileIndexFuture = null;
    _searchIndexGeneration++;
  }

  void queue(
    String query, {
    SourceSearchMode mode = SourceSearchMode.source,
    Iterable<SourceDefinition> definitions = const [],
    required Future<List<SourceSearchFile>> Function() getFiles,
    required Future<SourceSearchText?> Function(SourceSearchFile) readDocument,
    required Future<void> Function() beforeContents,
    required void Function(List<SourceSearchResult>, bool searching) publish,
    bool immediate = false,
  }) {
    cancel();
    if (_disposed || query.trim().isEmpty) return;
    final generation = _searchGeneration;
    void run() {
      bool isCurrent() => !_disposed && generation == _searchGeneration;
      void publishCurrent(List<SourceSearchResult> results, bool searching) {
        if (isCurrent()) publish(results, searching);
      }

      unawaited(
        mode == SourceSearchMode.files
            ? _searchEditableFiles(query, getFiles, isCurrent, publishCurrent)
            : _searchAcrossFiles(
                query,
                definitions: definitions,
                getFiles: getFiles,
                readDocument: readDocument,
                beforeContents: beforeContents,
                isCurrent: isCurrent,
                publish: publishCurrent,
              ),
      );
    }

    if (immediate) {
      run();
    } else {
      _debounce = Timer(const Duration(milliseconds: 100), run);
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
    invalidateIndex();
  }

  Future<List<SourceSearchFile>> files({
    required Iterable<String> sourcePaths,
    required String sourceRoot,
  }) {
    if (_disposed) return Future.value(const []);
    final pathsByKey = <String, String>{};
    for (final path in sourcePaths) {
      pathsByKey.putIfAbsent(_pathKey(path), () => path);
    }
    final paths = pathsByKey.values.toList();
    if (_searchFileIndexFuture != null &&
        _searchIndexRoot == sourceRoot &&
        listEquals(paths, _searchIndexPaths)) {
      return _searchFileIndexFuture!;
    }
    _searchIndexPaths = paths;
    _searchIndexRoot = sourceRoot;
    final indexGeneration = ++_searchIndexGeneration;
    final root = sourceRoot;
    final rootIndex = root.isEmpty
        ? Future.value(const <String, List<String>>{})
        : documents.indexRoot(root);
    return _searchFileIndexFuture = _buildSearchFileIndex(
      paths,
      root,
      rootIndex,
      Map.of(documents.resolvedPaths),
      indexGeneration,
    );
  }

  Future<List<SourceSearchFile>> _buildSearchFileIndex(
    List<String> paths,
    String root,
    Future<Map<String, List<String>>> rootIndexFuture,
    Map<String, String> resolvedPaths,
    int generation,
  ) async {
    final rootIndex = await rootIndexFuture;
    if (_disposed || generation != _searchIndexGeneration) return const [];
    final filesByKey = <String, SourceSearchFile>{};
    for (final path in rootIndex.values.expand((paths) => paths)) {
      final file = SourceSearchFile(path: path, sourceRoot: root);
      filesByKey[file.key] = file;
    }
    for (var start = 0; start < paths.length; start += _searchReadBatchSize) {
      if (_disposed || generation != _searchIndexGeneration) return const [];
      final batch = await Future.wait(
        paths.skip(start).take(_searchReadBatchSize).map((path) async {
          final key = _pathKey(path);
          var localPath = resolvedPaths[key] ?? filesByKey[key]?.localPath;
          if (localPath == null && root.isNotEmpty) {
            localPath = filesByKey[_pathKey('$root/$path')]?.localPath;
            final candidates = rootIndex[_basename(path).toLowerCase()];
            if (localPath == null && candidates != null) {
              // Only ambiguous build-machine aliases need a filesystem probe,
              // and only when constructing the index, never for each query.
              if (!await File(path).exists()) {
                var bestScore = -1;
                for (final candidate in candidates) {
                  final score = sourcePathSuffixLength(path, candidate);
                  if (score > bestScore) {
                    bestScore = score;
                    localPath = candidate;
                  }
                }
              }
            }
          }
          return SourceSearchFile(
            path: path,
            localPath: localPath,
            sourceRoot: root,
            searchContents: true,
          );
        }),
      );
      for (final file in batch) {
        // Keep a single result for a local file and its DWARF alias, retaining
        // the debug path for opening the source and setting breakpoints.
        if (filesByKey[file.key]?.searchContents != true) {
          filesByKey[file.key] = file;
        }
      }
    }
    return filesByKey.values.toList()..sort((left, right) {
      final priority = left.priority.compareTo(right.priority);
      return priority != 0 ? priority : left.key.compareTo(right.key);
    });
  }

  Future<void> _searchEditableFiles(
    String query,
    Future<List<SourceSearchFile>> Function() getFiles,
    bool Function() isCurrent,
    void Function(List<SourceSearchResult>, bool searching) publish,
  ) async {
    final files = await getFiles();
    if (!isCurrent()) return;
    final matches = searchSourceFiles(
      files.where((file) => !file.isBinaryArtifact),
      query,
      limit: files.length,
    );
    final results = <SourceSearchResult>[];
    for (var start = 0; start < matches.length; start += _searchReadBatchSize) {
      final batch = matches.skip(start).take(_searchReadBatchSize);
      final editable = await Future.wait(
        batch.map((file) => _isEditableFile(file.localPath, isCurrent)),
      );
      if (!isCurrent()) return;
      for (final (index, file) in batch.indexed) {
        if (editable[index]) {
          results.add(SourceSearchResult.file(file));
          if (results.length == _maxSearchResults) break;
        }
      }
      if (results.length == _maxSearchResults) break;
      if (start + _searchReadBatchSize < matches.length) {
        publish(List.of(results), true);
      }
    }
    publish(results, false);
  }

  Future<bool> _isEditableFile(String path, bool Function() isCurrent) async {
    try {
      // Use the same strict UTF-8 decoding as the source viewer. Streaming
      // keeps large files out of the source document cache until opened.
      await for (final chunk in File(path).openRead().transform(utf8.decoder)) {
        if (!isCurrent() || _binaryControlCharacters.hasMatch(chunk)) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<void> _searchAcrossFiles(
    String query, {
    required Iterable<SourceDefinition> definitions,
    required Future<List<SourceSearchFile>> Function() getFiles,
    required Future<SourceSearchText?> Function(SourceSearchFile) readDocument,
    required Future<void> Function() beforeContents,
    required bool Function() isCurrent,
    required void Function(List<SourceSearchResult>, bool searching) publish,
  }) async {
    final variables = searchSourceVariables(
      definitions,
      query,
      limit: _maxSearchResults,
    ).map(SourceSearchResult.variable).toList();
    if (variables.length == _maxSearchResults) {
      publish(variables, false);
      return;
    }
    if (variables.isNotEmpty) publish(variables, true);

    final files = await getFiles();
    if (!isCurrent()) return;
    final fileResults = List.generate(3, (_) => <SourceSearchResult>[]);
    for (final file in searchSourceFiles(
      files,
      query,
      limit: _maxSearchResults - variables.length,
    )) {
      fileResults[file.priority].add(SourceSearchResult.file(file));
    }
    publish([...variables, ...fileResults.expand((group) => group)], true);
    // Render filename matches before reading and searching file contents.
    await beforeContents();
    if (!isCurrent()) return;
    final results = [...variables];
    for (var priority = 0; priority < fileResults.length; priority += 1) {
      results.addAll(
        fileResults[priority].take(_maxSearchResults - results.length),
      );
      if (results.length >= _maxSearchResults) break;
      final contentFiles = files
          .where(
            (file) =>
                file.priority == priority &&
                file.searchContents &&
                !file.isBinaryArtifact,
          )
          .toList();
      for (
        var start = 0;
        start < contentFiles.length;
        start += _searchReadBatchSize
      ) {
        if (!isCurrent()) return;
        final batch = contentFiles
            .skip(start)
            .take(_searchReadBatchSize)
            .toList();
        final documents = await Future.wait(batch.map(readDocument));
        if (!isCurrent()) return;
        for (var index = 0; index < batch.length; index += 1) {
          final document = documents[index];
          if (document == null) continue;
          for (final match in document.search(
            query,
            limit: _maxSearchResults - results.length,
          )) {
            results.add(
              SourceSearchResult(
                path: batch[index].path,
                line: match.line,
                column: match.column,
                preview: match.preview,
              ),
            );
          }
          if (results.length >= _maxSearchResults) break;
        }
        publish(
          [
            ...results,
            ...fileResults.skip(priority + 1).expand((group) => group),
          ].take(_maxSearchResults).toList(),
          true,
        );
        if (results.length >= _maxSearchResults) break;
        // Let new keystrokes cancel an obsolete content scan between batches.
        if (start + batch.length < contentFiles.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (results.length >= _maxSearchResults) break;
    }
    publish(results, false);
  }
}

class SourceSearchResult {
  const SourceSearchResult({
    required this.path,
    required this.line,
    required this.column,
    required this.preview,
  }) : localPath = null,
       variableName = null;

  SourceSearchResult.file(SourceSearchFile file)
    : path = file.path,
      localPath = file.localPath,
      preview = file.localPath,
      line = null,
      column = null,
      variableName = null;

  SourceSearchResult.variable(SourceDefinition definition)
    : path = definition.path,
      localPath = null,
      line = definition.line,
      column = null,
      preview = '${definition.path}:${definition.line}',
      variableName = definition.qualifiedName;

  final String path;
  final String? localPath;
  final int? line;
  final int? column;
  final String preview;
  final String? variableName;

  bool get isFile => line == null;
}

String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();
String _basename(String path) => path.replaceAll('\\', '/').split('/').last;
