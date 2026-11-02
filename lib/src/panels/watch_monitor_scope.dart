part of 'watch_panel.dart';

/// A view owns its demand even when its rows are virtualized or kept offstage.
/// Registering demand has no synchronous UI notifications; the controller merges
/// all changes in this frame before sending a lightweight backend update.
class _WatchMonitorScope extends StatefulWidget {
  const _WatchMonitorScope({
    required this.controller,
    required this.keys,
    required this.child,
  });

  final TakeALookController controller;
  final Set<String> keys;
  final Widget child;

  @override
  State<_WatchMonitorScope> createState() => _WatchMonitorScopeState();
}

class _WatchMonitorScopeState extends State<_WatchMonitorScope> {
  late final String _scope =
      'watch-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    widget.controller.setWatchMonitorScope(_scope, widget.keys);
  }

  @override
  void didUpdateWidget(covariant _WatchMonitorScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.setWatchMonitorScope(_scope, null);
    }
    widget.controller.setWatchMonitorScope(_scope, widget.keys);
  }

  @override
  void dispose() {
    widget.controller.setWatchMonitorScope(_scope, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
