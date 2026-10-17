import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../controller/controller.dart';

// Geometry belongs to the local view, never to synchronized controller state.
final _watchAnchors = Expando<Map<String, Set<_RenderWatchRowAnchor>>>();

class WatchRowAnchor extends SingleChildRenderObjectWidget {
  const WatchRowAnchor({
    required this.controller,
    required this.watchKey,
    required super.child,
    super.key,
  });

  final TakeALookController controller;
  final String watchKey;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWatchRowAnchor(controller, watchKey);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderWatchRowAnchor).update(controller, watchKey);
}

double? watchRowCenterInChart(
  TakeALookController controller,
  String? watchKey,
  RenderBox chart,
) {
  final anchors = _watchAnchors[controller]?[watchKey];
  if (anchors == null || !chart.attached || !chart.hasSize) return null;
  for (final anchor in anchors.toList().reversed) {
    final center = anchor.visibleCenterIn(chart);
    if (center != null) return center;
  }
  return null;
}

class _RenderWatchRowAnchor extends RenderProxyBox {
  _RenderWatchRowAnchor(this._controller, this._watchKey);

  TakeALookController _controller;
  String _watchKey;

  void _register() {
    final rows = _watchAnchors[_controller] ??= {};
    (rows[_watchKey] ??= {}).add(this);
  }

  void _unregister() {
    final rows = _watchAnchors[_controller];
    final anchors = rows?[_watchKey];
    anchors?.remove(this);
    if (anchors != null && anchors.isEmpty) rows!.remove(_watchKey);
  }

  void update(TakeALookController controller, String watchKey) {
    if (_controller == controller && _watchKey == watchKey) return;
    if (attached) _unregister();
    _controller = controller;
    _watchKey = watchKey;
    if (attached) _register();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }

  RenderObject _root(RenderObject object) {
    while (object.parent != null) {
      object = object.parent!;
    }
    return object;
  }

  double? visibleCenterIn(RenderBox chart) {
    if (!attached || !hasSize || _root(this) != _root(chart)) return null;
    var visible = MatrixUtils.transformRect(
      getTransformTo(chart),
      Offset.zero & size,
    );
    RenderObject child = this;
    for (var ancestor = parent; ancestor != null; ancestor = ancestor.parent) {
      if (!ancestor.paintsChild(child)) return null;
      final clip = ancestor.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(
          MatrixUtils.transformRect(ancestor.getTransformTo(chart), clip),
        );
      }
      child = ancestor;
    }
    return visible.isEmpty || !visible.isFinite ? null : visible.center.dy;
  }
}
