import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:tal_drag_preview/tal_drag_preview.dart';
import 'package:window_manager/window_manager.dart';

import 'title_bar.dart';
import 'workbench_chrome.dart';
import 'workbench_feedback.dart';
import '../backend/backend_client.dart';
import '../controller/controller.dart';
import '../telemetry/recording_storage.dart';
import '../workspace/keyboard_shortcuts.dart';
import '../workspace/panel_types.dart';
import '../panels/panels.dart';
import '../theme/theme.dart';
import '../workspace/window_sync.dart';
import '../workspace/workspace.dart';

export 'title_bar.dart';

class TakeALookApp extends StatefulWidget {
  const TakeALookApp({
    this.detachedPanel,
    this.detachedPanels,
    this.secondaryWindowRole = SecondaryWindowRole.detachedPanel,
    this.enableBackend = false,
    this.controller,
    this.workbenchToolbar,
    this.layoutFile,
    this.inputModeOverride,
    super.key,
  }) : assert(controller == null || (!enableBackend && detachedPanel == null));

  final WorkspacePanelId? detachedPanel;
  final List<WorkspacePanelId>? detachedPanels;
  final SecondaryWindowRole secondaryWindowRole;
  final bool enableBackend;

  /// An injected controller is owned and disposed by its caller.
  final TakeALookController? controller;
  final Widget? workbenchToolbar;
  final File? layoutFile;
  final TalInputMode? inputModeOverride;

  @override
  State<TakeALookApp> createState() => _TakeALookAppState();
}

class _TakeALookAppState extends State<TakeALookApp> with WindowListener {
  late final TakeALookController controller;
  final _recordingStorage = RecordingStorage();
  MainWindowSync? windowSync;
  BackendClient? backendClient;
  WorkspacePanelId? detachedPanel;
  List<WorkspacePanelId> detachedPanels = const <WorkspacePanelId>[];
  bool detachedWindowAssigned = false;
  bool releasingDetachedWindow = false;
  int _detachedAssignmentRevision = 0;
  int _tabDragPreviewSession = 0;
  bool _tabDragPreviewActive = false;
  bool _tabDragPreviewVisible = false;

  @override
  void initState() {
    super.initState();
    if (widget.detachedPanel == null) {
      if (widget.controller != null) {
        controller = widget.controller!;
      } else if (widget.enableBackend) {
        final client = BackendClient();
        controller = TakeALookController(
          backendCommand: client.command,
          symbolFilePicker: pickSymbolFile,
          sourceRootPicker: pickSourceRootDirectory,
          csvExportPathPicker: pickCsvExportPath,
          csvImportContentsPicker: pickCsvImportContents,
          csvImportPathPicker: kIsWeb ? null : pickCsvImportPath,
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
        csvImportContentsPicker: pickCsvImportContents,
        csvImportPathPicker: kIsWeb ? null : pickCsvImportPath,
      );
      controller = remoteController;
      controller.setPresentationActive(false);
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
          onGetWindowBounds:
              widget.secondaryWindowRole == SecondaryWindowRole.detachedPanel
              ? _getDetachedWindowBounds
              : null,
        ),
      );
    }
  }

  Future<void> _configureDetachedWindow(
    DetachedPanelLaunch configuration,
  ) async {
    if (!mounted) return;
    _detachedAssignmentRevision++;
    await windowManager.hide();
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setBackgroundColor(TalColors.background);
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
    controller.setPresentationActive(true);
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
    controller.setPresentationActive(true);
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
    if (Platform.isWindows) {
      // window_manager's Windows setPosition/show implementations activate the
      // target, including show(inactive: true). Use one non-activating operation.
      await TalDragPreview.showInactiveAt(
        screenPosition,
        devicePixelRatio: View.of(context).devicePixelRatio,
      );
      if (!_isCurrentTabDragPreview(session)) {
        await windowManager.hide();
        return;
      }
      _tabDragPreviewVisible = true;
      return;
    }
    await windowManager.setPosition(screenPosition);
    if (!_isCurrentTabDragPreview(session) || _tabDragPreviewVisible) return;
    _tabDragPreviewVisible = true;
    await windowManager.show(inactive: true);
  }

  Future<void> _hideTabDragPreview(int session) async {
    if (session < _tabDragPreviewSession) return;
    if (!_tabDragPreviewActive && !_tabDragPreviewVisible) return;
    _tabDragPreviewSession = session;
    _tabDragPreviewActive = false;
    _tabDragPreviewVisible = false;
    await windowManager.hide();
    if (session == _tabDragPreviewSession && !_tabDragPreviewActive) {
      controller.setPresentationActive(false, releaseHistory: true);
    }
  }

  Future<Rect> _getDetachedWindowBounds() async {
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    return position & size;
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
    final revision = _detachedAssignmentRevision;
    try {
      if (detachedWindowAssigned) {
        await releaseDetachedWindow();
        if (revision != _detachedAssignmentRevision) return;
        if (mounted) setState(() => detachedWindowAssigned = false);
      }
      await windowManager.hide();
      if (revision == _detachedAssignmentRevision) {
        controller.setPresentationActive(false, releaseHistory: true);
      }
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
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TalInteractionRegion(
      builder: (context, inputMode) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Take A Look',
        theme: buildTalTheme(inputMode: widget.inputModeOverride ?? inputMode),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) {
          return ValueListenableBuilder<double>(
            valueListenable: controller.uiScaleListenable,
            child: child ?? const SizedBox.shrink(),
            builder: (context, scale, child) =>
                TalUiScaleViewport(scale: scale, child: child!),
          );
        },
        home: widget.detachedPanel == null
            ? MainWorkbench(
                controller: controller,
                windowSync: windowSync!,
                layoutFile: widget.layoutFile,
                toolbar: widget.workbenchToolbar,
                recordingStorage: _recordingStorage,
              )
            : widget.secondaryWindowRole == SecondaryWindowRole.dragPreview
            ? TabContentDragPreviewWindow(
                controller: controller,
                panel: detachedPanel!,
              )
            : ExcludeFocus(
                excluding: !detachedWindowAssigned,
                child: DetachedPanelWindow(
                  controller: controller,
                  panel: detachedPanel!,
                  panels: detachedPanels,
                  assigned: detachedWindowAssigned,
                ),
              ),
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
    return ExcludeFocus(
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: TalUiTheme.of(context).panelTabStripHeight,
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
                child: buildWorkspacePanelBody(
                  panel,
                  controller,
                  sourcePreview: true,
                ),
              ),
            ),
          ],
        ),
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
    // Keep the same subtree at 100% so scaling does not recreate the workspace.
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
    this.layoutFile,
    this.toolbar,
    this.recordingStorage,
    super.key,
  });

  final TakeALookController controller;
  final MainWindowSync windowSync;
  final File? layoutFile;
  final Widget? toolbar;
  final RecordingStorage? recordingStorage;

  @override
  State<MainWorkbench> createState() => _MainWorkbenchState();
}

