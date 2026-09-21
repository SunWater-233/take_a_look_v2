import 'package:flutter/material.dart';

class AxisSettings {
  const AxisSettings({
    required this.automatic,
    required this.minimum,
    required this.maximum,
    required this.mouseEnabled,
    required this.inverted,
  });

  final bool automatic;
  final double minimum;
  final double maximum;
  final bool mouseEnabled;
  final bool inverted;
}

/// Mutable editor shared by the desktop submenu and touch-friendly dialog.
/// Validation and text parsing live here so both presentations obey exactly
/// the same axis invariants.
class AxisSettingsDraft {
  AxisSettingsDraft({
    required this.automatic,
    required double minimum,
    required double maximum,
    required this.mouseEnabled,
    required this.inverted,
    this.minimumAllowed,
    String Function(double value)? format,
  }) : minimumController = TextEditingController(
         text: (format ?? _defaultFormat)(minimum),
       ),
       maximumController = TextEditingController(
         text: (format ?? _defaultFormat)(maximum),
       );

  bool automatic;
  bool mouseEnabled;
  bool inverted;
  final double? minimumAllowed;
  final TextEditingController minimumController;
  final TextEditingController maximumController;
  String? errorText;

  AxisSettings? validate({required bool xAxis}) {
    final minimum = double.tryParse(minimumController.text.trim());
    final maximum = double.tryParse(maximumController.text.trim());
    if (minimum == null ||
        maximum == null ||
        !minimum.isFinite ||
        !maximum.isFinite ||
        maximum <= minimum ||
        (minimumAllowed != null && minimum < minimumAllowed!)) {
      errorText = minimumAllowed == null
          ? '请输入有效范围，最大值必须大于最小值。'
          : '请输入有效范围，且最小值不能小于 ${_defaultFormat(minimumAllowed!)}。';
      return null;
    }
    errorText = null;
    return AxisSettings(
      automatic: automatic,
      minimum: minimum,
      maximum: maximum,
      mouseEnabled: mouseEnabled,
      inverted: inverted,
    );
  }

  void dispose() {
    minimumController.dispose();
    maximumController.dispose();
  }

  static String _defaultFormat(double value) => value.toStringAsFixed(4);
}

class PlotAxisSettingsDialog extends StatefulWidget {
  const PlotAxisSettingsDialog({
    required this.xAxis,
    required this.automatic,
    required this.minimum,
    required this.maximum,
    required this.mouseEnabled,
    required this.inverted,
    this.minimumAllowed,
    super.key,
  });

  final bool xAxis;
  final bool automatic;
  final double minimum;
  final double maximum;
  final bool mouseEnabled;
  final bool inverted;
  final double? minimumAllowed;

  @override
  State<PlotAxisSettingsDialog> createState() => PlotAxisSettingsDialogState();
}

class PlotAxisSettingsDialogState extends State<PlotAxisSettingsDialog> {
  late final AxisSettingsDraft draft;

  bool get automatic => draft.automatic;
  set automatic(bool value) => draft.automatic = value;
  bool get mouseEnabled => draft.mouseEnabled;
  set mouseEnabled(bool value) => draft.mouseEnabled = value;
  bool get inverted => draft.inverted;
  set inverted(bool value) => draft.inverted = value;
  TextEditingController get minimumController => draft.minimumController;
  TextEditingController get maximumController => draft.maximumController;
  String? get errorText => draft.errorText;

  @override
  void initState() {
    super.initState();
    draft = AxisSettingsDraft(
      automatic: widget.automatic,
      minimum: widget.minimum,
      maximum: widget.maximum,
      mouseEnabled: widget.mouseEnabled,
      inverted: widget.inverted,
      minimumAllowed: widget.minimumAllowed,
    );
  }

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final axis = widget.xAxis ? 'X' : 'Y';
    final unit = widget.xAxis ? '（秒）' : '';
    return AlertDialog(
      title: Text('$axis 轴详细设置'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(widget.xAxis ? '自动跟随最新' : '自动范围'),
              value: automatic,
              onChanged: (value) => setState(() => automatic = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用鼠标拖动与缩放'),
              value: mouseEnabled,
              onChanged: (value) => setState(() => mouseEnabled = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('反向坐标轴'),
              value: inverted,
              onChanged: (value) => setState(() => inverted = value),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('plot-${axis.toLowerCase()}-minimum'),
                    controller: minimumController,
                    enabled: !automatic,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(labelText: '最小值$unit'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: ValueKey('plot-${axis.toLowerCase()}-maximum'),
                    controller: maximumController,
                    enabled: !automatic,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(labelText: '最大值$unit'),
                  ),
                ),
              ],
            ),
            if (errorText != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errorText!,
                  style: const TextStyle(color: Color(0xFFE25858)),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _apply, child: const Text('应用')),
      ],
    );
  }

  void _apply() {
    final result = draft.validate(xAxis: widget.xAxis);
    if (result == null) return setState(() {});
    Navigator.of(context).pop(result);
  }
}
