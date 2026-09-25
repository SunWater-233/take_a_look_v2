/// A cached filename candidate. Path normalization and file classification are
/// performed once when the file list changes, rather than on every keystroke.
class SourceSearchFile {
  SourceSearchFile({
    required this.path,
    String? localPath,
    String sourceRoot = '',
    this.searchContents = false,
  }) : localPath = localPath ?? path,
       key = _normalize(localPath ?? path),
       debugKey = _normalize(path),
       name = _normalize(path).split('/').last,
       searchPath = _relativePath(localPath ?? path, sourceRoot),
       priority = _filePriority(path);

  final String path;
  final String localPath;
  final String key;
  final String debugKey;
  final String name;
  final String searchPath;
  final int priority;
  final bool searchContents;

  bool get isBinaryArtifact => _binaryArtifactPattern.hasMatch(name);
}

/// C sources and headers precede other files; build outputs remain searchable
/// at the end. Within each group, literal matches precede fuzzy abbreviations.
List<SourceSearchFile> searchSourceFiles(
  Iterable<SourceSearchFile> files,
  String query, {
  int limit = 1000,
}) {
  final normalized = _normalize(query.trim());
  if (normalized.isEmpty || limit <= 0) return const [];
  final abbreviation = normalized.replaceAll(_whitespace, '');
  final matches = <({SourceSearchFile file, int rank, int penalty})>[];
  for (final file in files) {
    final score = _matchFile(file, normalized, abbreviation);
    if (score == null) continue;
    matches.add((file: file, rank: score.$1, penalty: score.$2));
  }
  matches.sort((left, right) {
    var order = left.file.priority.compareTo(right.file.priority);
    if (order != 0) return order;
    order = left.rank.compareTo(right.rank);
    if (order != 0) return order;
    order = left.penalty.compareTo(right.penalty);
    if (order != 0) return order;
    order = left.file.name.compareTo(right.file.name);
    return order != 0 ? order : left.file.key.compareTo(right.file.key);
  });
  return matches.take(limit).map((match) => match.file).toList();
}

(int, int)? _matchFile(
  SourceSearchFile file,
  String query,
  String abbreviation,
) {
  if (file.name == query) return (0, 0);
  if (file.name.startsWith(query)) return (1, 0);
  final nameOffset = file.name.indexOf(query);
  if (nameOffset >= 0) return (2, nameOffset);
  if (file.searchPath.contains(query) ||
      file.key.contains(query) ||
      file.debugKey.contains(query)) {
    return (3, 0);
  }
  final namePenalty = _subsequencePenalty(file.name, abbreviation);
  if (namePenalty != null) return (4, namePenalty);
  final pathPenalty = _subsequencePenalty(file.searchPath, abbreviation);
  return pathPenalty == null ? null : (5, pathPenalty);
}

int? _subsequencePenalty(String text, String query) {
  if (query.isEmpty || query.length > text.length) return null;
  var offset = 0;
  var penalty = 0;
  for (var index = 0; index < query.length; index += 1) {
    final match = text.indexOf(query[index], offset);
    if (match < 0) return null;
    penalty += match - offset;
    if (match > 0 && match != offset && !'/_-. '.contains(text[match - 1])) {
      penalty += 4;
    }
    offset = match + 1;
  }
  return penalty;
}

/// Lazily prepares case-folded text and lines once, sharing them across queries.
/// Content search remains literal so code punctuation and line locations retain
/// the same meaning as before filename fuzzy search was added.
class SourceSearchText {
  SourceSearchText(this.text);

  final String text;
  late final String _normalized = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  late final String _folded = _normalized.toLowerCase();
  late final List<String> _lines = _normalized.split('\n');
  late final List<String> _foldedLines = _folded.split('\n');

  Iterable<({int line, int column, String preview})> search(
    String query, {
    int limit = 1000,
  }) sync* {
    final foldedQuery = query.toLowerCase();
    if (foldedQuery.isEmpty || limit <= 0 || !_folded.contains(foldedQuery)) {
      return;
    }
    var count = 0;
    for (var index = 0; index < _foldedLines.length; index += 1) {
      final column = _foldedLines[index].indexOf(foldedQuery);
      if (column < 0) continue;
      yield (
        line: index + 1,
        column: column + 1,
        preview: _lines[index].trim(),
      );
      if (++count >= limit) return;
    }
  }
}

String _normalize(String path) => path.replaceAll('\\', '/').toLowerCase();

String _relativePath(String path, String root) {
  final normalized = _normalize(path);
  final prefix = '${_normalize(root).replaceFirst(RegExp(r'/+$'), '')}/';
  return root.isNotEmpty && normalized.startsWith(prefix)
      ? normalized.substring(prefix.length)
      : normalized;
}

int _filePriority(String path) {
  final name = _normalize(path).split('/').last;
  if (name.endsWith('.c') || name.endsWith('.h')) return 0;
  return _buildArtifactPattern.hasMatch(name) ? 2 : 1;
}

final _whitespace = RegExp(r'\s+');
final _buildArtifactPattern = RegExp(
  r'\.(?:o|obj|a|lib|so(?:\.\d+)*|dll|dylib|elf|axf|out|exe|bin|hex|uf2|'
  r'map|lst|list|d|dep|su|gcno|gcda|gch|pch|pdb|ilk|exp)$',
);
final _binaryArtifactPattern = RegExp(
  r'\.(?:o|obj|a|lib|so(?:\.\d+)*|dll|dylib|elf|axf|out|exe|bin|uf2|'
  r'gcno|gcda|gch|pch|pdb|ilk|exp)$',
);
