import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart.dart';
import 'controller.dart';
import 'models.dart';
import 'panel_types.dart';
import 'theme.dart';

Widget buildWorkspacePanel(
  WorkspacePanelId panel,
  TakeALookController controller, {
  PanelChrome? chrome,
}) {
  final body = switch (panel) {
    WorkspacePanelId.header => _HeaderPanel(controller: controller),
    WorkspacePanelId.runControl => _RunControlPanel(controller: controller),
    WorkspacePanelId.sampling => _SamplingPanel(controller: controller),
    WorkspacePanelId.symbols => _SymbolPanel(controller: controller),
    WorkspacePanelId.watch => _WatchPanel(controller: controller),
    WorkspacePanelId.connection => _ConnectionPanel(controller: controller),
    WorkspacePanelId.plot => _PlotPanel(controller: controller),
    WorkspacePanelId.log => _LogPanel(controller: controller),
  };
  return TalPanelFrame(panel: panel, chrome: chrome, child: body);
}

class TalPanelFrame extends StatefulWidget {
  const TalPanelFrame({
    required this.panel,
    required this.child,
    this.chrome,
    super.key,
  });

  final WorkspacePanelId panel;
  final Widget child;
  final PanelChrome? chrome;

  @override
  State<TalPanelFrame> createState() => _TalPanelFrameState();
}

class _TalPanelFrameState extends State<TalPanelFrame> {
  bool collapsed = false;

  @override
  Widget build(BuildContext context) {
    final chrome = widget.chrome;
    final tabs = chrome?.tabs ?? [widget.panel];
    final title = tabs.length > 1
        ? '${widget.panel.title} 组合'
        : widget.panel.title;
    return Container(
      key: ValueKey<String>('panel-frame-${widget.panel.name}'),
      decoration: BoxDecoration(
        color: TalColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: chrome?.highlighted == true
              ? TalColors.accent
              : TalColors.panelBorder,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: chrome?.onFloat,
              onPanStart: chrome?.draggable == true
                  ? chrome!.onDragStart
                  : null,
              onPanUpdate: chrome?.draggable == true
                  ? chrome!.onDragUpdate
                  : null,
              onPanEnd: chrome?.draggable == true ? chrome!.onDragEnd : null,
              child: MouseRegion(
                cursor: chrome?.draggable == true
                    ? SystemMouseCursors.grab
                    : MouseCursor.defer,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.only(left: 7, right: 4),
                  decoration: const BoxDecoration(
                    color: TalColors.surfaceAlt,
                    border: Border(bottom: BorderSide(color: TalColors.border)),
                  ),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => setState(() => collapsed = !collapsed),
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          width: 26,
                          height: 28,
                          child: Icon(
                            collapsed
                                ? Icons.keyboard_arrow_right
                                : Icons.keyboard_arrow_down,
                            size: 18,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: talStrong,
                        ),
                      ),
                      if (chrome != null && chrome.showActions)
                        IconButton(
                          tooltip: '弹出为独立窗口',
                          onPressed: chrome.onFloat,
                          icon: const Icon(Icons.open_in_new, size: 15),
                        ),
                      if (chrome != null &&
                          chrome.showActions &&
                          tabs.length > 1)
                        IconButton(
                          tooltip: '从组合中拆分当前面板',
                          onPressed: chrome.onSeparate,
                          icon: const Icon(Icons.call_split, size: 15),
                        ),
                      if (chrome != null && chrome.showActions)
                        IconButton(
                          tooltip: '隐藏面板（可从“视图”恢复）',
                          onPressed: chrome.onClose,
                          icon: const Icon(Icons.close, size: 17),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (!collapsed && tabs.length > 1)
              _PanelTabs(
                tabs: tabs,
                selected: chrome!.activePanel,
                onSelected: chrome.onSelect,
                groupId: chrome.groupId,
                draggable: chrome.tabsDraggable,
                onAccept: chrome.onTabAccept,
                onDragEnd: chrome.onTabDragEnd,
              ),
            if (!collapsed) Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }
}

class _PanelTabs extends StatelessWidget {
  const _PanelTabs({
    required this.tabs,
    required this.selected,
    required this.onSelected,
    required this.groupId,
    required this.draggable,
    required this.onAccept,
    required this.onDragEnd,
  });

  final List<WorkspacePanelId> tabs;
  final WorkspacePanelId selected;
  final ValueChanged<WorkspacePanelId> onSelected;
  final String? groupId;
  final bool draggable;
  final ValueChanged<PanelTabDragData>? onAccept;
  final void Function(PanelTabDragData, DraggableDetails)? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final tabList = ListView(
      scrollDirection: Axis.horizontal,
      children: [for (final tab in tabs) _buildTab(tab)],
    );
    if (!draggable || onAccept == null) {
      return _tabStrip(tabList);
    }
    return DragTarget<PanelTabDragData>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAccept!(details.data),
      builder: (context, candidates, rejected) =>
          _tabStrip(tabList, accepting: candidates.isNotEmpty),
    );
  }

  Widget _tabStrip(Widget child, {bool accepting = false}) {
    return Container(
      height: 30,
      color: accepting ? TalColors.surfaceAlt : TalColors.surface,
      alignment: Alignment.bottomLeft,
      child: child,
    );
  }

  Widget _buildTab(WorkspacePanelId tab) {
    final tabWidget = InkWell(
      onTap: () => onSelected(tab),
      child: _tabSurface(tab),
    );
    final sourceGroupId = groupId;
    if (!draggable || sourceGroupId == null || onDragEnd == null) {
      return tabWidget;
    }
    final data = PanelTabDragData(sourceGroupId: sourceGroupId, panel: tab);
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<PanelTabDragData>(
        data: data,
        rootOverlay: true,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () => onSelected(tab),
        onDragEnd: (details) => onDragEnd!(data, details),
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.92, child: _tabSurface(tab)),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: tabWidget),
        child: tabWidget,
      ),
    );
  }

  Widget _tabSurface(WorkspacePanelId tab) {
    return Container(
      height: 29,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tab == selected ? TalColors.surface : TalColors.surfaceAlt,
        border: Border(
          top: BorderSide(
            color: tab == selected ? TalColors.accent : TalColors.border,
            width: tab == selected ? 2 : 1,
          ),
          right: const BorderSide(color: TalColors.border),
          bottom: BorderSide(
            color: tab == selected ? TalColors.surface : TalColors.border,
          ),
        ),
      ),
      child: Center(child: Text(tab.title, style: talBody)),
    );
  }
}

