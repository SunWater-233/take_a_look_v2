import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../controller/controller.dart';
import '../panels/panels.dart';
import '../telemetry/recording_storage.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../workspace/panel_types.dart';
import '../theme/theme.dart';
import '../workspace/workspace.dart';

class TalWindowTitleBar extends StatefulWidget {
  const TalWindowTitleBar({
    this.subtitle,
    this.controller,
    this.workspaceKey,
    this.workbench = false,
    this.recordingStorage,
    super.key,
  });

  final String? subtitle;
  final TakeALookController? controller;
  final GlobalKey<DockingWorkspaceState>? workspaceKey;
  final bool workbench;
  final RecordingStorage? recordingStorage;

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
    WorkspacePanelId.analysis,
    WorkspacePanelId.sourceDebug,
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
    final detached = widget.subtitle != null;
    return Container(
      height: TalUiTheme.of(context).titleBarHeight,
      color: TalColors.background,
      child: Row(
        children: [
          if (detached)
            Expanded(child: _buildDetachedTitle())
          else
            _buildMainTitle(),
          if (!detached) ...[
            if (widget.workbench)
              _TitleMenu(label: '文件', menuChildren: _buildFileMenu()),
            if (widget.workbench)
              _TitleMenu(label: '采集', menuChildren: _buildVariableMenu()),
            _TitleMenu(label: '视图', menuChildren: _buildViewMenu()),
            const SizedBox(width: 4),
            if (!widget.workbench)
              _TitleMenu(label: '实时变量', menuChildren: _buildVariableMenu()),
            const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          ],
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

  Widget _buildMainTitle() {
    return DragToMoveArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            const Text('Take A Look', style: _brandStyle),
            const SizedBox(width: 8),
            Container(width: 2, height: 24, color: TalColors.accent),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildDetachedTitle() {
    return DragToMoveArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Take A Look', style: _brandStyle),
                    TextSpan(text: '  ${widget.subtitle}', style: talMuted),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(width: 2, height: 24, color: TalColors.accent),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  static const _brandStyle = TextStyle(
    color: TalColors.heading,
    fontSize: 18,
    fontWeight: FontWeight.w800,
    fontFamily: talBrandFontFamily,
    fontFamilyFallback: talBrandFontFamilyFallback,
    letterSpacing: 0,
  );

  List<Widget> _buildViewMenu() {
    final workspace = widget.workspaceKey?.currentState;
    return [
      if (widget.workbench) ...[
        _menuItem(
          label: '资源库',
          checked: workspace?.resourceDocked ?? false,
          onPressed: () =>
              unawaited(workspace?.toggleWorkbenchResource() ?? Future.value()),
        ),
        _menuItem(
          label: '输出',
          checked: workspace?.outputDocked ?? false,
          onPressed: () =>
              unawaited(workspace?.toggleWorkbenchOutput() ?? Future.value()),
        ),
        _menuItem(
          label: '专注视图',
          checked: workspace?.focusedWorkbench ?? false,
          onPressed: workspace?.toggleWorkbenchFocus,
        ),
        const _MenuDivider(),
      ],
      SubmenuButton(
        menuStyle: Theme.of(
          context,
        ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
        animated: true,
        leadingIcon: const SizedBox(width: 16),
        menuChildren: [
          _menuItem(label: '放大界面', onPressed: () => _stepUiScale(1)),
          _menuItem(label: '缩小界面', onPressed: () => _stepUiScale(-1)),
          _menuItem(
            label: '重置界面缩放',
            shortcut: WorkspaceShortcut.resetUiScale.menuActivator,
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
        menuStyle: Theme.of(
          context,
        ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
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
        shortcut: WorkspaceShortcut.saveLayout.menuActivator,
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
      if (widget.workbench) ...[
        _menuItem(
          label: state?.samplingPaused == true ? '继续采集' : '暂停采集',
          onPressed: state?.toggleSampling,
        ),
        _menuItem(label: '清空采样', onPressed: state?.clearSamples),
        _menuItem(
          label: '采集设置',
          onPressed: state == null
              ? null
              : () => showWorkbenchSamplingSettings(context, state),
        ),
        const _MenuDivider(),
      ],
      SubmenuButton(
        menuStyle: Theme.of(
          context,
        ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
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
      ListenableBuilder(
        listenable: Listenable.merge([state?.plotControlChanges]),
        builder: (context, _) => SubmenuButton(
          menuStyle: Theme.of(
            context,
          ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
          animated: true,
          menuChildren: [
            for (final seconds in const [10, 30, 60, 120])
              _menuItem(
                label: '$seconds 秒',
                checked: state?.plotRetentionSeconds == seconds,
                reserveLeading: true,
                onPressed: state == null
                    ? null
                    : () => state.configurePlotView({
                        'plotRetentionSeconds': seconds,
                      }),
              ),
          ],
          child: const Text('绘图缓存'),
        ),
      ),
      SubmenuButton(
        menuStyle: Theme.of(
          context,
        ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
        animated: true,
        menuChildren: [
          CheckboxMenuButton(
            value: state?.rttEnabled ?? false,
            onChanged: state == null
                ? null
                : (value) => state.toggleRtt(value ?? false),
            closeOnActivate: false,
            child: const Text('RTT采样'),
          ),
          SubmenuButton(
            menuStyle: Theme.of(
              context,
            ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.topEnd),
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

  List<Widget> _buildFileMenu() {
    final state = widget.controller;
    return [
      _menuItem(label: '打开 ELF / AXF', onPressed: state?.chooseSymbolFile),
      _menuItem(
        label: '工程设置',
        onPressed: state == null
            ? null
            : () => showWorkbenchProjectSettings(context, state),
      ),
      const _MenuDivider(),
      _menuItem(
        label: '数据分析',
        onPressed: () => unawaited(
          widget.workspaceKey?.currentState?.activateWorkbenchView(
                WorkspacePanelId.analysis,
              ) ??
              Future.value(),
        ),
      ),
      _menuItem(label: '导出原始采样 CSV', onPressed: state?.exportCsv),
      _menuItem(
        label: '打开录制目录',
        onPressed: widget.recordingStorage?.openDirectory,
      ),
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
      style: Theme.of(
        context,
      ).menuTheme.style?.copyWith(alignment: AlignmentDirectional.bottomStart),
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
                height: TalUiTheme.of(context).titleButtonHeight,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: open || hovered ? TalColors.hover : Colors.transparent,
                  border: open || hovered
                      ? Border.all(color: TalColors.border)
                      : null,
                  borderRadius: const BorderRadius.all(Radius.circular(7)),
                ),
                child: Text(
                  widget.label,
                  style: talBody.copyWith(fontWeight: FontWeight.w400),
                ),
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
    final ui = TalUiTheme.of(context);
    return TalIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: talCaptionButtonStyle(ui, close: close),
      icon: Icon(icon, size: 18),
    );
  }
}
