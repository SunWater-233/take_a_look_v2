import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'panel_types.dart';

class WorkspaceGroup {
  WorkspaceGroup({
    required this.id,
    required List<WorkspacePanelId> panels,
    required WorkspacePanelId activePanel,
    required this.rect,
    required this.z,
    this.sidebar,
    this.sidebarWidth = 280,
    this.sidebarCollapsed = false,
  }) : panels = List.of(panels),
       _activePanel = ValueNotifier<WorkspacePanelId>(activePanel);

  final String id;
  final List<WorkspacePanelId> panels;
  final ValueNotifier<WorkspacePanelId> _activePanel;
  Rect rect;
  int z;
  WorkspaceSidebarSide? sidebar;
  double sidebarWidth;
  bool sidebarCollapsed;

  WorkspacePanelId get activePanel => _activePanel.value;
  set activePanel(WorkspacePanelId value) => _activePanel.value = value;
  ValueNotifier<WorkspacePanelId> get activePanelListenable => _activePanel;

  Map<String, dynamic> toJson() => {
    'id': id,
    'panels': [for (final panel in panels) panel.name],
    'activePanel': activePanel.name,
    'rect': [rect.left, rect.top, rect.width, rect.height],
    'z': z,
    if (sidebar != null) ...{
      'sidebar': sidebar!.name,
      'sidebarWidth': sidebarWidth,
      'sidebarCollapsed': sidebarCollapsed,
    },
  };

  factory WorkspaceGroup.fromJson(Map<String, dynamic> json) {
    final panels = (json['panels'] as List)
        .map((value) => WorkspacePanelId.values.byName(value as String))
        .toList();
    if (panels.isEmpty) {
      throw const FormatException('Workspace group cannot be empty.');
    }
    final activePanel = WorkspacePanelId.values.byName(
      json['activePanel'] as String,
    );
    if (!panels.contains(activePanel)) {
      throw const FormatException('Active panel is not part of its group.');
    }
    final values = (json['rect'] as List)
        .map((value) => (value as num).toDouble())
        .toList();
    if (values.length != 4 || values.any((value) => !value.isFinite)) {
      throw const FormatException('Workspace group rectangle is invalid.');
    }
    final rect = Rect.fromLTWH(values[0], values[1], values[2], values[3]);
    if (rect.width <= 0 || rect.height <= 0) {
      throw const FormatException('Workspace group size must be positive.');
    }
    final sidebarName = json['sidebar'];
    final sidebar = sidebarName == null
        ? null
        : WorkspaceSidebarSide.values
              .where((side) => side.name == sidebarName)
              .firstOrNull;
    final sidebarWidth = (json['sidebarWidth'] as num?)?.toDouble() ?? 280;
    if ((sidebarName != null && sidebar == null) ||
        !sidebarWidth.isFinite ||
        sidebarWidth <= 0) {
      throw const FormatException('Workspace sidebar is invalid.');
    }
    return WorkspaceGroup(
      id: json['id'] as String,
      panels: panels,
      activePanel: activePanel,
      rect: rect,
      z: (json['z'] as num).toInt(),
      sidebar: sidebar,
      sidebarWidth: sidebarWidth,
      sidebarCollapsed: json['sidebarCollapsed'] == true,
    );
  }
}

class WorkspaceLayoutSnapshot {
  const WorkspaceLayoutSnapshot({
    required this.groups,
    required this.uiScale,
    this.version = 1,
    this.legacyPanels = false,
  });

  final List<WorkspaceGroup> groups;
  final double uiScale;
  final int version;
  final bool legacyPanels;

  Map<String, dynamic> toJson() => {
    'version': version,
    if (version >= 2) 'legacyPanels': legacyPanels,
    'uiScale': uiScale,
    'groups': [for (final group in groups) group.toJson()],
  };

  factory WorkspaceLayoutSnapshot.fromJson(Map<String, dynamic> json) {
    if (!const [1, 2, 3, 4].contains(json['version']) ||
        json['groups'] is! List) {
      throw const FormatException('Unsupported workspace layout format.');
    }
    return WorkspaceLayoutSnapshot(
      version: json['version'] as int,
      legacyPanels: json['legacyPanels'] == true,
      groups: [
        for (final entry in json['groups'] as List)
          WorkspaceGroup.fromJson(Map<String, dynamic>.from(entry as Map)),
      ],
      uiScale: (json['uiScale'] as num?)?.toDouble() ?? 1,
    );
  }
}

class WorkspaceLayoutRepository {
  const WorkspaceLayoutRepository(this.file);

  final File file;

  Future<void> save(WorkspaceLayoutSnapshot layout) async {
    await file.parent.create(recursive: true);
    if (layout.version >= 2 && await file.exists()) {
      try {
        final previous = jsonDecode(await file.readAsString());
        if (previous is Map &&
            previous['version'] is int &&
            const [1, 2, 3].contains(previous['version']) &&
            (previous['version'] as int) < layout.version) {
          final backup = File('${file.path}.v${previous['version']}.bak');
          if (!await backup.exists()) await file.copy(backup.path);
        }
      } on FormatException {
        /* Preserve normal save behavior for invalid old data. */
      }
    }
    await file.writeAsString(jsonEncode(layout.toJson()), flush: true);
  }

  Future<WorkspaceLayoutSnapshot?> load() async {
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) {
      throw const FormatException('Workspace layout root must be an object.');
    }
    return WorkspaceLayoutSnapshot.fromJson(Map<String, dynamic>.from(raw));
  }

  static File defaultFile() {
    final environment = Platform.environment;
    late final String basePath;
    if (Platform.isWindows) {
      basePath = environment['APPDATA'] ?? Directory.current.path;
    } else if (Platform.isMacOS) {
      final home = environment['HOME'] ?? Directory.current.path;
      basePath =
          '$home${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support';
    } else {
      final home = environment['HOME'] ?? Directory.current.path;
      basePath =
          environment['XDG_CONFIG_HOME'] ??
          '$home${Platform.pathSeparator}.config';
    }
    final directory = Directory('$basePath${Platform.pathSeparator}TakeALook');
    return File('${directory.path}${Platform.pathSeparator}layout.json');
  }
}
