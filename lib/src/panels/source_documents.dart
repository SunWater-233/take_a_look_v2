import 'dart:io';
import 'source_search.dart';

/// Owns filesystem reads and root indexes; UI generations control presentation.
class SourceDocuments {
  final Map<String, String> resolvedPaths = {};
  final Map<String, Future<SourceSearchText>> _documents = {};
  final Map<String, Future<Map<String, List<String>>>> _indexes = {};

  Future<SourceSearchText> read(
    String path, {
    required String sourceRoot,
    String? localPath,
  }) => _documents.putIfAbsent(_pathKey(path), () async {
    final sourcePath = localPath ?? await resolve(path, sourceRoot);
    return SourceSearchText(await File(sourcePath).readAsString());
  });
  Future<Map<String, List<String>>> indexRoot(String root) =>
      _indexes.putIfAbsent(root, () => _buildIndex(root));
  void invalidate(String path) => _documents.remove(_pathKey(path));
  void clearIndex() => _indexes.clear();
  void clear() {
    _documents.clear();
    resolvedPaths.clear();
    clearIndex();
  }

  Future<String> resolve(String debugPath, String sourceRoot) async {
    if (await File(debugPath).exists()) return debugPath;
    if (sourceRoot.isEmpty) return debugPath;

    final cacheKey = _pathKey(debugPath);
    final cached = resolvedPaths[cacheKey];
    if (cached != null && await File(cached).exists()) return cached;

    final normalized = debugPath.replaceAll('\\', '/');
    final isAbsolute =
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
    if (!isAbsolute) {
      final direct = File(
        '$sourceRoot${Platform.pathSeparator}${normalized.replaceAll('/', Platform.pathSeparator)}',
      );
      if (await direct.exists()) {
        resolvedPaths[cacheKey] = direct.path;
        return direct.path;
      }
    }

    final targetName = _basename(debugPath).toLowerCase();
    File? bestMatch;
    var bestScore = -1;
    final index = await indexRoot(sourceRoot);
    for (final path in index[targetName] ?? const <String>[]) {
      final score = sourcePathSuffixLength(debugPath, path);
      if (score > bestScore) {
        bestMatch = File(path);
        bestScore = score;
      }
    }
    if (bestMatch != null) {
      resolvedPaths[cacheKey] = bestMatch.path;
      return bestMatch.path;
    }
    return debugPath;
  }

  Future<Map<String, List<String>>> _buildIndex(String sourceRoot) async {
    final index = <String, List<String>>{};
    try {
      await for (final entity in Directory(
        sourceRoot,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        index
            .putIfAbsent(_basename(entity.path).toLowerCase(), () => <String>[])
            .add(entity.path);
      }
    } on FileSystemException {
      return const <String, List<String>>{};
    }
    return index;
  }
}

String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();
String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

int sourcePathSuffixLength(String left, String right) {
  final leftParts = left
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .map((part) => part.toLowerCase())
      .toList();
  final rightParts = right
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .map((part) => part.toLowerCase())
      .toList();
  var score = 0;
  while (score < leftParts.length && score < rightParts.length) {
    if (leftParts[leftParts.length - 1 - score] !=
        rightParts[rightParts.length - 1 - score]) {
      break;
    }
    score += 1;
  }
  return score;
}
