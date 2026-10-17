part of 'panels.dart';

class _WorkbenchOutput extends StatefulWidget {
  const _WorkbenchOutput({required this.controller, this.onShowSource});
  final TakeALookController controller;
  final VoidCallback? onShowSource;
  @override
  State<_WorkbenchOutput> createState() => _WorkbenchOutputState();
}

class _WorkbenchOutputState extends State<_WorkbenchOutput> {
  TakeALookController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.sourceToolsChanges,
    builder: (context, _) => Column(
      children: [
        Container(
          color: WorkbenchColors.surface,
          height: TalUiTheme.of(context).targetExtent(32),
          child: Row(
            children: [
              for (final (index, label) in ['事件日志', '编译 / 下载', '寄存器'].indexed)
                TextButton(
                  onPressed: () =>
                      setState(() => controller.workbenchOutputTab = index),
                  style: TextButton.styleFrom(
                    foregroundColor: controller.workbenchOutputTab == index
                        ? WorkbenchColors.text
                        : WorkbenchColors.muted,
                  ),
                  child: Text(label),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (controller.workbenchOutputTab) {
            1 => LayoutBuilder(
              builder: (context, constraints) => _SourceTaskOutput(
                controller: controller,
                maxHeight: constraints.maxHeight,
                embedded: true,
                onOpenLocation: (path, line) {
                  controller.revealSourceLocation(path, line);
                  widget.onShowSource?.call();
                },
              ),
            ),
            2 => AnimatedBuilder(
              animation: controller.debugChanges,
              builder: (context, _) {
                final registers = controller.debugState.registers;
                return registers.isEmpty
                    ? const Center(
                        child: Text('暂停目标后查看寄存器', style: workbenchMuted),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 24,
                          runSpacing: 12,
                          children: [
                            for (final entry in registers.entries)
                              SizedBox(
                                width: 180,
                                child: Text(
                                  '${entry.key.toUpperCase()}   ${entry.value}',
                                  style: talMono,
                                ),
                              ),
                          ],
                        ),
                      );
              },
            ),
            _ => _LogPanel(controller: controller),
          },
        ),
      ],
    ),
  );
}
