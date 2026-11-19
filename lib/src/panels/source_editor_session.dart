import 'source_documents.dart';
import 'source_highlighter.dart';
import 'source_navigation_history.dart';
import 'source_references.dart';
import 'source_search_controller.dart';

/// Owns document work that can outlive the current tab or source root.
class SourceEditorSession<T extends Object> {
  final documents = SourceDocuments();
  final highlighter = SourceHighlighter();
  final navigation = SourceNavigationHistory<T>();
  late final search = SourceSearchController(documents);
  late final references = SourceReferencesController(documents);
  int _loadGeneration = 0;

  int get loadGeneration => _loadGeneration;
  int beginLoad() => ++_loadGeneration;

  Future<PreparedSourceText> readHighlighted(
    String path, {
    required String sourceRoot,
    String? localPath,
  }) async {
    final source = await documents.read(
      path,
      sourceRoot: sourceRoot,
      localPath: localPath,
    );
    return highlighter.prepare(source, path: path);
  }

  void invalidate({bool clearNavigation = false}) {
    _loadGeneration++;
    documents.clear();
    references.cancel();
    search.cancel();
    search.invalidateIndex();
    if (clearNavigation) navigation.clear();
  }

  void dispose() {
    _loadGeneration++;
    references.dispose();
    search.dispose();
  }
}
