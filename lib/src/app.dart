import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tal_drag_preview/tal_drag_preview.dart';
import 'package:window_manager/window_manager.dart';

import 'app/title_bar.dart';
import 'backend_client.dart';
import 'controller.dart';
import 'panel_types.dart';
import 'panels.dart';
import 'theme.dart';
import 'window_sync.dart';
import 'workspace.dart';

export 'app/title_bar.dart';

class TakeALookApp extends StatefulWidget {
  const TakeALookApp({
    this.detachedPanel,
    this.detachedPanels,
    this.secondaryWindowRole = SecondaryWindowRole.detachedPanel,
    this.enableBackend = false,
    super.key,
  });

  final WorkspacePanelId? detachedPanel;
  final List<WorkspacePanelId>? detachedPanels;
  final SecondaryWindowRole secondaryWindowRole;
  final bool enableBackend;

  @override
  State<TakeALookApp> createState() => _TakeALookAppState();
}

class _TakeALookAppState extends State<TakeALookApp> with WindowListener {
  late final TakeALookController controller;
  MainWindowSync? windowSync;
  BackendClient? backendClient;
  WorkspacePanelId? detachedPanel;
  List<WorkspacePanelId> detachedPanels = const <WorkspacePanelId>[];
  bool detachedWindowAssigned = false;
  bool releasingDetachedWindow = false;
  int _tabDragPreviewSession = 0;
  bool _tabDragPreviewActive = false;
  bool _tabDragPreviewVisible = false;

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
      detachedPanel = widget.detachedPanel;
      detachedPanels = widget.detachedPanels ?? const <WorkspacePanelId>[];
      late final TakeALookController remoteController;
      remoteController = TakeALookController(
        remoteCommand: (method, arguments) =>
            sendCommandToMain(remoteController, method, arguments),
      );
      controller = remoteController;
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
      unawaited(
        initializeDetachedWindow(
          controller,
          onConfigure:
              widget.secondaryWindowRole == SecondaryWindowRole.detachedPanel
              ? _configureDetachedWindow
              : null,
          onPrepareTabDragPreview:
              widget.secondaryWindowRole == SecondaryWindowRole.dragPreview
              ? _prepareTabDragPreview
              : null,
          onShowTabDragPreview:
              widget.secondaryWindowRole == SecondaryWindowRole.dragPreview
              ? _showTabDragPreview
              : null,
          onHideTabDragPreview:
              widget.secondaryWindowRole == SecondaryWindowRole.dragPreview
              ? _hideTabDragPreview
              : null,
        ),
      );
    }
  }

  Future<void> _configureDetachedWindow(
    DetachedPanelLaunch configuration,
  ) async {
    if (!mounted) return;
    await windowManager.hide();
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setBackgroundColor(const Color(0xFF050505));
    await windowManager.setMinimumSize(Size.zero);
    await TalDragPreview.setClickThrough(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setOpacity(1);
    setState(() {
      detachedPanel = configuration.panel;
      detachedPanels = configuration.panels;
      detachedWindowAssigned = true;
    });
    await windowManager.setSize(configuration.initialSize);
    final initialPosition = configuration.initialPosition;
    if (initialPosition != null) {
      await windowManager.setPosition(initialPosition);
    }
    final panels = configuration.groupPanels;
    await windowManager.setTitle(
      panels.length > 1
          ? 'Take A Look - ${configuration.panel.title} 组合'
          : 'Take A Look - ${configuration.panel.title}',
    );
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _prepareTabDragPreview(
    DetachedPanelLaunch configuration,
    int session,
  ) async {
    if (!mounted || session <= _tabDragPreviewSession) return;
    _tabDragPreviewSession = session;
    _tabDragPreviewActive = true;
    _tabDragPreviewVisible = false;
    await windowManager.hide();
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setMinimumSize(Size.zero);
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await TalDragPreview.setClickThrough(true);
    await windowManager.setOpacity(0.88);
    if (!_isCurrentTabDragPreview(session)) return;
    setState(() {
      detachedPanel = configuration.panel;
      detachedPanels = const <WorkspacePanelId>[];
      detachedWindowAssigned = false;
    });
    await windowManager.setSize(configuration.initialSize);
    await windowManager.setTitle(
      'Take A Look - ${configuration.panel.title} 拖动预览',
    );
  }

  Future<void> _showTabDragPreview(Offset screenPosition, int session) async {
    if (detachedPanel == null || !_isCurrentTabDragPreview(session)) return;
    await windowManager.setPosition(screenPosition);
    if (!_isCurrentTabDragPreview(session) || _tabDragPreviewVisible) return;
    _tabDragPreviewVisible = true;
    await windowManager.show(inactive: true);
  }

  Future<void> _hideTabDragPreview(int session) async {
    if (session < _tabDragPreviewSession) return;
    _tabDragPreviewSession = session;
    _tabDragPreviewActive = false;
    _tabDragPreviewVisible = false;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.hide();
  }

  bool _isCurrentTabDragPreview(int session) =>
      mounted && _tabDragPreviewActive && _tabDragPreviewSession == session;

  @override
  void onWindowClose() {
    if (widget.detachedPanel == null) return;
    if (widget.secondaryWindowRole == SecondaryWindowRole.dragPreview) {
      unawaited(_hideTabDragPreview(_tabDragPreviewSession));
    } else {
      unawaited(_releaseDetachedWindow());
    }
  }

  Future<void> _releaseDetachedWindow() async {
    if (releasingDetachedWindow) return;
    releasingDetachedWindow = true;
    try {
      if (detachedWindowAssigned) {
        await releaseDetachedWindow();
        detachedWindowAssigned = false;
      }
      await windowManager.hide();
    } finally {
      releasingDetachedWindow = false;
    }
  }

  @override
  void dispose() {
    if (widget.detachedPanel != null) windowManager.removeListener(this);
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
          : widget.secondaryWindowRole == SecondaryWindowRole.dragPreview
          ? TabContentDragPreviewWindow(
              controller: controller,
              panel: detachedPanel!,
            )
          : DetachedPanelWindow(
              controller: controller,
              panel: detachedPanel!,
              panels: detachedPanels,
            ),
    );
  }
}

/// The drag surface mirrors exactly the selected tab and its content area.
/// Group chrome and native-window chrome deliberately stay outside this tree.
class TabContentDragPreviewWindow extends StatelessWidget {
  const TabContentDragPreviewWindow({
    required this.controller,
    required this.panel,
    super.key,
  });

  final TakeALookController controller;
  final WorkspacePanelId panel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: talPanelTabStripHeight,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: TalPanelTabSurface(tab: panel, selected: true),
            ),
          ),
          Expanded(
            child: Container(
              key: const ValueKey<String>('tab-content-drag-preview-body'),
              decoration: BoxDecoration(
                color: TalColors.surface,
                border: Border.all(color: TalColors.panelBorder),
              ),
              clipBehavior: Clip.hardEdge,
              child: buildWorkspacePanelBody(panel, controller),
            ),
          ),
        ],
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
  void didUpdateWidget(covariant DetachedPanelWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panel == widget.panel && oldWidget.panels == widget.panels) {
      return;
    }
    if (!groupPanels.contains(activePanel) || oldWidget.panel != widget.panel) {
      activePanel = widget.panel;
    }
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
