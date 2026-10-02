import 'package:flutter/material.dart';

import 'controls.dart';
import 'interaction.dart';
import 'tokens.dart';

/// All modal editors use the same route and theme-controlled dialog surface.
Future<T?> showTalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: builder,
);

class TalDialog extends StatelessWidget {
  const TalDialog({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    return AlertDialog(
      title: title,
      content: content,
      actions: actions,
      scrollable: true,
      insetPadding: ui.dialogInsetPadding,
      titlePadding: ui.dialogPadding,
      contentPadding: ui.dialogPadding.copyWith(top: 0),
      actionsPadding: ui.dialogPadding.copyWith(top: 0),
    );
  }
}

/// Owns at most one desktop notice. New errors replace that notice; complete
/// history remains in the event log. Touch errors keep the confirmation route.
class TalFeedbackController {
  OverlayEntry? _entry;
  Widget? _notice;

  Future<void> showError({
    required BuildContext context,
    required String title,
    required String message,
    String? details,
  }) async {
    if (TalUiTheme.of(context).touchOptimized) {
      dismiss();
      await showTalDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => TalDialog(
          title: Text(title),
          content: SelectableText(
            details == null || details.isEmpty
                ? message
                : '$message\n\n$details',
          ),
          actions: [
            TalButton(
              variant: TalButtonVariant.text,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    final noticeKey = UniqueKey();
    _notice = _DesktopErrorNotice(
      key: noticeKey,
      title: title,
      message: message,
      details: details,
      onClose: () {
        if (_notice?.key == noticeKey) dismiss();
      },
    );
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(builder: (_) => _notice!);
    Overlay.of(context).insert(_entry!);
  }

  void dismiss() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _notice = null;
  }

  void dispose() => dismiss();
}

class _DesktopErrorNotice extends StatefulWidget {
  const _DesktopErrorNotice({
    required this.title,
    required this.message,
    required this.details,
    required this.onClose,
    super.key,
  });

  final String title;
  final String message;
  final String? details;
  final VoidCallback onClose;

  @override
  State<_DesktopErrorNotice> createState() => _DesktopErrorNoticeState();
}

class _DesktopErrorNoticeState extends State<_DesktopErrorNotice>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _dismissController;
  late final Animation<double> _entrance;
  late final Animation<double> _dismissScale;
  late final Animation<double> _dismissOpacity;
  bool _expanded = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _entrance = _entranceController.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    _dismissScale = _dismissController.drive(
      Tween<double>(begin: 1, end: 0.86).chain(
        CurveTween(curve: const Interval(0, 0.7, curve: Curves.easeOutCubic)),
      ),
    );
    _dismissOpacity = _dismissController.drive(
      Tween<double>(begin: 1, end: 0).chain(
        CurveTween(curve: const Interval(0.25, 1, curve: Curves.easeInQuad)),
      ),
    );
    _entranceController.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entranceController.value = 1;
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      widget.onClose();
      return;
    }
    setState(() => _closing = true);
    _entranceController.stop();
    try {
      await _dismissController.forward().orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted) widget.onClose();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _dismissController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = TalUiTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - ui.overlayMargin * 2).clamp(
      0.0,
      ui.notificationWidth,
    );
    // Include the outer margin, safe area, and shadow in the offscreen start.
    final slideDistance =
        width + ui.overlayMargin + MediaQuery.paddingOf(context).right + 32;
    return Positioned(
      right: ui.overlayMargin,
      bottom: ui.overlayMargin + MediaQuery.viewInsetsOf(context).bottom,
      child: SafeArea(
        child: SizedBox(
          width: width,
          child: AnimatedBuilder(
            animation: _entrance,
            builder: (context, child) => Transform.translate(
              offset: Offset(slideDistance * (1 - _entrance.value), 0),
              child: child,
            ),
            child: IgnorePointer(
              ignoring: _closing,
              child: FadeTransition(
                opacity: _dismissOpacity,
                child: ScaleTransition(
                  scale: _dismissScale,
                  child: _buildContent(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final ui = TalUiTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final hasDetails = widget.details?.isNotEmpty == true;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        key: const ValueKey('tal-error-popup'),
        color: TalColors.surfaceAlt,
        elevation: 12,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: ui.menuRadius,
          side: BorderSide(color: Theme.of(context).colorScheme.error),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                (size.height -
                        ui.overlayMargin * 2 -
                        MediaQuery.viewInsetsOf(context).bottom)
                    .clamp(0.0, ui.notificationMaxHeight),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 20,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(widget.title, style: talStrong)),
                    TalIconButton(
                      tooltip: '关闭提示',
                      onPressed: _close,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(widget.message, style: talBody),
                if (hasDetails) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TalButton(
                      variant: TalButtonVariant.text,
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(_expanded ? '收起详情' : '查看详情'),
                    ),
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 8),
                    SelectableText(widget.details!, style: talMono),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
