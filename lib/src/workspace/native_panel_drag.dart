import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tal_drag_preview/tal_drag_preview.dart';

import 'panel_transfer.dart';
import 'panel_types.dart';
import '../theme/theme.dart';

export 'panel_transfer.dart';

class NativePanelDragHost extends StatefulWidget {
  const NativePanelDragHost({
    required this.isMainWindow,
    required this.onTransfer,
    required this.child,
    this.windowId,
    super.key,
  });
  final bool isMainWindow;
  final Future<bool> Function(NativePanelTransfer) onTransfer;
  final Widget child;
  final String? windowId;

  @override
  State<NativePanelDragHost> createState() => NativePanelDragHostState();
}

class NativePanelDragHostState extends State<NativePanelDragHost> {
  Future<String>? _windowId;
  List<_NativePanelDropRegionState> _hovered = [];
  Timer? _leaveTimer;
  NativePanelPayload? _activePayload;
  bool _sourceActive = false;

  void sourceStarted(NativePanelPayload payload) {
    _sourceActive = true;
    setState(() => _activePayload = payload);
  }

  void sourceEnded() {
    _sourceActive = false;
    if (mounted) setState(() => _activePayload = null);
  }

  Future<String> get windowId => _windowId ??= widget.windowId != null
      ? Future.value(widget.windowId!)
      : WindowController.fromCurrentEngine().then((window) => window.windowId);

  @override
  void initState() {
    super.initState();
    if (TalDragPreview.nativeWayland) {
      TalDragPreview.setNativeDragHandler(_handleDrag);
    }
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    if (TalDragPreview.nativeWayland) TalDragPreview.setNativeDragHandler(null);
    super.dispose();
  }

  List<_NativePanelDropRegionState> _regionsAt(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    return [
      for (final entry in result.path)
        if (entry.target case RenderMetaData(
          metaData: final _NativePanelDropRegionState region,
        ))
          if (region.mounted) region,
    ];
  }

