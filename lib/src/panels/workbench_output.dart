part of 'source_debug_panel.dart';

class BuildOutputPanel extends StatelessWidget {
  const BuildOutputPanel({
    super.key,
    required this.controller,
    this.onShowSource,
  });

  final TakeALookController controller;
  final VoidCallback? onShowSource;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _SourceTaskOutput(
      controller: controller,
      // The output container's top border consumes one pixel.
      maxHeight: math.max(0, constraints.maxHeight - 1),
      embedded: true,
      onOpenLocation: (path, line) {
        controller.revealSourceLocation(path, line);
        onShowSource?.call();
      },
    ),
  );
}

class RegistersPanel extends StatelessWidget {
  const RegistersPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.debugChanges,
    builder: (context, _) {
      final registers = controller.debugState.registers;
      return registers.isEmpty
          ? const Center(child: Text('暂停目标后查看寄存器', style: workbenchMuted))
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
  );
}
