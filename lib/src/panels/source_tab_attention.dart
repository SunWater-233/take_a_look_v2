part of 'panel_frame.dart';

const _sourceAttentionColor = TalColors.accent;

class SourceUnreadDot extends StatelessWidget {
  const SourceUnreadDot({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '有未查看的源码文件',
    child: Container(
      width: 5,
      height: 5,
      decoration: const BoxDecoration(
        color: _sourceAttentionColor,
        shape: BoxShape.circle,
      ),
    ),
  );
}

class SourceTabAttention extends StatefulWidget {
  const SourceTabAttention({
    super.key,
    required this.controller,
    required this.builder,
  });

  final TakeALookController controller;
  final Widget Function(double attention, bool unread) builder;

  @override
  State<SourceTabAttention> createState() => _SourceTabAttentionState();
}

class _SourceTabAttentionState extends State<SourceTabAttention>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycles;
  Timer? _staticHighlightTimer;
  bool _reduceMotion = false;
  bool _staticHighlight = false;
  int _started = -1;
  int _until = -1;

  @override
  void initState() {
    super.initState();
    _cycles = AnimationController.unbounded(vsync: this);
    widget.controller.sourceWorkspaceChanges.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      _started = -1;
    }
    _sync();
  }

  @override
  void didUpdateWidget(covariant SourceTabAttention oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.sourceWorkspaceChanges.removeListener(_sync);
      widget.controller.sourceWorkspaceChanges.addListener(_sync);
      _started = -1;
      _sync();
    }
  }

  void _sync() {
    if (!mounted) return;
    final state = widget.controller.sourceWorkspace;
    final started = state.attentionStartedAtMs;
    final until = state.attentionUntilMs;
    if (started != _started || until != _until) {
      _started = started;
      _until = until;
      _cycles.stop();
      _staticHighlightTimer?.cancel();
      _staticHighlight = false;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (started > 0 && until > now && state.unreadPaths.isNotEmpty) {
        if (_reduceMotion) {
          final remaining = math.min(until, started + 1200) - now;
          if (remaining > 0) {
            _staticHighlight = true;
            _staticHighlightTimer = Timer(
              Duration(milliseconds: remaining),
              () {
                if (mounted) setState(() => _staticHighlight = false);
              },
            );
          }
        } else {
          _cycles.value = math.max(0, now - started) / 1400;
          _cycles.animateTo(
            (until - started) / 1400,
            duration: Duration(milliseconds: until - now),
            curve: Curves.linear,
          );
        }
      }
    }
    setState(() {});
  }

  double get _brightness {
    if (_reduceMotion) return _staticHighlight ? 0.7 : 0;
    if (!_cycles.isAnimating) return 0;
    final phase = _cycles.value % 1;
    if (phase < 5 / 14) {
      return Curves.easeInOutCubic.transform(phase / (5 / 14));
    }
    if (phase < 6 / 14) return 1;
    if (phase < 12.5 / 14) {
      return 1 - Curves.easeInOutCubic.transform((phase - 6 / 14) / (6.5 / 14));
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _cycles,
    builder: (context, _) => widget.builder(
      _brightness,
      widget.controller.sourceWorkspace.unreadPaths.isNotEmpty,
    ),
  );

  @override
  void dispose() {
    widget.controller.sourceWorkspaceChanges.removeListener(_sync);
    _staticHighlightTimer?.cancel();
    _cycles.dispose();
    super.dispose();
  }
}
