import 'dart:convert';
import 'dart:io';

import '../controller/controller.dart';
import 'workspace_layout.dart';

class ProjectDocument {
  const ProjectDocument({
    required this.settings,
    required this.layout,
    this.gridMode = false,
    this.focused = false,
  });

  final Map<String, dynamic> settings;
  final WorkspaceLayoutSnapshot layout;
  final bool gridMode;
  final bool focused;

  Map<String, dynamic> toJson() => {
    'format': 'take-a-look-project',
    'version': 1,
    'settings': settings,
    'layout': layout.toJson(),
    'gridMode': gridMode,
    'focused': focused,
  };

  factory ProjectDocument.fromJson(Map<String, dynamic> data) {
    if (data['format'] != 'take-a-look-project' || data['version'] != 1) {
      throw const FormatException('不支持的 Take A Look 项目格式。');
    }
    final settings = Map<String, dynamic>.from(data['settings'] as Map);
    TakeALookControllerProject.validateProjectSettings(settings);
    final layout = WorkspaceLayoutSnapshot.fromJson(
      Map<String, dynamic>.from(data['layout'] as Map),
    );
    if (!layout.uiScale.isFinite ||
        layout.uiScale < .5 ||
        layout.uiScale > 2 ||
        layout.groups.map((group) => group.id).toSet().length !=
            layout.groups.length) {
      throw const FormatException('项目布局无效。');
    }
    return ProjectDocument(
      settings: settings,
      layout: layout,
      gridMode: data['gridMode'] == true,
      focused: data['focused'] == true,
    );
  }

  static Future<ProjectDocument> read(File file) async =>
      ProjectDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(toJson()),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
