/// A declaration site from the loaded firmware's DWARF information.
class SourceDefinition {
  const SourceDefinition({
    required this.name,
    required this.path,
    required this.line,
    required this.kind,
    this.scope = '',
    this.isDeclaration = false,
    this.isLocal = false,
  });

  final String name;
  final String path;
  final int line;
  final String kind;
  final String scope;
  final bool isDeclaration;
  final bool isLocal;

  String get qualifiedName => scope.isEmpty ? name : '$scope::$name';
  String get kindLabel => switch (kind) {
    'function' => '函数',
    'parameter' => '参数',
    'member' => '成员',
    _ => '变量',
  };

  factory SourceDefinition.fromJson(Map<String, dynamic> json) =>
      SourceDefinition(
        name: json['name'] as String,
        path: json['path'] as String,
        line: json['line'] as int,
        kind: json['kind'] as String,
        scope: json['scope'] as String? ?? '',
        isDeclaration: json['isDeclaration'] == true,
        isLocal: json['isLocal'] == true,
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'path': path,
    'line': line,
    'kind': kind,
    'scope': scope,
    'isDeclaration': isDeclaration,
    'isLocal': isLocal,
  };
}

/// Prefer definitions over declarations of the same qualified name. Distinct
/// scopes remain candidates: a name alone cannot resolve C++ overloads/members.
List<SourceDefinition> findSourceDefinitions(
  Iterable<SourceDefinition> definitions,
  String name, {
  required bool Function(String path) isCurrentFile,
}) {
  final candidates = definitions
      .where(
        (item) =>
            item.name == name &&
            item.line > 0 &&
            (!item.isLocal || isCurrentFile(item.path)),
      )
      .toList();
  final definedNames = candidates
      .where((item) => !item.isDeclaration)
      .map((item) => item.qualifiedName)
      .toSet();
  final unique = <String, SourceDefinition>{};
  for (final item in candidates) {
    if (item.isDeclaration && definedNames.contains(item.qualifiedName)) {
      continue;
    }
    final key =
        '${item.path.replaceAll('\\', '/').toLowerCase()}:${item.line}'
        ':${item.kind}:${item.qualifiedName}';
    unique.putIfAbsent(key, () => item);
  }
  return unique.values.toList()..sort((left, right) {
    final current = (isCurrentFile(left.path) ? 0 : 1).compareTo(
      isCurrentFile(right.path) ? 0 : 1,
    );
    if (current != 0) return current;
    final path = left.path.compareTo(right.path);
    return path != 0 ? path : left.line.compareTo(right.line);
  });
}