  Future<bool> _handleDrag(
    String phase,
    Map<Object?, Object?> arguments,
  ) async {
    final payload = NativePanelPayload.parse(arguments['payload']);
    if (!mounted || payload == null) return false;
    if (phase == 'leave') {
      // GTK emits leave immediately before drop too. Keep dwell deadlines for
      // that final drop, while promptly clearing a real exit to another window.
      _leaveTimer?.cancel();
      _leaveTimer = Timer(const Duration(milliseconds: 50), () {
        for (final region in _hovered) {
          if (region.mounted) region.widget.onLeave?.call();
        }
        _hovered = [];
        if (mounted && !_sourceActive) setState(() => _activePayload = null);
      });
      return true;
    }
    _leaveTimer?.cancel();
    if (_activePayload?.windowId != payload.windowId ||
        _activePayload?.panel != payload.panel) {
      setState(() => _activePayload = payload);
    }
    final x = arguments['x'];
    final y = arguments['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return false;
    final position = Offset(x.toDouble(), y.toDouble());
    final regions = _regionsAt(position);
    for (final previous in _hovered) {
      if (previous.mounted && !regions.contains(previous)) {
        previous.widget.onLeave?.call();
      }
    }
    _hovered = regions;
    // The outer workspace updates dwell/edge state before its inner tab strip.
    for (final region in regions.reversed) {
      region.widget.onMove?.call(payload, position);
    }
    if (phase == 'motion') return regions.isNotEmpty;
    if (phase != 'drop') return false;
    try {
      for (final region in regions) {
        final handler = region.widget.onDrop;
        if (handler != null && await handler(payload, position)) return true;
      }
      return false;
    } finally {
      for (final region in regions) {
        if (region.mounted) region.widget.onLeave?.call();
      }
      _hovered = [];
      if (mounted && !_sourceActive) setState(() => _activePayload = null);
    }
  }

  Future<bool> transfer(
    NativePanelPayload payload, {
    String? groupId,
    int? insertionIndex,
    WorkspaceDockEdge? dockEdge,
  }) async {
    final id = await windowId;
    if (!mounted) return false;
    return widget.onTransfer(
      NativePanelTransfer(
        source: payload,
        targetWindowId: id,
        targetIsMainWindow: widget.isMainWindow,
        targetGroupId: groupId,
        insertionIndex: insertionIndex,
        dockEdge: dockEdge,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TalDragPreview.nativeWayland
      ? _NativePanelScope(
          host: this,
          child: Stack(
            children: [
              Positioned.fill(child: widget.child),
              if (_activePayload != null)
                Positioned(
                  top: 7,
                  left: 0,
                  right: 0,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: NativePanelDropRegion(
                      onDrop: (payload, _) => widget.onTransfer(
                        NativePanelTransfer(
                          source: payload,
                          targetWindowId: 'new',
                          targetIsMainWindow: false,
                        ),
                      ),
                      child: Material(
                        key: const ValueKey('native-panel-detach-target'),
                        color: TalColors.surfaceAlt,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(color: TalColors.accent),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.open_in_new,
                                color: TalColors.accent,
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Text('弹出为独立窗口', style: talBody),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        )
      : widget.child;
}

class _NativePanelScope extends InheritedWidget {
  const _NativePanelScope({required this.host, required super.child});
  final NativePanelDragHostState host;
  @override
  bool updateShouldNotify(_NativePanelScope oldWidget) =>
      host != oldWidget.host;
}

NativePanelDragHostState? nativePanelDragHostOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_NativePanelScope>()?.host;

class NativePanelDropRegion extends StatefulWidget {
  const NativePanelDropRegion({
    required this.child,
    this.onMove,
    this.onLeave,
    this.onDrop,
    super.key,
  });
  final Widget child;
  final void Function(NativePanelPayload, Offset)? onMove;
  final VoidCallback? onLeave;
  final Future<bool> Function(NativePanelPayload, Offset)? onDrop;
  @override
  State<NativePanelDropRegion> createState() => _NativePanelDropRegionState();
}

class _NativePanelDropRegionState extends State<NativePanelDropRegion> {
  @override
  Widget build(BuildContext context) => TalDragPreview.nativeWayland
      ? MetaData(
          metaData: this,
          behavior: HitTestBehavior.translucent,
          child: widget.child,
        )
      : widget.child;
}

/// Captures the selected tab and body, without native chrome or other tabs.
class NativePanelPreview extends InheritedWidget {
  const NativePanelPreview({
    required this.bodyKey,
    required super.child,
    super.key,
  });
  final GlobalKey bodyKey;
  static NativePanelPreview? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NativePanelPreview>();
  @override
  bool updateShouldNotify(NativePanelPreview oldWidget) =>
      bodyKey != oldWidget.bodyKey;

  Future<Uint8List?> capture(GlobalKey tabKey, double pixelRatio) async {
    final body = bodyKey.currentContext?.findRenderObject();
    final tab = tabKey.currentContext?.findRenderObject();
    if (body is! RenderRepaintBoundary || tab is! RenderRepaintBoundary) {
      return null;
    }
    var needsPaint = false;
    assert(() {
      needsPaint = body.debugNeedsPaint || tab.debugNeedsPaint;
      return true;
    }());
    if (needsPaint) return null;
    final bodyImage = await body.toImage(pixelRatio: pixelRatio);
    final tabImage = await tab.toImage(pixelRatio: pixelRatio);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = bodyImage.width;
    final height = bodyImage.height + tabImage.height;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xff171b23),
    );
    canvas.drawImage(tabImage, Offset.zero, Paint());
    canvas.drawImage(bodyImage, Offset(0, tabImage.height.toDouble()), Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    bodyImage.dispose();
    tabImage.dispose();
    return bytes?.buffer.asUint8List();
  }
}

class NativePanelDragSource extends StatefulWidget {
  const NativePanelDragSource({
    required this.data,
    required this.child,
    required this.onStart,
    required this.onEnd,
    required this.tabKey,
    super.key,
  });
  final PanelTabDragData data;
  final Widget child;
  final VoidCallback onStart;
  final void Function(bool accepted) onEnd;
  final GlobalKey tabKey;
  @override
  State<NativePanelDragSource> createState() => _NativePanelDragSourceState();
}

class _NativePanelDragSourceState extends State<NativePanelDragSource> {
  bool _dragging = false;

  Future<void> _start() async {
    if (TalDragPreview.debugNativeDrag) {
      debugPrint('Native tab drag start: ${widget.data.panel.name}');
    }
    if (_dragging) return;
    final host = nativePanelDragHostOf(context);
    if (host == null) return;
    _dragging = true;
    // Cache inherited values before selecting a tab can rebuild the source.
    final preview = NativePanelPreview.of(context);
    final ratio =
        View.of(context).devicePixelRatio *
        (context.findRenderObject()?.getTransformTo(null).getMaxScaleOnAxis() ??
            1);
    final data = widget.data;
    final end = widget.onEnd;
    widget.onStart();
    var outcome = 'cancelled';
    try {
      final id = await host.windowId;
      final payload = NativePanelPayload(
        windowId: id,
        fromMainWindow: host.widget.isMainWindow,
        groupId: data.sourceGroupId,
        panel: data.panel,
      );
      host.sourceStarted(payload);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Uint8List? png;
      try {
        png = await preview?.capture(widget.tabKey, ratio);
      } on Object {
        // A transient repaint must not prevent the native drag itself.
      }
      if (!mounted) return;
      outcome = await TalDragPreview.beginNativeTabDrag({
        'payload': payload.toJson(),
        'png': ?png,
      });
    } on Object catch (error) {
      // A lost source, released pointer or cancelled native drag keeps the panel.
      debugPrint('Native panel drag failed: $error');
    } finally {
      _dragging = false;
      host.sourceEnded();
      end(outcome != 'outside');
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanDown: TalDragPreview.debugNativeDrag
        ? (_) => debugPrint('Native tab press: ${widget.data.panel.name}')
        : null,
    onPanStart: (_) => unawaited(_start()),
    child: widget.child,
  );
}
