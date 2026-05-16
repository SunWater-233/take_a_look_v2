part of '../take_a_look_app.dart';

Future<void> runTakeALook(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final panelId = _panelIdFromEntrypointArgs(args);
  if (panelId == null) {
    runApp(const TakeALookApp());
    return;
  }

  runApp(TakeALookPanelWindowApp(panelId: panelId));
}

class TakeALookApp extends StatelessWidget {
  const TakeALookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Take A Look',
      theme: _buildTakeALookTheme(),
      home: const TakeALookHome(),
    );
  }
}

class TakeALookPanelWindowApp extends StatefulWidget {
  const TakeALookPanelWindowApp({required this.panelId, super.key});

  final WorkspacePanelId panelId;

  @override
  State<TakeALookPanelWindowApp> createState() =>
      _TakeALookPanelWindowAppState();
}

class _TakeALookPanelWindowAppState extends State<TakeALookPanelWindowApp>
    with SingleTickerProviderStateMixin {
  late final TakeALookController controller;
  late final Ticker ticker;

  @override
  void initState() {
    super.initState();
    controller = TakeALookController();
    if (widget.panelId == WorkspacePanelId.plot ||
        widget.panelId == WorkspacePanelId.watch ||
        widget.panelId == WorkspacePanelId.sampling) {
      controller.seedDemoWatches(count: 4);
    }
    ticker = createTicker(controller.pump)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Take A Look - ${_panelTitle(widget.panelId)}',
      theme: _buildTakeALookTheme(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: _standalonePanelFor(widget.panelId, controller),
          ),
        ),
      ),
    );
  }
}

class TakeALookHome extends StatefulWidget {
  const TakeALookHome({super.key});

  @override
  State<TakeALookHome> createState() => _TakeALookHomeState();
}

class _TakeALookHomeState extends State<TakeALookHome>
    with SingleTickerProviderStateMixin {
  late final TakeALookController controller;
  late final Ticker ticker;
  var workspaceGridMode = true;
  var workspaceResetVersion = 0;

  @override
  void initState() {
    super.initState();
    controller = TakeALookController();
    ticker = createTicker(controller.pump)..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopCommandBar(
              controller: controller,
              gridMode: workspaceGridMode,
              onToggleGridMode: () {
                setState(() {
                  workspaceGridMode = !workspaceGridMode;
                });
                controller.addLog(
                  workspaceGridMode ? '工作区网格模式已开启' : '工作区网格模式已关闭',
                );
              },
              onResetWorkspace: () {
                setState(() {
                  workspaceResetVersion += 1;
                });
                controller.addLog('工作区布局已重置');
              },
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 1180) {
                    return _CompactWorkspace(controller: controller);
                  }
                  return DockableWorkspace(
                    controller: controller,
                    gridMode: workspaceGridMode,
                    resetVersion: workspaceResetVersion,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactWorkspace extends StatelessWidget {
  const _CompactWorkspace({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        SizedBox(height: 236, child: ConnectionPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 520, child: LivePlotPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 420, child: WatchTablePanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(
          height: 390,
          child: SymbolBrowserPanel(controller: controller),
        ),
        const SizedBox(height: 10),
        SizedBox(height: 250, child: SamplingPanel(controller: controller)),
        const SizedBox(height: 10),
        SizedBox(height: 180, child: EventLogPanel(controller: controller)),
      ],
    );
  }
}

Widget _standalonePanelFor(
  WorkspacePanelId panelId,
  TakeALookController controller,
) {
  switch (panelId) {
    case WorkspacePanelId.connection:
      return ConnectionPanel(controller: controller);
    case WorkspacePanelId.symbols:
      return SymbolBrowserPanel(controller: controller);
    case WorkspacePanelId.plot:
      return LivePlotPanel(controller: controller);
    case WorkspacePanelId.watch:
      return WatchTablePanel(controller: controller);
    case WorkspacePanelId.sampling:
      return SamplingPanel(controller: controller);
    case WorkspacePanelId.log:
      return EventLogPanel(controller: controller);
  }
}

class TopCommandBar extends StatelessWidget {
  const TopCommandBar({
    required this.controller,
    required this.gridMode,
    required this.onToggleGridMode,
    required this.onResetWorkspace,
    super.key,
  });

  final TakeALookController controller;
  final bool gridMode;
  final VoidCallback onToggleGridMode;
  final VoidCallback onResetWorkspace;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: TalColors.topBar,
        border: Border(bottom: BorderSide(color: TalColors.border)),
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Row(
            children: [
              const Icon(Icons.tune, color: TalColors.cyan, size: 24),
              const SizedBox(width: 10),
              const Text(
                'Take A Look',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      StatusPill(
                        icon: Icons.memory,
                        label: controller.connectionPhase.label,
                        color: _phaseColor(controller.connectionPhase),
                      ),
                      StatusPill(
                        icon: Icons.insert_drive_file_outlined,
                        label: controller.symbolFileName,
                        color: TalColors.amber,
                      ),
                      StatusPill(
                        icon: Icons.speed,
                        label: controller.sampleRateLabel,
                        color: TalColors.green,
                      ),
                      StatusPill(
                        icon: Icons.timeline,
                        label: '${controller.plottedSeriesCount} 曲线',
                        color: TalColors.cyan,
                      ),
                      StatusPill(
                        icon: gridMode ? Icons.grid_on : Icons.grid_off,
                        label: gridMode ? '网格模式' : '自由布局',
                        color: gridMode ? TalColors.cyan : TalColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ToolbarButton(
                icon: Icons.folder_open,
                label: '加载 ELF/AXF',
                onPressed: controller.loadSymbols,
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: controller.toggleProbe,
                icon: Icon(
                  controller.connectionPhase == ProbeConnectionPhase.connected
                      ? Icons.link_off
                      : Icons.usb,
                  size: 18,
                ),
                label: Text(
                  controller.connectionPhase == ProbeConnectionPhase.connected
                      ? '断开探针'
                      : '连接探针',
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: gridMode ? '关闭网格模式' : '开启网格模式',
                onPressed: onToggleGridMode,
                icon: Icon(gridMode ? Icons.grid_on : Icons.grid_off),
              ),
              IconButton(
                tooltip: '重置工作区布局',
                onPressed: onResetWorkspace,
                icon: const Icon(Icons.dashboard_customize_outlined),
              ),
              IconButton(
                tooltip: '复位运行',
                onPressed: () => controller.resetTarget(halt: false),
                icon: const Icon(Icons.restart_alt),
              ),
              IconButton(
                tooltip: '导出 CSV',
                onPressed: () => controller.addLog('CSV 导出任务已创建'),
                icon: const Icon(Icons.download),
              ),
            ],
          );
        },
      ),
    );
  }
}
