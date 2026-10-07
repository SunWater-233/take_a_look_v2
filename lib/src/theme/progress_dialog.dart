import 'package:flutter/material.dart';

import 'feedback.dart';
import 'interaction.dart';
import 'tokens.dart';

/// Shared progress surface; the caller owns work, dismissal, and input-mode lock.
class TalProgressDialog extends StatelessWidget {
  const TalProgressDialog({
    required this.title,
    required this.fileName,
    required this.phase,
    required this.step,
    required this.elapsed,
    this.value,
    this.current = 0,
    this.total = 0,
    super.key,
  });

  final String title;
  final String fileName;
  final String phase;
  final int step;
  final Duration elapsed;
  final double? value;
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    final touch = ui.touchOptimized;
    final text = Theme.of(context).dialogTheme.contentTextStyle ?? talBody;
    final muted = text.copyWith(
      color: TalColors.muted,
      fontSize: touch ? 14 : 12,
      fontWeight: FontWeight.w400,
    );
    final count = Text(
      total > 0 ? '已处理 $current / $total' : '处理中',
      style: touch ? text : muted,
    );
    final stepText = Text('阶段 $step / 5', style: muted);
    final elapsedText = Text(
      '已用时 ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
      style: muted,
    );
    return PopScope(
      canPop: false,
      child: TalDialog(
        title: Text(title),
        actions: const [],
        content: SizedBox(
          width: ui.progressDialogWidth - ui.dialogPadding.horizontal,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(fileName, style: text.copyWith(color: TalColors.muted)),
              SizedBox(height: touch ? 28 : 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(phase, style: text),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    value == null ? '处理中' : '${(value! * 100).floor()}%',
                    style: text,
                  ),
                ],
              ),
              SizedBox(height: touch ? 16 : 12),
              LinearProgressIndicator(
                value: value,
                minHeight: ui.progressIndicatorHeight,
                color: value == 1 && step == 5
                    ? TalColors.success
                    : TalColors.accent,
                backgroundColor: TalColors.borderSoft,
                borderRadius: BorderRadius.circular(4),
                semanticsLabel: phase,
                semanticsValue: value == null
                    ? '处理中'
                    : '${(value! * 100).floor()}%',
              ),
              SizedBox(height: touch ? 16 : 12),
              if (touch) ...[
                count,
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(child: stepText),
                    elapsedText,
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(child: count),
                    const SizedBox(width: 12),
                    stepText,
                  ],
                ),
                const SizedBox(height: 5),
                elapsedText,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
