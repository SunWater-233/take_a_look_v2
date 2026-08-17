import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'backend_client.dart';
import 'controller.dart';
import 'panel_types.dart';
import 'panels.dart';
import 'theme.dart';
import 'window_sync.dart';
import 'workspace.dart';

class TakeALookApp extends StatefulWidget {
  const TakeALookApp({
    this.detachedPanel,
    this.detachedPanels,
    this.enableBackend = false,
    super.key,
  });

  final WorkspacePanelId? detachedPanel;
  final List<WorkspacePanelId>? detachedPanels;
  final bool enableBackend;

  @override
  State<TakeALookApp> createState() => _TakeALookAppState();
}

class _TakeALookAppState extends State<TakeALookApp> {
  late final TakeALookController controller;
  MainWindowSync? windowSync;
  BackendClient? backendClient;

  @override
  void initState() {
    super.initState();
    if (widget.detachedPanel == null) {
      if (widget.enableBackend) {
        final client = BackendClient();
        controller = TakeALookController(
          backendCommand: client.command,
          symbolFilePicker: pickSymbolFile,
          csvExportPathPicker: pickCsvExportPath,
        );
        client.eventHandler = controller.applyBackendEvent;
        backendClient = client;
        unawaited(client.start());
      } else {
        controller = TakeALookController();
      }
      windowSync = MainWindowSync(controller);
      unawaited(windowSync!.start());
    } else {
      late final TakeALookController remoteController;
      remoteController = TakeALookController(
        remoteCommand: (method, arguments) =>
            sendCommandToMain(remoteController, method, arguments),
      );
      controller = remoteController;
      unawaited(initializeDetachedWindow(controller));
    }
  }

  @override
  void dispose() {
    unawaited(windowSync?.dispose());
    backendClient?.eventHandler = null;
    unawaited(backendClient?.close());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Take A Look',
      theme: buildTalTheme(),
      builder: (context, child) {
        return ValueListenableBuilder<double>(
          valueListenable: controller.uiScaleListenable,
          child: child ?? const SizedBox.shrink(),
          builder: (context, scale, child) =>
              TalUiScaleViewport(scale: scale, child: child!),
        );
      },
      home: widget.detachedPanel == null
          ? MainWorkbench(controller: controller, windowSync: windowSync!)
          : DetachedPanelWindow(
              controller: controller,
              panel: widget.detachedPanel!,
              panels: widget.detachedPanels ?? const <WorkspacePanelId>[],
            ),
    );
  }
}

class TalUiScaleViewport extends StatelessWidget {
  const TalUiScaleViewport({
    required this.scale,
    required this.child,
    super.key,
  }) : assert(scale > 0);

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if ((scale - 1).abs() < 0.001) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final logicalSize = Size(
          constraints.maxWidth / scale,
          constraints.maxHeight / scale,
        );
        final mediaQuery = MediaQuery.maybeOf(context);
        final scaledChild = mediaQuery == null
            ? child
            : MediaQuery(
                data: mediaQuery.copyWith(size: logicalSize),
                child: child,
              );
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: logicalSize.width,
            maxWidth: logicalSize.width,
            minHeight: logicalSize.height,
            maxHeight: logicalSize.height,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: scaledChild,
            ),
          ),
        );
      },
    );
  }
}

