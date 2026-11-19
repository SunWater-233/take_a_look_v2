import 'package:material_ui/material_ui.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../theme/theme.dart';

class HeaderPanel extends StatelessWidget {
  const HeaderPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.connectionChanges,
        controller.samplingChanges,
      ]),
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
                        _connectionButton(),
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
    return TalButton(
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
      ),
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
    return TalDropdown<double>(
      value: controller.sampleRateHz,
      values: captureRatePresets,
      label: formatReadRate,
      editor: captureRateEditor,
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

class RunControlPanel extends StatelessWidget {
  const RunControlPanel({super.key, required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.connectionChanges,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TalButton(
                onPressed: controller.toggleConnection,
                child: Text(controller.connectionLabel),
              ),
              TalButton(
                onPressed: controller.supportsTargetControl
                    ? () => controller.resetTarget(halt: false)
                    : null,
                child: const Text('复位运行'),
              ),
              TalButton(
                onPressed: controller.supportsTargetControl
                    ? () => controller.resetTarget(halt: true)
                    : null,
                child: const Text('复位暂停'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SamplingPanel extends StatelessWidget {
  const SamplingPanel({
    super.key,
    required this.controller,
    this.showMemoryOverclock = false,
  });

  final TakeALookController controller;
  final bool showMemoryOverclock;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.samplingChanges,
        if (showMemoryOverclock) controller.connectionChanges,
      ]),
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedBuilder(
                animation: controller.clockChanges,
                builder: (context, _) => Text(
                  controller.elapsedLabel,
                  style: const TextStyle(
                    color: TalColors.text,
                    fontFamily: talFontFamily,
                    fontFamilyFallback: talFontFamilyFallback,
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
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
                    child: TalDropdown<double>(
                      value: controller.sampleRateHz,
                      values: captureRatePresets,
                      label: formatReadRate,
                      editor: captureRateEditor,
                      onChanged: controller.setSampleRate,
                    ),
                  ),
                  TalButton(
                    onPressed: controller.toggleSampling,
                    child: Text(controller.samplingPaused ? '继续采样' : '采样暂停'),
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
                      child: TalDropdown<double>(
                        value: controller.rttSampleRateHz,
                        values: captureRatePresets,
                        label: formatReadRate,
                        editor: captureRateEditor,
                        onChanged: controller.setRttSampleRate,
                      ),
                    ),
                  ],
                ),
              ],
              if (showMemoryOverclock) ...[
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 4),
                _MemoryOverclockSetting(controller: controller),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryOverclockSetting extends StatelessWidget {
  const _MemoryOverclockSetting({required this.controller});

  final TakeALookController controller;

  @override
  Widget build(BuildContext context) {
    final available =
        controller.connectionKind == 'local' &&
        (controller.connectionStatus != ConnectionStatus.connected ||
            controller.memoryPipelineDepth > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: const ValueKey('memory-overclock'),
          value: available && controller.memoryOverclock,
          onChanged: available
              ? (value) => controller.setMemoryOverclock(value == true)
              : null,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            '超频模式',
            style: available
                ? talBody
                : talBody.copyWith(color: TalColors.muted),
          ),
        ),
        const Text(
          '本地 CMSIS-DAP（HID 或 Bulk）可批量读取 RAM，并按探针能力同时排队最多 4 个读包。读取按设定采样率调度。',
          style: talMuted,
        ),
        const SizedBox(height: 6),
        Text(
          '批内样本共用一个时间窗口，间隔可能不均匀。高负载时可能出现读取超时或调试响应变慢。',
          style: talMuted.copyWith(color: TalColors.warning),
        ),
        if (!available) ...[
          const SizedBox(height: 6),
          const Text('超频模式仅适用于本地 CMSIS-DAP。', style: talMuted),
        ],
      ],
    );
  }
}
