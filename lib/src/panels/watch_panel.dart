part of '../panels.dart';

class _WatchPanel extends StatelessWidget {
  const _WatchPanel({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.watchChanges,
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
                                            key: ValueKey<String>(
                                              controller
                                                  .watches[index]
                                                  .symbol
                                                  .key,
                                            ),
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
  const _WatchRow({required this.controller, required this.watch, super.key});

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
          _WatchCell(
            width: 96,
            child: AnimatedBuilder(
              animation: widget.controller.telemetryChanges,
              builder: (context, _) =>
                  Text(widget.watch.valueLabel, style: talMono),
            ),
          ),
          _WatchCell(
            width: 96,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: editor,
                enabled: watch.symbol.writable,
                style: talMono,
              ),
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
                  onPressed: watch.symbol.writable
                      ? () => widget.controller.writeWatch(
                          watch.symbol.key,
                          editor.text,
                        )
                      : null,
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