class MainWorkbench extends StatefulWidget {
  const MainWorkbench({
    required this.controller,
    required this.windowSync,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;

  @override
  State<MainWorkbench> createState() => _MainWorkbenchState();
}

class _MainWorkbenchState extends State<MainWorkbench> {
  final workspaceKey = GlobalKey<DockingWorkspaceState>();
  Map<String, dynamic>? _lastObservedBackendError;
  Map<String, dynamic>? _pendingBackendError;
  bool _errorDialogScheduled = false;
  bool _errorDialogShowing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.connectionChanges.addListener(_handleBackendError);
    _handleBackendError();
  }

  @override
  void didUpdateWidget(covariant MainWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.connectionChanges.removeListener(_handleBackendError);
    widget.controller.connectionChanges.addListener(_handleBackendError);
    _lastObservedBackendError = null;
    _handleBackendError();
  }

  @override
  void dispose() {
    widget.controller.connectionChanges.removeListener(_handleBackendError);
    super.dispose();
  }

  void _handleBackendError() {
    final error = widget.controller.lastBackendError;
    if (error == null || identical(error, _lastObservedBackendError)) return;
    _lastObservedBackendError = error;
    _pendingBackendError = Map<String, dynamic>.from(error);
    if (_errorDialogShowing || _errorDialogScheduled) return;
    _errorDialogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _errorDialogScheduled = false;
      if (mounted) unawaited(_showPendingBackendErrors());
    });
  }

  Future<void> _showPendingBackendErrors() async {
    if (_errorDialogShowing) return;
    _errorDialogShowing = true;
    try {
      while (mounted && _pendingBackendError != null) {
        final error = _pendingBackendError!;
        _pendingBackendError = null;
        final message = error['message'] as String? ?? '后端操作失败。';
        final details = error['details'];
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(_backendErrorTitle(error)),
            content: SelectableText(
              details == null || details.toString().isEmpty
                  ? message
                  : '$message\n\n$details',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    } finally {
      _errorDialogShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          TalWindowTitleBar(
            controller: widget.controller,
            workspaceKey: workspaceKey,
          ),
          Expanded(
            child: DockingWorkspace(
              key: workspaceKey,
              controller: widget.controller,
              windowSync: widget.windowSync,
              onPanelVisibilityChanged: () {
                if (mounted) setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _backendErrorTitle(Map<String, dynamic> error) {
  return switch (error['code']) {
    'startup_failed' => '后端启动失败',
    'connect_failed' => 'pyOCD 连接失败',
    'file_not_found' ||
    'unsupported_symbol_file' ||
    'symbol_load_failed' => '读取失败',
    'write_failed' || 'readonly_symbol' || 'unknown_watch' => '写入失败',
    'reset_failed' => '目标复位失败',
    'no_samples' => '导出失败',
    _ => '操作失败',
  };
}

class DetachedPanelWindow extends StatefulWidget {
  const DetachedPanelWindow({
    required this.controller,
    required this.panel,
    this.panels = const <WorkspacePanelId>[],
    super.key,
  });

  final TakeALookController controller;
  final WorkspacePanelId panel;
  final List<WorkspacePanelId> panels;

  @override
  State<DetachedPanelWindow> createState() => _DetachedPanelWindowState();
}

class _DetachedPanelWindowState extends State<DetachedPanelWindow> {
  late WorkspacePanelId activePanel;

  List<WorkspacePanelId> get groupPanels =>
      widget.panels.isEmpty ? <WorkspacePanelId>[widget.panel] : widget.panels;

  @override
  void initState() {
    super.initState();
    activePanel = widget.panel;
  }

  @override
  Widget build(BuildContext context) {
    final panels = groupPanels;
    final chrome = panels.length > 1
        ? PanelChrome(
            tabs: List.unmodifiable(panels),
            activePanel: activePanel,
            highlighted: false,
            onSelect: (panel) => setState(() => activePanel = panel),
            onFloat: () {},
            onClose: () {},
            onSeparate: () {},
            onDragStart: (_) {},
            onDragUpdate: (_) {},
            onDragEnd: (_) {},
            showActions: false,
            draggable: false,
          )
        : null;
    return Scaffold(
      body: Column(
        children: [
          TalWindowTitleBar(
            subtitle: panels.length > 1
                ? '${activePanel.title} 组合'
                : activePanel.title,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: buildWorkspacePanel(
                activePanel,
                widget.controller,
                chrome: chrome,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TalWindowTitleBar extends StatefulWidget {
  const TalWindowTitleBar({
    this.subtitle,
    this.controller,
    this.workspaceKey,
    super.key,
  });

  final String? subtitle;
  final TakeALookController? controller;
  final GlobalKey<DockingWorkspaceState>? workspaceKey;

  @override
  State<TalWindowTitleBar> createState() => _TalWindowTitleBarState();
}

class _TalWindowTitleBarState extends State<TalWindowTitleBar> {
  static const _uiScales = <double>[0.85, 1, 1.25, 1.45];
  static const _panelMenuOrder = <WorkspacePanelId>[
    WorkspacePanelId.header,
    WorkspacePanelId.sampling,
    WorkspacePanelId.runControl,
    WorkspacePanelId.plot,
    WorkspacePanelId.connection,
    WorkspacePanelId.symbols,
    WorkspacePanelId.watch,
    WorkspacePanelId.log,
  ];

  bool gridMode = false;
  double get uiScale => widget.controller?.uiScale ?? 1;

  @override
  void initState() {
    super.initState();
    widget.controller?.samplingChanges.addListener(_refreshSamplingMenu);
  }

  @override
  void didUpdateWidget(covariant TalWindowTitleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller?.samplingChanges.removeListener(_refreshSamplingMenu);
    widget.controller?.samplingChanges.addListener(_refreshSamplingMenu);
  }

  @override
  void dispose() {
    widget.controller?.samplingChanges.removeListener(_refreshSamplingMenu);
    super.dispose();
  }

  void _refreshSamplingMenu() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      color: TalColors.input,
      child: Row(
        children: [
          DragToMoveArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Row(
                children: [
                  const Text(
                    'Take A Look',
                    style: TextStyle(
                      color: TalColors.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFamily: talBrandFontFamily,
                      fontFamilyFallback: talBrandFontFamilyFallback,
                      letterSpacing: 0,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(width: 8),
                    Text(widget.subtitle!, style: talMuted),
                  ],
                  const SizedBox(width: 8),
                  Container(width: 2, height: 24, color: TalColors.accent),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (widget.subtitle == null) ...[
            _TitleMenu(label: '视图', menuChildren: _buildViewMenu()),
            const SizedBox(width: 4),
            _TitleMenu(label: '实时变量', menuChildren: _buildVariableMenu()),
          ],
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _CaptionButton(
            tooltip: '最小化',
            icon: Icons.remove,
            onPressed: windowManager.minimize,
          ),
          const SizedBox(width: 8),
          _CaptionButton(
            tooltip: '最大化/还原',
            icon: Icons.crop_square,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          const SizedBox(width: 8),
          _CaptionButton(
            tooltip: '关闭',
            icon: Icons.close,
            close: true,
            onPressed: windowManager.close,
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  List<Widget> _buildViewMenu() {
    final workspace = widget.workspaceKey?.currentState;
    return [
      SubmenuButton(
        style: _menuButtonStyle,
        menuStyle: _submenuStyle,
        animated: true,
        leadingIcon: const SizedBox(width: 16),
        menuChildren: [
          _menuItem(label: '放大界面', onPressed: () => _stepUiScale(1)),
          _menuItem(label: '缩小界面', onPressed: () => _stepUiScale(-1)),
          _menuItem(
            label: '重置界面缩放',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.digit0,
              control: true,
            ),
            onPressed: () => _setUiScale(1),
          ),
          const _MenuDivider(),
          for (final scale in _uiScales)
            _menuItem(
              label: '${(scale * 100).round()}%',
              checked: (uiScale - scale).abs() < 0.001,
              reserveLeading: true,
              onPressed: () => _setUiScale(scale),
            ),
        ],
        child: const Text('UI 缩放'),
      ),
      _menuItem(
        label: '网格模式',
        checked: gridMode,
        reserveLeading: true,
        onPressed: _toggleGridMode,
      ),
      SubmenuButton(
        style: _menuButtonStyle,
        menuStyle: _submenuStyle,
        animated: true,
        leadingIcon: const SizedBox(width: 16),
        menuChildren: [
          _menuItem(
            label: '恢复默认组件组合',
            onPressed: () => widget.workspaceKey?.currentState?.resetLayout(),
          ),
        ],
        child: const Text('组件组合'),
      ),
      _menuItem(
        label: '保存布局',
        shortcut: const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          shift: true,
        ),
        reserveLeading: true,
        onPressed: () => _handleViewAction('save'),
      ),
      _menuItem(
        label: '恢复保存的布局',
        reserveLeading: true,
        onPressed: () => _handleViewAction('restore'),
      ),
      _menuItem(
        label: '重置默认布局',
        reserveLeading: true,
        onPressed: () => _handleViewAction('reset'),
      ),
      const _MenuDivider(),
      for (final panel in _panelMenuOrder)
        _menuItem(
          label: panel.title,
          checked: workspace?.isPanelVisible(panel) ?? true,
          reserveLeading: true,
          onPressed: () => _handleViewAction('panel:${panel.name}'),
        ),
    ];
  }

  List<Widget> _buildVariableMenu() {
    final state = widget.controller;
    return [
      SubmenuButton(
        style: _menuButtonStyle,
        menuStyle: _submenuStyle,
        animated: true,
        menuChildren: [
          _menuItem(
            label: '标准模式（60 Hz）',
            checked: state?.displayRefreshMode == 'standard',
            reserveLeading: true,
            onPressed: state == null
                ? null
                : () => _setDisplayRefreshMode('standard'),
          ),
          _menuItem(
            label: '高频模式（120 Hz）',
            checked: state?.displayRefreshMode == 'high',
            reserveLeading: true,
            onPressed: state == null
                ? null
                : () => _setDisplayRefreshMode('high'),
          ),
          _menuItem(
            label: '实时模式（自适应）',
            checked: state?.displayRefreshMode == 'realtime',
            reserveLeading: true,
            onPressed: state == null
                ? null
                : () => _setDisplayRefreshMode('realtime'),
          ),
        ],
        child: const Text('刷新率设置'),
      ),
      SubmenuButton(
        style: _menuButtonStyle,
        menuStyle: _submenuStyle,
        animated: true,
        menuChildren: [
          CheckboxMenuButton(
            value: state?.rttEnabled ?? false,
            onChanged: state == null
                ? null
                : (value) => state.toggleRtt(value ?? false),
            style: _menuButtonStyle,
            closeOnActivate: false,
            child: const Text('RTT采样'),
          ),
          SubmenuButton(
            style: _menuButtonStyle,
            menuStyle: _submenuStyle,
            animated: true,
            leadingIcon: const SizedBox(width: 16),
            menuChildren: [
              _menuItem(
                label: 'RTT-Normal',
                checked: state?.rttProtocol == 'normal',
                reserveLeading: true,
                onPressed: () => _setRttProtocol('normal'),
              ),
              _menuItem(
                label: 'RTT-Plus',
                checked: state?.rttProtocol == 'plus',
                reserveLeading: true,
                onPressed: () => _setRttProtocol('plus'),
              ),
            ],
            child: const Text('RTT协议'),
          ),
        ],
        child: const Text('RTT设置'),
      ),
      _menuItem(label: '导出原始采样 CSV', onPressed: state?.exportCsv),
    ];
  }

  void _stepUiScale(int direction) {
    final currentIndex = _uiScales.indexOf(uiScale);
    final nextIndex = (currentIndex + direction).clamp(0, _uiScales.length - 1);
    _setUiScale(_uiScales[nextIndex]);
  }

  void _setUiScale(double value) {
    widget.controller?.setUiScale(value);
    setState(() {});
  }

  void _toggleGridMode() {
    setState(() => gridMode = !gridMode);
    widget.workspaceKey?.currentState?.setGridMode(gridMode);
    widget.controller?.report(gridMode ? '网格模式已开启。' : '网格模式已关闭。');
  }

  void _setRttProtocol(String protocol) {
    widget.controller?.setRttProtocol(protocol);
    setState(() {});
  }

  void _setDisplayRefreshMode(String mode) {
    widget.controller?.setDisplayRefreshMode(mode);
    setState(() {});
  }

  void _handleViewAction(String action) {
    final workspace = widget.workspaceKey?.currentState;
    if (workspace == null) return;
    switch (action) {
      case 'save':
        unawaited(workspace.saveLayout());
      case 'restore':
        unawaited(workspace.restoreLayout());
      case 'reset':
        workspace.resetLayout();
      default:
        if (action.startsWith('panel:')) {
          final panel = WorkspacePanelId.values.byName(action.substring(6));
          unawaited(workspace.togglePanelVisibility(panel));
        }
    }
  }
}

class _TitleMenu extends StatefulWidget {
  const _TitleMenu({required this.label, required this.menuChildren});

  final String label;
  final List<Widget> menuChildren;

  @override
  State<_TitleMenu> createState() => _TitleMenuState();
}

class _TitleMenuState extends State<_TitleMenu> {
  final menuController = MenuController();
  TalMenuAnimationLease? _menuAnimationLease;
  bool open = false;
  bool hovered = false;

  @override
  void dispose() {
    _releaseMenuAnimation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: menuController,
      style: _rootMenuStyle,
      // The title buttons are 34 px high and vertically centered in the
      // 46 px title bar. Move the root menu to the bottom edge of that bar.
      alignmentOffset: const Offset(0, 6),
      animated: true,
      onAnimationStatusChanged: (status) {
        if (status == AnimationStatus.dismissed) _releaseMenuAnimation();
      },
      onOpen: () {
        _menuAnimationLease ??= beginTalMenuAnimation();
        setState(() => open = true);
      },
      onClose: () => setState(() => open = false),
      menuChildren: widget.menuChildren,
      builder: (context, controller, child) {
        return MouseRegion(
          onEnter: _handleHoverEnter,
          onExit: _handleHoverExit,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: const BorderRadius.all(Radius.circular(7)),
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  _menuAnimationLease ??= beginTalMenuAnimation();
                  controller.open();
                }
              },
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: open || hovered ? TalColors.hover : Colors.transparent,
                  border: open || hovered
                      ? Border.all(color: TalColors.border)
                      : null,
                  borderRadius: const BorderRadius.all(Radius.circular(7)),
                ),
                child: Text(widget.label, style: talStrong),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleHoverEnter(PointerEnterEvent event) {
    setState(() => hovered = true);
  }

  void _handleHoverExit(PointerExitEvent event) {
    if (mounted) setState(() => hovered = false);
  }

  void _releaseMenuAnimation() {
    _menuAnimationLease?.release();
    _menuAnimationLease = null;
  }
}

MenuItemButton _menuItem({
  required String label,
  required VoidCallback? onPressed,
  bool checked = false,
  bool reserveLeading = false,
  MenuSerializableShortcut? shortcut,
}) {
  return MenuItemButton(
    style: _menuButtonStyle,
    leadingIcon: reserveLeading
        ? SizedBox(
            width: 16,
            child: checked
                ? const Icon(Icons.check, size: 14, color: TalColors.text)
                : null,
          )
        : null,
    shortcut: shortcut,
    onPressed: onPressed,
    child: Text(label),
  );
}

final _menuButtonStyle = talContextMenuButtonStyle;
final _rootMenuStyle = talContextMenuStyle.copyWith(
  alignment: AlignmentDirectional.bottomStart,
);
final _submenuStyle = talContextSubmenuStyle;

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 7, thickness: 1, color: TalColors.borderSoft);
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.close = false,
  });

  final String tooltip;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool close;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        hoverColor: close ? const Color(0xFFC42B1C) : TalColors.hover,
        child: SizedBox(
          width: 44,
          height: 34,
          child: Icon(icon, size: 18, color: TalColors.text),
        ),
      ),
    );
  }
}
