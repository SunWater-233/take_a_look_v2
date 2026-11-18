import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../theme/theme.dart';
import 'axis_settings.dart';
import 'viewport.dart';

class PlotRangeMenu extends StatefulWidget {
  const PlotRangeMenu({
    required this.controller,
    required this.viewport,
    required this.autofocus,
    required this.rectangleZoom,
    required this.onRectangleZoomChanged,
    super.key,
  });

  final TakeALookController controller;
  final TelemetryViewport Function() viewport;
  final bool autofocus;
  final bool rectangleZoom;
  final ValueChanged<bool> onRectangleZoomChanged;

  @override
  State<PlotRangeMenu> createState() => _PlotRangeMenuState();
}

class _PlotRangeMenuState extends State<PlotRangeMenu> {
  static const _axisLabelWidth = 24.0;

  late final _RangeEditor _x;
  late final _RangeEditor _y;
  bool _advanced = false;
  TakeALookController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final viewport = widget.viewport();
    _x = _RangeEditor(
      automatic: _controller.followLatest,
      minimum: viewport.xMin,
      maximum: viewport.xMax,
      inverted: _controller.plotInvertX,
      mouseEnabled: _controller.plotMouseXEnabled,
      minimumAllowed: 0,
    );
    _y = _RangeEditor(
      automatic: _controller.plotAutoY,
      minimum: viewport.yMin,
      maximum: viewport.yMax,
      inverted: _controller.plotInvertY,
      mouseEnabled: _controller.plotMouseYEnabled,
    );
    _controller.plotChanges.addListener(_sync);
  }

  @override
  void didUpdateWidget(PlotRangeMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _controller) {
      oldWidget.controller.plotChanges.removeListener(_sync);
      _controller.plotChanges.addListener(_sync);
    }
  }

  @override
  void dispose() {
    _controller.plotChanges.removeListener(_sync);
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  void _sync() {
    final viewport = widget.viewport();
    _x.sync(viewport.xMin, viewport.xMax);
    _y.sync(viewport.yMin, viewport.yMax);
    if (_x.settings.automatic != _controller.followLatest ||
        _y.settings.automatic != _controller.plotAutoY ||
        _x.settings.inverted != _controller.plotInvertX ||
        _y.settings.inverted != _controller.plotInvertY ||
        _x.settings.mouseEnabled != _controller.plotMouseXEnabled ||
        _y.settings.mouseEnabled != _controller.plotMouseYEnabled) {
      setState(() {
        _x.settings
          ..automatic = _controller.followLatest
          ..inverted = _controller.plotInvertX
          ..mouseEnabled = _controller.plotMouseXEnabled;
        _y.settings
          ..automatic = _controller.plotAutoY
          ..inverted = _controller.plotInvertY
          ..mouseEnabled = _controller.plotMouseYEnabled;
      });
    }
  }

  void _setAutomatic({required bool xAxis, required bool value}) {
    final editor = xAxis ? _x : _y;
    setState(editor.clearDraft);
    if (xAxis) {
      _controller.configurePlotView({'followLatest': value});
    } else {
      final viewport = widget.viewport();
      _controller.configurePlotView({
        'plotAutoY': value,
        if (!value) 'yMin': viewport.yMin,
        if (!value) 'yMax': viewport.yMax,
      });
    }
    final viewport = widget.viewport();
    editor.sync(
      xAxis ? viewport.xMin : viewport.yMin,
      xAxis ? viewport.xMax : viewport.yMax,
      force: true,
    );
  }

  void _fitAll() {
    setState(() {
      _x.clearDraft();
      _y.clearDraft();
    });
    _controller.showAllPlotSamples();
    _refreshCommittedValues();
  }

  void _refreshCommittedValues() {
    final viewport = widget.viewport();
    _x.sync(viewport.xMin, viewport.xMax, force: true);
    _y.sync(viewport.yMin, viewport.yMax, force: true);
  }

  void _apply() {
    if (!_x.dirty && !_y.dirty) return;
    final x = _x.dirty ? _x.settings.validate(xAxis: true) : null;
    final y = _y.dirty ? _y.settings.validate(xAxis: false) : null;
    if (x != null && x.maximum - x.minimum < 0.2 - 1e-9) {
      _x.settings.errorText = '时间范围至少为 0.2 秒。';
    }
    if (_x.settings.errorText != null || _y.settings.errorText != null) {
      setState(() {});
      return;
    }
    setState(() {
      _x.clearDraft();
      _y.clearDraft();
    });
    _controller.configurePlotView({
      if (x != null) ...{
        'followLatest': false,
        'xMin': x.minimum,
        'xMax': x.maximum,
      },
      if (y != null) ...{
        'plotAutoY': false,
        'yMin': y.minimum,
        'yMax': y.maximum,
      },
    });
    _refreshCommittedValues();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('plot-range-menu'),
      width: math.min(304, MediaQuery.sizeOf(context).width - 24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('显示范围', style: talStrong)),
                TalButton(onPressed: _fitAll, child: const Text('适配全部')),
              ],
            ),
            const SizedBox(height: 8),
            const Row(
              children: [
                SizedBox(width: _axisLabelWidth),
                Expanded(child: Text('下限', style: talMuted)),
                SizedBox(width: 6),
                Expanded(child: Text('上限', style: talMuted)),
                SizedBox(width: 91),
              ],
            ),
            const SizedBox(height: 5),
            _axisRow(xAxis: true, editor: _x),
            const SizedBox(height: 6),
            _axisRow(xAxis: false, editor: _y),
            const SizedBox(height: 8),
            const Divider(height: 1, color: TalColors.border),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TalButton(
                  variant: TalButtonVariant.text,
                  onPressed: () => setState(() => _advanced = !_advanced),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _advanced ? Icons.expand_more : Icons.chevron_right,
                        size: 16,
                        color: TalColors.muted,
                      ),
                      const Text('轴与鼠标设置', style: talMuted),
                    ],
                  ),
                ),
                TalButton(
                  variant: TalButtonVariant.filled,
                  onPressed: _x.dirty || _y.dirty ? _apply : null,
                  child: const Text('应用'),
                ),
              ],
            ),
            if (_advanced) ...[
              const SizedBox(height: 6),
              const Divider(height: 1, color: TalColors.border),
              _axisOptions(xAxis: true, editor: _x),
              _axisOptions(xAxis: false, editor: _y),
              Row(
                children: [
                  const Text('拖动方式', style: talMuted),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 118,
                    height: TalUiTheme.of(context).controlHeight,
                    child: TalDropdown<bool>(
                      value: widget.rectangleZoom,
                      values: const [false, true],
                      label: (rectangle) => rectangle ? '框选缩放' : '平移',
                      onChanged: widget.onRectangleZoomChanged,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _axisRow({required bool xAxis, required _RangeEditor editor}) {
    final draft = editor.settings;
    final axis = xAxis ? 'X' : 'Y';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: _axisLabelWidth,
              child: Text(axis, style: talMono),
            ),
            Expanded(child: _field(editor, axis, maximum: false)),
            const SizedBox(width: 6),
            Expanded(child: _field(editor, axis, maximum: true)),
            const SizedBox(width: 6),
            SizedBox(
              width: 85,
              child: _check(
                xAxis ? '跟随最新' : '自动适配',
                draft.automatic,
                (value) => _setAutomatic(xAxis: xAxis, value: value),
              ),
            ),
          ],
        ),
        if (draft.errorText case final error?)
          Padding(
            padding: const EdgeInsets.only(left: _axisLabelWidth, top: 3),
            child: Text(
              error,
              style: talMuted.copyWith(color: TalColors.error),
            ),
          ),
      ],
    );
  }

  Widget _field(_RangeEditor editor, String axis, {required bool maximum}) {
    final draft = editor.settings;
    final bound = maximum ? '上限' : '下限';
    return SizedBox(
      height: 31,
      child: Semantics(
        label: '$axis 轴$bound',
        child: TextField(
          key: ValueKey(
            'plot-range-${axis.toLowerCase()}-${maximum ? 'max' : 'min'}',
          ),
          controller: maximum
              ? draft.maximumController
              : draft.minimumController,
          focusNode: maximum ? editor.maxFocus : editor.minFocus,
          autofocus: widget.autofocus && axis == 'X' && !maximum,
          textAlign: TextAlign.right,
          style: talMono,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {
            editor.dirty = true;
            draft.errorText = null;
          }),
          onSubmitted: (_) => _apply(),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          ),
        ),
      ),
    );
  }

  Widget _axisOptions({required bool xAxis, required _RangeEditor editor}) {
    final axis = xAxis ? 'X' : 'Y';
    return Row(
      children: [
        SizedBox(width: 38, child: Text('$axis 轴', style: talMuted)),
        _check('反转轴', editor.settings.inverted, (value) {
          _controller.configurePlotView({'plotInvert$axis': value});
        }),
        const SizedBox(width: 12),
        _check('鼠标控制', editor.settings.mouseEnabled, (value) {
          _controller.configurePlotView({'plotMouse${axis}Enabled': value});
        }),
      ],
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      canRequestFocus: false,
      excludeFromSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 31,
            child: Semantics(
              label: label,
              child: Checkbox(
                value: value,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: (next) => onChanged(next ?? false),
              ),
            ),
          ),
          Text(label, style: talMuted),
        ],
      ),
    );
  }
}

