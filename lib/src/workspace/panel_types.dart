import 'dart:convert';

import 'package:flutter/material.dart';

enum WorkspacePanelId {
  header,
  runControl,
  sampling,
  symbols,
  watch,
  connection,
  plot,
  analysis,
  sourceDebug,
  log,
}

enum SecondaryWindowRole { detachedPanel, dragPreview }

extension WorkspacePanelInfo on WorkspacePanelId {
  String get title => switch (this) {
    WorkspacePanelId.header => '主标题',
    WorkspacePanelId.runControl => '运行控制',
    WorkspacePanelId.sampling => '采样控制',
    WorkspacePanelId.symbols => '符号变量',
    WorkspacePanelId.watch => '实时调参',
    WorkspacePanelId.connection => '连接设置',
    WorkspacePanelId.plot => '实时图表',
    WorkspacePanelId.analysis => '分析图表',
    WorkspacePanelId.sourceDebug => '源码调试',
    WorkspacePanelId.log => '事件日志',
  };

  IconData get icon => switch (this) {
    WorkspacePanelId.header => Icons.space_dashboard_outlined,
    WorkspacePanelId.runControl => Icons.play_circle_outline,
    WorkspacePanelId.sampling => Icons.timer_outlined,
    WorkspacePanelId.symbols => Icons.account_tree_outlined,
    WorkspacePanelId.watch => Icons.tune,
    WorkspacePanelId.connection => Icons.settings_input_component,
    WorkspacePanelId.plot => Icons.show_chart,
    WorkspacePanelId.analysis => Icons.analytics_outlined,
    WorkspacePanelId.sourceDebug => Icons.code,
    WorkspacePanelId.log => Icons.terminal,
  };

  Size get preferredWindowSize => switch (this) {
    WorkspacePanelId.header => const Size(520, 250),
    WorkspacePanelId.runControl => const Size(520, 260),
    WorkspacePanelId.sampling => const Size(520, 330),
    WorkspacePanelId.symbols => const Size(540, 700),
    WorkspacePanelId.watch => const Size(900, 560),
    WorkspacePanelId.connection => const Size(520, 430),
    WorkspacePanelId.plot => const Size(1050, 700),
    WorkspacePanelId.analysis => const Size(1050, 700),
    WorkspacePanelId.sourceDebug => const Size(1100, 760),
    WorkspacePanelId.log => const Size(900, 340),
  };
}

class DetachedPanelLaunch {
  const DetachedPanelLaunch({
    required this.panel,
    required this.initialSize,
    this.panels = const <WorkspacePanelId>[],
    this.role = SecondaryWindowRole.detachedPanel,
    this.initialPosition,
  });

  final WorkspacePanelId panel;
  final Size initialSize;
  final List<WorkspacePanelId> panels;
  final SecondaryWindowRole role;
  final Offset? initialPosition;

  List<WorkspacePanelId> get groupPanels =>
      panels.isEmpty ? <WorkspacePanelId>[panel] : panels;

  Map<String, dynamic> toJson() => {
    'businessId': 'take_a_look_panel',
    'role': role.name,
    'panel': panel.name,
    if (panels.isNotEmpty) 'panels': [for (final item in panels) item.name],
    'width': initialSize.width,
    'height': initialSize.height,
    if (initialPosition case final position?) ...{
      'x': position.dx,
      'y': position.dy,
    },
  };
}

DetachedPanelLaunch? detachedPanelLaunchFromJson(Object? value) {
  try {
    final data = Map<String, dynamic>.from(value as Map);
    if (data['businessId'] != 'take_a_look_panel') return null;
    final role = SecondaryWindowRole.values.byName(data['role'] as String);
    final panel = WorkspacePanelId.values.byName(data['panel'] as String);
    final panels = (data['panels'] as List<dynamic>?)
        ?.map((value) => WorkspacePanelId.values.byName(value as String))
        .toList(growable: false);
    final width = (data['width'] as num?)?.toDouble();
    final height = (data['height'] as num?)?.toDouble();
    final size =
        width != null && height != null && width.isFinite && height.isFinite
        ? Size(width, height)
        : panel.preferredWindowSize;
    if (size.width <= 0 || size.height <= 0) return null;
    final x = (data['x'] as num?)?.toDouble();
    final y = (data['y'] as num?)?.toDouble();
    final position = x != null && y != null && x.isFinite && y.isFinite
        ? Offset(x, y)
        : null;
    return DetachedPanelLaunch(
      panel: panel,
      panels: panels ?? const <WorkspacePanelId>[],
      initialSize: size,
      role: role,
      initialPosition: position,
    );
  } on Object {
    return null;
  }
}

DetachedPanelLaunch? detachedPanelLaunchFromEntrypointArguments(
  List<String> args,
) {
  if (args.length < 3 || args.first != 'multi_window') return null;
  try {
    return detachedPanelLaunchFromJson(jsonDecode(args[2]));
  } on Object {
    return null;
  }
}

WorkspacePanelId? panelFromEntrypointArguments(List<String> args) {
  return detachedPanelLaunchFromEntrypointArguments(args)?.panel;
}

String encodePanelArguments(
  WorkspacePanelId panel,
  Size initialSize, {
  List<WorkspacePanelId>? panels,
  SecondaryWindowRole role = SecondaryWindowRole.detachedPanel,
  Offset? initialPosition,
}) {
  return jsonEncode(
    DetachedPanelLaunch(
      panel: panel,
      panels: panels ?? const <WorkspacePanelId>[],
      initialSize: initialSize,
      role: role,
      initialPosition: initialPosition,
    ).toJson(),
  );
}

class PanelTabInfo {
  const PanelTabInfo(this.id);
  final WorkspacePanelId id;
}

class PanelTabDragData {
  const PanelTabDragData({required this.sourceGroupId, required this.panel});

  final String sourceGroupId;
  final WorkspacePanelId panel;
}

class PanelChrome {
  const PanelChrome({
    required this.tabs,
    required this.activePanel,
    required this.highlighted,
    required this.onSelect,
    required this.onFloat,
    required this.onClose,
    required this.onSeparate,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.showActions = true,
    this.draggable = true,
    this.groupId,
    this.onTabAccept,
    this.onTabDragStart,
    this.onTabDragUpdate,
    this.onTabDragEnd,
    this.tabsDraggable = false,
    this.headerLeading,
  });

  final List<WorkspacePanelId> tabs;
  final WorkspacePanelId activePanel;
  final bool highlighted;
  final ValueChanged<WorkspacePanelId> onSelect;
  final VoidCallback onFloat;
  final VoidCallback onClose;
  final VoidCallback onSeparate;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final bool showActions;
  final bool draggable;
  final String? groupId;
  final void Function(PanelTabDragData, int targetIndex)? onTabAccept;
  final ValueChanged<PanelTabDragData>? onTabDragStart;
  final void Function(PanelTabDragData, DragUpdateDetails)? onTabDragUpdate;
  final void Function(PanelTabDragData, DraggableDetails)? onTabDragEnd;
  final bool tabsDraggable;
  final Widget? headerLeading;
}
