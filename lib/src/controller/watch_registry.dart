import 'dart:async';

import '../models/models.dart';

/// Owns watch membership, editor preferences and bounded deletion history.
/// Backend commands and UI notifications are handled by the controller.
class WatchRegistry {
  WatchRegistry({required this.onExpired, required this.onDiscard});

  final void Function() onExpired;
  final void Function(String key) onDiscard;
  final List<WatchItem> watches = [];
  final Map<String, String> drafts = {};
  final Set<String> expanded = {};
  final Set<String> removedKeys = {};
  String? selection;
  final List<List<DeletedWatch>> _deletions = [];
  final List<List<String>> _redos = [];

  bool get canUndo => _deletions.isNotEmpty;
  bool get canRedo => _redos.isNotEmpty;

  Iterable<WatchItem> get retained sync* {
    yield* watches;
    for (final batch in _deletions) {
      for (final entry in batch) {
        yield entry.watch;
      }
    }
  }

  Iterable<WatchItem> get acquiring sync* {
    yield* watches;
    for (final batch in _deletions) {
      for (final entry in batch) {
        if (entry._expiry != null) yield entry.watch;
      }
    }
  }

  void clearRedos() => _redos.clear();

  bool remove(
    Set<String> keys, {
    required bool samplingPaused,
    required String? highlightedKey,
  }) {
    final deleted = <DeletedWatch>[];
    for (final (index, watch) in watches.indexed) {
      final key = watch.symbol.key;
      if (!keys.contains(key)) continue;
      final entry = DeletedWatch(
        watch: watch,
        index: index,
        draft: drafts[key],
        expanded: expanded.contains(key),
        selected: selection == key,
        highlighted: highlightedKey == key,
      );
      if (!samplingPaused && watch.samplingEnabled) {
        entry._expiry = Timer(const Duration(seconds: 10), () {
          _discard(entry);
          onExpired();
        });
      }
      deleted.add(entry);
    }
    if (deleted.isEmpty) return false;
    _redos.clear();
    _deletions.add(deleted);
    removedKeys.addAll(deleted.map((entry) => entry.watch.symbol.key));
    while (_deletions.length > 50) {
      for (final entry in List.of(_deletions.first)) {
        _discard(entry);
      }
    }
    watches.removeWhere((watch) => keys.contains(watch.symbol.key));
    drafts.removeWhere((key, _) => keys.contains(key));
    expanded.removeAll(keys);
    if (keys.contains(selection)) selection = null;
    return true;
  }

  List<DeletedWatch> undo() {
    if (_deletions.isEmpty) return const [];
    final entries = _deletions.removeLast();
    _redos.add([for (final entry in entries) entry.watch.symbol.key]);
    for (final entry in entries) {
      entry._expiry?.cancel();
      entry._expiry = null;
      removedKeys.remove(entry.watch.symbol.key);
      restore(entry);
    }
    return entries;
  }

  bool redo({required bool samplingPaused, required String? highlightedKey}) {
    if (_redos.isEmpty) return false;
    final keys = _redos.removeLast();
    final remaining = List<List<String>>.of(_redos);
    final changed = remove(
      keys.toSet(),
      samplingPaused: samplingPaused,
      highlightedKey: highlightedKey,
    );
    _redos
      ..clear()
      ..addAll(remaining);
    return changed;
  }

  DeletedWatch? takeDeleted(String key) {
    for (final batch in List.of(_deletions)) {
      final entry = batch
          .where((item) => item.watch.symbol.key == key)
          .firstOrNull;
      if (entry == null) continue;
      entry._expiry?.cancel();
      entry._expiry = null;
      batch.remove(entry);
      if (batch.isEmpty) _deletions.remove(batch);
      return entry;
    }
    return null;
  }

  void restore(DeletedWatch entry, {int? index}) {
    final key = entry.watch.symbol.key;
    watches.insert(
      (index ?? entry.index).clamp(0, watches.length),
      entry.watch,
    );
    if (entry.draft != null) drafts[key] = entry.draft!;
    if (entry.expanded) expanded.add(key);
    if (entry.selected) selection = key;
  }

  void _discard(DeletedWatch entry) {
    entry._expiry?.cancel();
    entry._expiry = null;
    entry.watch.samples.clear();
    entry.watch.totalSampleCount = 0;
    onDiscard(entry.watch.symbol.key);
    for (final batch in _deletions) {
      batch.remove(entry);
    }
    _deletions.removeWhere((batch) => batch.isEmpty);
  }

  void clearHistory() {
    _redos.clear();
    for (final batch in List.of(_deletions)) {
      for (final entry in List.of(batch)) {
        _discard(entry);
      }
    }
  }
}

class DeletedWatch {
  DeletedWatch({
    required this.watch,
    required this.index,
    required this.draft,
    required this.expanded,
    required this.selected,
    required this.highlighted,
  });

  final WatchItem watch;
  final int index;
  final String? draft;
  final bool expanded;
  final bool selected;
  final bool highlighted;
  Timer? _expiry;
}