class _RangeEditor {
  _RangeEditor({
    required bool automatic,
    required double minimum,
    required double maximum,
    required bool inverted,
    required bool mouseEnabled,
    double? minimumAllowed,
  }) : settings = AxisSettingsDraft(
         automatic: automatic,
         minimum: minimum,
         maximum: maximum,
         inverted: inverted,
         mouseEnabled: mouseEnabled,
         minimumAllowed: minimumAllowed,
         format: _format,
       );

  final AxisSettingsDraft settings;
  final minFocus = FocusNode();
  final maxFocus = FocusNode();
  bool dirty = false;

  static String _format(double value) {
    final magnitude = value.abs();
    if (magnitude >= 1e6 || (magnitude > 0 && magnitude < 1e-4)) {
      return value.toStringAsExponential(4);
    }
    return value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  void sync(double minimum, double maximum, {bool force = false}) {
    if (!force && (dirty || minFocus.hasFocus || maxFocus.hasFocus)) return;
    final lower = _format(minimum);
    final upper = _format(maximum);
    if (settings.minimumController.text != lower) {
      settings.minimumController.text = lower;
    }
    if (settings.maximumController.text != upper) {
      settings.maximumController.text = upper;
    }
  }

  void clearDraft() {
    dirty = false;
    settings.errorText = null;
  }

  void dispose() {
    minFocus.dispose();
    maxFocus.dispose();
    settings.dispose();
  }
}
