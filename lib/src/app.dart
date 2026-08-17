import 'dart:async';

import 'package:flutter/material.dart';

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