class _MainWorkbenchState extends State<MainWorkbench> {
  final workspaceKey = GlobalKey<DockingWorkspaceState>();
  String _shownSourceTask = '';

  @override
  void initState() {
    super.initState();
    widget.controller.sourceToolsChanges.addListener(_handleSourceTask);
  }

  @override
  void didUpdateWidget(covariant MainWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.sourceToolsChanges.removeListener(_handleSourceTask);
      widget.controller.sourceToolsChanges.addListener(_handleSourceTask);
      _shownSourceTask = '';
    }
  }

  @override
  void dispose() {
    widget.controller.sourceToolsChanges.removeListener(_handleSourceTask);
    super.dispose();
  }

  void _handleSourceTask() {
    final task = widget.controller.sourceTask;
    if (!task.running || task.id == _shownSourceTask) return;
    _shownSourceTask = task.id;
    widget.controller.workbenchOutputTab = 1;
    final workspace = workspaceKey.currentState;
    if (workspace != null && !workspace.outputDocked) {
      unawaited(workspace.toggleWorkbenchOutput());
    }
  }

  KeyEventResult _handleWorkbenchShortcut(KeyEvent event) {
    if (WorkspaceShortcut.resetUiScale.matches(event)) {
      widget.controller.setUiScale(1);
      setState(() {});
      return KeyEventResult.handled;
    }
    if (WorkspaceShortcut.saveLayout.matches(event)) {
      final workspace = workspaceKey.currentState;
      if (workspace != null) {
        unawaited(workspace.saveLayout());
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return WorkbenchFeedback(
      controller: widget.controller,
      recordingStorage: widget.recordingStorage,
      child: WorkspaceKeyboardShortcuts(
        onKeyEvent: _handleWorkbenchShortcut,
        child: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TalWindowTitleBar(
                controller: widget.controller,
                workspaceKey: workspaceKey,
                workbench: true,
                recordingStorage: widget.recordingStorage,
              ),
              if (widget.toolbar != null) widget.toolbar!,
              WorkbenchToolbar(controller: widget.controller),
              WorkbenchNavigation(workspaceKey: workspaceKey),
              Expanded(
                child: DockingWorkspace(
                  key: workspaceKey,
                  controller: widget.controller,
                  windowSync: widget.windowSync,
                  layoutFile: widget.layoutFile,
                  workbenchLayout: true,
                  onPanelVisibilityChanged: () {
                    if (mounted) setState(() {});
                  },
                ),
              ),
              WorkbenchStatusBar(
                controller: widget.controller,
                workspaceKey: workspaceKey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DetachedPanelWindow extends StatefulWidget {
  const DetachedPanelWindow({
    required this.controller,
    required this.panel,
    this.panels = const <WorkspacePanelId>[],
    this.assigned = true,
    super.key,
  });

  final TakeALookController controller;
  final WorkspacePanelId panel;
  final List<WorkspacePanelId> panels;
  final bool assigned;

  @override
  State<DetachedPanelWindow> createState() => _DetachedPanelWindowState();
}

class _DetachedPanelWindowState extends State<DetachedPanelWindow> {
  late WorkspacePanelId activePanel;
  WorkspacePanelId? _draggedPanel;
  Offset? _dragWindowOrigin;
  Offset? _lastDragPosition;
  String? _sourceWindowId;
  Future<void> _dragCommands = Future<void>.value();

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
    final chrome = PanelChrome(
      tabs: List.unmodifiable(panels),
      activePanel: activePanel,
      highlighted: false,
      onSelect: (panel) => setState(() => activePanel = panel),
      onFloat: () {},
      onClose: () {},
      onSeparate: () {},
      onDragStart: (_) => _startPanelDrag(activePanel),
      onDragUpdate: _updatePanelDrag,
      onDragEnd: (_) => _endPanelDrag(),
      showActions: false,
      draggable: panels.length == 1,
      groupId: 'detached-window',
      tabsDraggable: panels.length > 1,
      onTabDragStart: (data) => _startPanelDrag(data.panel),
      onTabDragUpdate: (_, details) => _updatePanelDrag(details),
      onTabDragEnd: (_, _) => _endPanelDrag(),
    );
    return WorkbenchFeedback(
      controller: widget.controller,
      child: WorkspaceKeyboardShortcuts(
        onKeyEvent: (event) {
          if (WorkspaceShortcut.resetUiScale.matches(event)) {
            widget.controller.setUiScale(1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
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
                    sourcePreview: !widget.assigned,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startPanelDrag(WorkspacePanelId panel) {
    _draggedPanel = panel;
    _dragWindowOrigin = null;
    _lastDragPosition = null;
    _sourceWindowId = null;
    final previewSize = context.size ?? panel.preferredWindowSize;
    _dragCommands = () async {
      final window = await WindowController.fromCurrentEngine();
      final origin = await windowManager.getPosition();
      if (_draggedPanel != panel) return;
      _sourceWindowId = window.windowId;
      _dragWindowOrigin = origin;
      await sendDetachedTabDrag(
        phase: DetachedTabDragPhase.start,
        windowId: window.windowId,
        panel: panel,
        previewSize: previewSize,
      );
    }();
  }

  void _updatePanelDrag(DragUpdateDetails details) {
    final panel = _draggedPanel;
    if (panel == null) return;
    _lastDragPosition = details.globalPosition;
    _queueDragCommand(() async {
      final windowId = _sourceWindowId;
      final origin = _dragWindowOrigin;
      final localPosition = _lastDragPosition;
      if (windowId == null || origin == null || localPosition == null) return;
      await sendDetachedTabDrag(
        phase: DetachedTabDragPhase.update,
        windowId: windowId,
        panel: panel,
        screenPosition: origin + localPosition,
      );
    });
  }

  void _endPanelDrag() {
    final panel = _draggedPanel;
    if (panel == null) return;
    final localPosition = _lastDragPosition;
    _queueDragCommand(() async {
      final windowId = _sourceWindowId;
      final origin = _dragWindowOrigin;
      if (windowId == null) return;
      await sendDetachedTabDrag(
        phase: DetachedTabDragPhase.end,
        windowId: windowId,
        panel: panel,
        screenPosition: origin != null && localPosition != null
            ? origin + localPosition
            : null,
      );
      if (_draggedPanel == panel) {
        _draggedPanel = null;
        _dragWindowOrigin = null;
        _lastDragPosition = null;
        _sourceWindowId = null;
      }
    });
  }

  void _queueDragCommand(Future<void> Function() command) {
    final previous = _dragCommands;
    _dragCommands = () async {
      try {
        await previous;
        await command();
      } on Object {
        // Losing drag feedback must not break the detached panel itself.
      }
    }();
  }
}
