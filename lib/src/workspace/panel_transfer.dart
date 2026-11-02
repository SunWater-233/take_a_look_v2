import 'panel_types.dart';

class NativePanelPayload {
  const NativePanelPayload({
    required this.windowId,
    required this.fromMainWindow,
    required this.groupId,
    required this.panel,
  });

  final String windowId;
  final bool fromMainWindow;
  final String groupId;
  final WorkspacePanelId panel;

  Map<String, Object?> toJson() => {
    'windowId': windowId,
    'fromMainWindow': fromMainWindow,
    'groupId': groupId,
    'panel': panel.name,
  };

  static NativePanelPayload? parse(Object? value) {
    if (value is! Map ||
        value['windowId'] is! String ||
        (value['windowId'] as String).isEmpty ||
        value['fromMainWindow'] is! bool ||
        value['groupId'] is! String ||
        value['panel'] is! String) {
      return null;
    }
    final panel = WorkspacePanelId.values
        .where((item) => item.name == value['panel'])
        .firstOrNull;
    return panel == null
        ? null
        : NativePanelPayload(
            windowId: value['windowId'] as String,
            fromMainWindow: value['fromMainWindow'] as bool,
            groupId: value['groupId'] as String,
            panel: panel,
          );
  }
}

/// A transfer names its destination explicitly. No desktop coordinates are
/// exchanged between engines on Wayland.
class NativePanelTransfer {
  const NativePanelTransfer({
    required this.source,
    required this.targetWindowId,
    required this.targetIsMainWindow,
    this.targetGroupId,
    this.insertionIndex,
    this.dockEdge,
  });

  final NativePanelPayload source;
  final String targetWindowId;
  final bool targetIsMainWindow;
  final String? targetGroupId;
  final int? insertionIndex;
  final WorkspaceDockEdge? dockEdge;

  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    'targetWindowId': targetWindowId,
    'targetIsMainWindow': targetIsMainWindow,
    'targetGroupId': targetGroupId,
    'insertionIndex': insertionIndex,
    'dockEdge': dockEdge?.name,
  };

  static NativePanelTransfer? parse(Object? value) {
    if (value is! Map) return null;
    final source = NativePanelPayload.parse(value['source']);
    final target = value['targetWindowId'];
    final isMain = value['targetIsMainWindow'];
    final group = value['targetGroupId'];
    final index = value['insertionIndex'];
    final edge = value['dockEdge'];
    if (source == null ||
        target is! String ||
        target.isEmpty ||
        isMain is! bool ||
        (group != null && group is! String) ||
        (index != null && (index is! int || index < 0)) ||
        (edge != null && edge is! String)) {
      return null;
    }
    final dock = WorkspaceDockEdge.values
        .where((item) => item.name == edge)
        .firstOrNull;
    if (edge != null && dock == null) return null;
    return NativePanelTransfer(
      source: source,
      targetWindowId: target,
      targetIsMainWindow: isMain,
      targetGroupId: group as String?,
      insertionIndex: index as int?,
      dockEdge: dock,
    );
  }
}