class _HeaderPanel extends StatelessWidget {
  const _HeaderPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final compactHeight = constraints.maxHeight < 76;
            final narrow = constraints.maxWidth < 330;
            final logoWidth = narrow
                ? (constraints.maxWidth - 238).clamp(34.0, 58.0)
                : (constraints.maxWidth - 244).clamp(52.0, 97.0);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                narrow ? 6 : 10,
                compactHeight ? 3 : 6,
                narrow ? 5 : 9,
                compactHeight ? 3 : 6,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: logoWidth,
                    height: narrow ? 44 : (compactHeight ? 48 : 65),
                    child: const CustomPaint(painter: _BrandLogoPainter()),
                  ),
                  SizedBox(width: narrow ? 4 : 7),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: narrow ? 68 : 78,
                          child: _connectionButton(),
                        ),
                        SizedBox(width: narrow ? 4 : 8),
                        const Text('采样率', style: talBody),
                        SizedBox(width: narrow ? 3 : 7),
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 94),
                            child: _ratePicker(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _connectionButton() {
    return OutlinedButton(
      onPressed: controller.connectionStatus == ConnectionStatus.connecting
          ? null
          : controller.toggleConnection,
      child: Text(
        controller.connectionLabel,
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
  }

  Widget _ratePicker() {
    return _CompactDropdown<double>(
      value: controller.sampleRateHz,
      values: const [50, 100, 200, 500, 1000, 2000, 5000, 7000],
      label: (value) => value >= 1000
          ? '${(value / 1000).toStringAsFixed(0)} kHz'
          : '${value.toStringAsFixed(0)} Hz',
      onChanged: controller.setSampleRate,
    );
  }
}

class _BrandLogoPainter extends CustomPainter {
  const _BrandLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 486.37;
    final sy = size.height / 326.32;
    final points = <Offset>[
      const Offset(486.37, 268.67),
      const Offset(389.47, 211.02),
      const Offset(389.47, 239.66),
      const Offset(295.77, 239.66),
      const Offset(295.77, 0),
      const Offset(232.03, 0),
      const Offset(0, 0),
      const Offset(0, 59.53),
      const Offset(84.34, 59.53),
      const Offset(84.34, 206.49),
      const Offset(58.36, 206.49),
      const Offset(116.02, 303.39),
      const Offset(173.67, 206.49),
      const Offset(148.07, 206.49),
      const Offset(148.07, 59.53),
      const Offset(232.03, 59.53),
      const Offset(232.03, 297.67),
      const Offset(389.47, 297.67),
      const Offset(389.47, 326.32),
    ];
    final path = Path()..moveTo(points.first.dx * sx, points.first.dy * sy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx * sx, point.dy * sy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = TalColors.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RunControlPanel extends StatelessWidget {
  const _RunControlPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: controller.toggleConnection,
                child: Text(controller.connectionLabel),
              ),
              OutlinedButton(
                onPressed: () => controller.resetTarget(halt: false),
                child: const Text('复位运行'),
              ),
              OutlinedButton(
                onPressed: () => controller.resetTarget(halt: true),
                child: const Text('复位暂停'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SamplingPanel extends StatelessWidget {
  const _SamplingPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.elapsedLabel,
                style: const TextStyle(
                  color: TalColors.text,
                  fontFamily: talFontFamily,
                  fontFamilyFallback: talFontFamilyFallback,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  const Text('采样率', style: talBody),
                  SizedBox(
                    width: 96,
                    child: _CompactDropdown<double>(
                      value: controller.sampleRateHz,
                      values: const [50, 100, 200, 500, 1000, 2000, 5000, 7000],
                      label: _sampleRateText,
                      onChanged: controller.setSampleRate,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: controller.toggleSampling,
                    child: Text(controller.samplingPaused ? '继续采样' : '采样暂停'),
                  ),
                  OutlinedButton(
                    onPressed: controller.clearSamples,
                    child: const Text('清空采样'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: controller.rttEnabled,
                        onChanged: (value) =>
                            controller.toggleRtt(value ?? false),
                      ),
                      const Text('RTT 采样', style: talBody),
                    ],
                  ),
                ],
              ),
              if (controller.rttEnabled) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(
                      width: 82,
                      child: Text('RTT 采样率', style: talBody),
                    ),
                    SizedBox(
                      width: 112,
                      child: _CompactDropdown<double>(
                        value: controller.rttSampleRateHz,
                        values: const [
                          50,
                          100,
                          200,
                          500,
                          1000,
                          2000,
                          5000,
                          7000,
                        ],
                        label: _sampleRateText,
                        onChanged: controller.setRttSampleRate,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _sampleRateText(double value) => value >= 1000
      ? '${(value / 1000).toStringAsFixed(0)} kHz'
      : '${value.toStringAsFixed(0)} Hz';
}

class _SymbolPanel extends StatefulWidget {
  const _SymbolPanel({required this.controller});

  final TakeALookController controller;

  @override
  State<_SymbolPanel> createState() => _SymbolPanelState();
}

class _SymbolPanelState extends State<_SymbolPanel> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final symbols = widget.controller.symbols
            .where((item) => item.matches(search.text))
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        color: TalColors.input,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: TalColors.border),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.controller.symbolFile.isEmpty
                            ? '尚未读取 .elf / .axf'
                            : widget.controller.symbolFile,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.controller.symbolFile.isEmpty
                            ? talMuted
                            : talBody,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 76,
                    child: OutlinedButton(
                      onPressed: widget.controller.loadDemoSymbols,
                      child: const Text('选择文件'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    child: OutlinedButton(
                      onPressed: widget.controller.symbols.isEmpty
                          ? null
                          : widget.controller.loadDemoSymbols,
                      child: const Text('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  style: talBody,
                  decoration: const InputDecoration(
                    hintText: '按变量名或地址过滤',
                    prefixIcon: Icon(Icons.search, size: 17),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: _TableHeader(
                columns: [_ColumnSpec('来源文件 / 变量', 1), _ColumnSpec('地址', 0.46)],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: TalColors.input,
                    border: Border(
                      left: BorderSide(color: TalColors.border),
                      right: BorderSide(color: TalColors.border),
                      bottom: BorderSide(color: TalColors.border),
                    ),
                  ),
                  child: symbols.isEmpty
                      ? const SizedBox.expand()
                      : ListView.builder(
                          itemCount: symbols.length,
                          itemBuilder: (context, index) {
                            final item = symbols[index];
                            final selected = widget.controller.selectedSymbols
                                .contains(item.key);
                            return InkWell(
                              onTap: () =>
                                  widget.controller.toggleSymbol(item.key),
                              child: Container(
                                height: 42,
                                color: selected
                                    ? TalColors.selection
                                    : TalColors.input,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  children: [
                                    Checkbox(
                                      value: selected,
                                      onChanged: (_) => widget.controller
                                          .toggleSymbol(item.key),
                                    ),
                                    const Icon(
                                      Icons.data_object,
                                      size: 15,
                                      color: TalColors.accent,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: talBody,
                                          ),
                                          Text(
                                            item.source,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: talMuted,
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(
                                      width: 112,
                                      child: Text(
                                        item.addressLabel,
                                        style: talMono,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: TalColors.surface,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.controller.symbols.isEmpty
                          ? '读取完成后，变量会按来源文件分层展示。'
                          : '${widget.controller.symbols.length} 个变量，已选择 ${widget.controller.selectedSymbols.length} 个',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: talMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 160,
                    child: OutlinedButton(
                      onPressed: widget.controller.selectedSymbols.isEmpty
                          ? null
                          : widget.controller.addSelectedToWatch,
                      child: const Text('加入实时调参'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WatchPanel extends StatelessWidget {
  const _WatchPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = math.max(876.0, constraints.maxWidth);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      height: constraints.maxHeight,
                      child: Column(
                        children: [
                          const _WatchTableHeader(),
                          Expanded(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: TalColors.input,
                                border: Border(
                                  left: BorderSide(color: TalColors.border),
                                  right: BorderSide(color: TalColors.border),
                                  bottom: BorderSide(color: TalColors.border),
                                ),
                              ),
                              child: controller.watches.isEmpty
                                  ? const SizedBox.expand()
                                  : ListView.builder(
                                      itemCount: controller.watches.length,
                                      itemBuilder: (context, index) =>
                                          _WatchRow(
                                            controller: controller,
                                            watch: controller.watches[index],
                                          ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '从左侧符号层级中选择变量，然后加入实时调参。',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: talMuted,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: controller.watches.isEmpty
                      ? null
                      : controller.clearWatches,
                  child: const Text('清空监视'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WatchTableHeader extends StatelessWidget {
  const _WatchTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border.symmetric(
          horizontal: BorderSide(color: TalColors.border),
        ),
      ),
      child: const Row(
        children: [
          _WatchHeaderCell('变量', 180),
          _WatchHeaderCell('地址', 112),
          _WatchHeaderCell('类型', 96),
          _WatchHeaderCell('当前值', 96),
          _WatchHeaderCell('写入值', 96),
          _WatchHeaderCell('操作', 116),
          _WatchHeaderCell('是否绘制', 84),
          _WatchHeaderCell('绘制颜色', 96),
        ],
      ),
    );
  }
}

class _WatchHeaderCell extends StatelessWidget {
  const _WatchHeaderCell(this.label, this.width);

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: TalColors.border)),
      ),
      child: Text(label, style: talStrong),
    );
  }
}

class _WatchRow extends StatefulWidget {
  const _WatchRow({required this.controller, required this.watch});

  final TakeALookController controller;
  final WatchItem watch;

  @override
  State<_WatchRow> createState() => _WatchRowState();
}

class _WatchRowState extends State<_WatchRow> {
  late final TextEditingController editor;

  @override
  void initState() {
    super.initState();
    editor = TextEditingController(text: widget.watch.valueLabel);
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watch = widget.watch;
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: TalColors.input,
        border: Border(bottom: BorderSide(color: TalColors.borderSoft)),
      ),
      child: Row(
        children: [
          _WatchCell(
            width: 180,
            child: Text(
              watch.symbol.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: talBody,
            ),
          ),
          _WatchCell(
            width: 112,
            child: Text(watch.symbol.addressLabel, style: talMono),
          ),
          _WatchCell(
            width: 96,
            child: Text(watch.symbol.type, style: talMuted),
          ),
          _WatchCell(width: 96, child: Text(watch.valueLabel, style: talMono)),
          _WatchCell(
            width: 96,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: SizedBox(
              height: 30,
              child: TextField(controller: editor, style: talMono),
            ),
          ),
          _WatchCell(
            width: 116,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '写入',
                  onPressed: () => widget.controller.writeWatch(
                    watch.symbol.key,
                    editor.text,
                  ),
                  icon: const Icon(Icons.save_outlined, size: 16),
                ),
                IconButton(
                  tooltip: '移除',
                  onPressed: () =>
                      widget.controller.removeWatch(watch.symbol.key),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
          _WatchCell(
            width: 84,
            padding: EdgeInsets.zero,
            child: Center(
              child: Checkbox(
                value: watch.plotted,
                onChanged: (value) => widget.controller.toggleWatchPlot(
                  watch.symbol.key,
                  value ?? false,
                ),
              ),
            ),
          ),
          _WatchCell(
            width: 96,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 36,
                height: 16,
                decoration: BoxDecoration(
                  color: watch.color,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: TalColors.border),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchCell extends StatelessWidget {
  const _WatchCell({
    required this.width,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });

  final double width;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: padding,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: TalColors.borderSoft)),
      ),
      child: child,
    );
  }
}

class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _LabeledField(
              label: '探针',
              child: _CompactDropdown<String>(
                value: controller.probeType,
                values: const ['自动发现任意探针', 'CMSIS-DAP', 'ST-Link', 'J-Link'],
                label: (value) => value,
                onChanged: controller.setProbeType,
              ),
            ),
            const SizedBox(height: 10),
            _LabeledField(
              label: '目标芯片',
              child: _CompactDropdown<String>(
                value: controller.targetName,
                values: const [
                  'auto',
                  'stm32f407vg',
                  'stm32g431rb',
                  'nrf52840',
                ],
                label: (value) => value,
                onChanged: controller.setTargetName,
              ),
            ),
            const SizedBox(height: 10),
            _LabeledField(
              label: 'SWD 时钟',
              child: _CompactDropdown<String>(
                value: controller.swdClock,
                values: const [
                  '100 kHz',
                  '400 kHz',
                  '1 MHz',
                  '2 MHz',
                  '4 MHz',
                  '8 MHz',
                  '12 MHz',
                  '24 MHz',
                ],
                label: (value) => value,
                onChanged: controller.setSwdClock,
              ),
            ),
            const SizedBox(height: 10),
            _LabeledField(
              label: '序列号',
              child: TextField(
                onChanged: controller.setSerialNumber,
                style: talBody,
                decoration: const InputDecoration(hintText: '留空表示自动选择'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlotPanel extends StatelessWidget {
  const _PlotPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) => Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: TalColors.surface,
              border: Border(bottom: BorderSide(color: TalColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    controller.watches.isEmpty
                        ? '从符号列表加入变量并勾选绘制后显示曲线'
                        : '${controller.watches.where((item) => item.plotted).length} 条曲线 · ${controller.sampleRateLabel}',
                    style: talMuted,
                  ),
                ),
                OutlinedButton(
                  onPressed: controller.togglePlotting,
                  child: Text(controller.plottingPaused ? '继续绘图' : '暂停绘图'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: controller.toggleFollowLatest,
                  child: const Text('显示设置'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: controller.exportCsv,
                  child: const Text('导出原始CSV'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: TelemetryChart(controller: controller)),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: TalColors.input,
            border: Border.all(color: TalColors.border),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ListView.builder(
                  padding: const EdgeInsets.all(4),
                  itemCount: controller.logs.length,
                  itemBuilder: (context, index) {
                    final entry = controller.logs[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '[${entry.timeLabel}] ${entry.message}',
                        style: talMono,
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                right: 4,
                top: 3,
                child: IconButton(
                  tooltip: '清空日志',
                  onPressed: controller.clearLogs,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactDropdown<T> extends StatefulWidget {
  const _CompactDropdown({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;

  @override
  State<_CompactDropdown<T>> createState() => _CompactDropdownState<T>();
}

class _CompactDropdownState<T> extends State<_CompactDropdown<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final AnimationController _animationController;
  late final Animation<double> _animation;
  bool expanded = false;
  bool closing = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didUpdateWidget(covariant _CompactDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => CompositedTransformTarget(
        link: _layerLink,
        child: Semantics(
          button: true,
          expanded: expanded,
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: expanded
                ? () => unawaited(_close())
                : () => _open(constraints.maxWidth),
            child: Container(
              key: ValueKey<String>(
                'compact-dropdown-${widget.label(widget.value)}',
              ),
              height: 32,
              decoration: BoxDecoration(
                color: TalColors.input,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: TalColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      child: Text(
                        widget.label(widget.value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: talBody,
                      ),
                    ),
                  ),
                  Container(
                    width: 30,
                    height: double.infinity,
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: TalColors.borderSoft),
                      ),
                    ),
                    child: const Icon(Icons.arrow_drop_down, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _open(double width) {
    if (expanded || closing) return;
    _overlayEntry = OverlayEntry(builder: (_) => _buildOverlay(width));
    Overlay.of(context).insert(_overlayEntry!);
    setState(() => expanded = true);
    _animationController.forward(from: 0);
  }

  Widget _buildOverlay(double width) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_close()),
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 2),
          showWhenUnlinked: false,
          child: SizedBox(
            width: width,
            child: SizeTransition(
              key: const ValueKey<String>('dropdown-menu-animation'),
              sizeFactor: _animation,
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: _animation,
                child: Material(
                  color: TalColors.input,
                  elevation: 12,
                  shadowColor: Colors.black,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                    side: const BorderSide(color: TalColors.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in widget.values) _buildMenuItem(item),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem(T item) {
    return InkWell(
      key: ValueKey<String>('dropdown-item-${widget.label(item)}'),
      onTap: () => unawaited(_close(selectedValue: item)),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return TalColors.hover;
        }
        return Colors.transparent;
      }),
      child: Container(
        key: item == widget.value
            ? ValueKey<String>('dropdown-selected-${widget.label(item)}')
            : null,
        height: 32,
        width: double.infinity,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.only(left: item == widget.value ? 9 : 12, right: 8),
        decoration: BoxDecoration(
          color: item == widget.value ? TalColors.selection : TalColors.input,
          border: item == widget.value
              ? const Border(
                  left: BorderSide(color: TalColors.accent, width: 3),
                )
              : null,
        ),
        child: Text(
          widget.label(item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: talBody,
        ),
      ),
    );
  }

  Future<void> _close({T? selectedValue}) async {
    if (!expanded || closing) return;
    closing = true;
    await _animationController.reverse();
    _overlayEntry?.remove();
    _overlayEntry = null;
    closing = false;
    if (!mounted) return;
    setState(() => expanded = false);
    if (selectedValue != null) widget.onChanged(selectedValue);
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label, style: talBody)),
        Expanded(child: child),
      ],
    );
  }
}

class _ColumnSpec {
  const _ColumnSpec(this.label, this.flex);
  final String label;
  final double flex;
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.columns});

  final List<_ColumnSpec> columns;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: TalColors.surfaceAlt,
        border: Border.symmetric(
          horizontal: BorderSide(color: TalColors.border),
        ),
      ),
      child: Row(
        children: [
          for (final column in columns)
            Expanded(
              flex: (column.flex * 100).round(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: TalColors.border)),
                ),
                child: Text(column.label, style: talStrong),
              ),
            ),
        ],
      ),
    );
  }
}
