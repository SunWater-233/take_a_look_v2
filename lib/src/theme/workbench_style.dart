import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

export '../models/frequency.dart' show formatReadRate;

abstract final class WorkbenchColors {
  static const background = TalColors.background;
  static const surface = TalColors.surface;
  static const raised = TalColors.surfaceAlt;
  static const input = TalColors.input;
  static const border = TalColors.border;
  static const text = TalColors.text;
  static const heading = TalColors.heading;
  static const muted = TalColors.muted;
  static const selection = TalColors.selection;
  static const accent = TalColors.accent;
  static const success = TalColors.success;
}

enum WorkbenchToolbarAttachment { start, end, stretch }

class WorkbenchToolbarOutline extends StatelessWidget {
  const WorkbenchToolbarOutline({
    required this.attachment,
    required this.child,
    super.key,
  });

  final WorkbenchToolbarAttachment attachment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    BorderRadiusDirectional radius(double value) => switch (attachment) {
      WorkbenchToolbarAttachment.start => BorderRadiusDirectional.only(
        bottomEnd: Radius.circular(value),
      ),
      WorkbenchToolbarAttachment.end => BorderRadiusDirectional.only(
        bottomStart: Radius.circular(value),
      ),
      WorkbenchToolbarAttachment.stretch => BorderRadiusDirectional.zero,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkbenchColors.border,
        borderRadius: radius(11),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: attachment == WorkbenchToolbarAttachment.end ? 1 : 0,
          end: attachment == WorkbenchToolbarAttachment.start ? 1 : 0,
          bottom: 1,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: WorkbenchColors.surface,
            borderRadius: radius(10),
          ),
          child: child,
        ),
      ),
    );
  }
}

const workbenchBody = TextStyle(
  fontFamily: 'MiSans',
  fontSize: 13,
  color: WorkbenchColors.text,
);
const workbenchMuted = TextStyle(
  fontFamily: 'MiSans',
  fontSize: 12,
  color: WorkbenchColors.muted,
);
