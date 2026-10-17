import 'package:flutter/material.dart';

import 'panel_types.dart';
import 'workspace_layout.dart';

class WorkspaceSession {
  final List<WorkspaceGroup> groups = <WorkspaceGroup>[];
  int zCursor = 20;
  int idCursor = 100;
  String? draggingGroup;
  String? mergeTarget;
  Offset dragRemainder = Offset.zero;
  Offset resizeRemainder = Offset.zero;
  Size workspaceSize = Size.zero;
  bool gridMode = false;

  List<WorkspaceGroup> get groupsByZ =>
      [...groups]..sort((a, b) => a.z.compareTo(b.z));

  int nextZ() => ++zCursor;
  String nextGroupId(String prefix) {
    String id;
    do {
      id = '${prefix}_${idCursor++}';
    } while (groups.any((group) => group.id == id));
    return id;
  }

  void resetDrag() {
    dragRemainder = Offset.zero;
    draggingGroup = null;
    mergeTarget = null;
  }

  void resetResize() => resizeRemainder = Offset.zero;
}

class DetachedPanelPlacement {
  const DetachedPanelPlacement({
    required this.groupId,
    required this.groupRect,
    required this.groupZ,
    required this.panels,
    required this.originalPanels,
    required this.activePanel,
    this.sidebar,
    this.sidebarWidth = 280,
    this.sidebarCollapsed = false,
  });

  final String groupId;
  final Rect groupRect;
  final int groupZ;
  final List<WorkspacePanelId> panels;
  final List<WorkspacePanelId> originalPanels;
  final WorkspacePanelId activePanel;
  final WorkspaceSidebarSide? sidebar;
  final double sidebarWidth;
  final bool sidebarCollapsed;
}
