import 'package:flutter/material.dart';

import '../controller.dart';
import '../theme.dart';
import 'axis_settings.dart';
import 'viewport.dart';

final MenuStyle desktopAxisSubmenuStyle = talContextSubmenuStyle.copyWith(
  minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
  padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
);

class DesktopAxisMenu extends StatefulWidget {
  const DesktopAxisMenu({
    required this.controller,
    required this.xAxis,
    required this.onChanged,
    super.key,
  });

  final TakeALookController controller;
  final bool xAxis;
  final VoidCallback onChanged;

  @override
  State<DesktopAxisMenu> createState() => DesktopAxisMenuState();
}

class DesktopAxisMenuState extends State<DesktopAxisMenu> {
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
  set errorText(String? value) => draft.errorText = value;

  TakeALookController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final viewport = telemetryViewport(controller, const Size(720, 480));
    draft = AxisSettingsDraft(
      automatic: widget.xAxis ? controller.followLatest : controller.plotAutoY,
      minimum: widget.xAxis ? viewport.xMin : viewport.yMin,
      maximum: widget.xAxis ? viewport.xMax : viewport.yMax,
      mouseEnabled: widget.xAxis
          ? controller.plotMouseXEnabled
          : controller.plotMouseYEnabled,
      inverted: widget.xAxis ? controller.plotInvertX : controller.plotInvertY,
      format: _compactNumber,
    );
  }

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey(
        widget.xAxis ? 'desktop-x-axis-panel' : 'desktop-y-axis-panel',
      ),
      width: 249,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: TalColors.text,
            fontFamily: talFontFamily,
            fontSize: 12.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DesktopChoiceRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-manual' : 'desktop-y-manual',
                ),
                label: 'Manual',
                selected: !automatic,
                onTap: () => _setAutomatic(false),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _rangeField(
                      controller: minimumController,
                      key: ValueKey(
                        widget.xAxis
                            ? 'desktop-x-minimum'
                            : 'desktop-y-minimum',
                      ),
                    ),
                    const SizedBox(width: 3),
                    _rangeField(
                      controller: maximumController,
                      key: ValueKey(
                        widget.xAxis
                            ? 'desktop-x-maximum'
                            : 'desktop-y-maximum',
                      ),
                    ),
                  ],
                ),
              ),
              _DesktopChoiceRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-auto' : 'desktop-y-auto',
                ),
                label: 'Auto',
                selected: automatic,
                onTap: () => _setAutomatic(true),
                trailing: Container(
                  width: 72,
                  height: 27,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: TalColors.input,
                    border: Border.all(color: TalColors.border),
                  ),
                  child: const Text('100%'),
                ),
              ),
              _DesktopCheckRow(
                label: 'Visible Data Only',
                value: !widget.xAxis,
                enabled: false,
                onChanged: (_) {},
              ),
              _DesktopCheckRow(
                label: 'Auto Pan Only',
                value: widget.xAxis && automatic,
                enabled: false,
                onChanged: (_) {},
              ),
              _DesktopCheckRow(
                key: ValueKey(
                  widget.xAxis ? 'desktop-x-invert' : 'desktop-y-invert',
                ),
                label: 'Invert Axis',
                value: inverted,
                onChanged: _setInverted,
              ),
              _DesktopCheckRow(
                key: ValueKey(
                  widget.xAxis
                      ? 'desktop-x-mouse-enabled'
                      : 'desktop-y-mouse-enabled',
                ),
                label: 'Mouse Enabled',
                value: mouseEnabled,
                onChanged: _setMouseEnabled,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Expanded(child: Text('Link Axis:')),
                  Container(
                    width: 108,
                    height: 27,
                    decoration: BoxDecoration(
                      color: TalColors.input,
                      border: Border.all(color: TalColors.border),
                    ),
                    child: const Align(
                      alignment: Alignment.centerRight,
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: 19,
                        color: TalColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
              if (errorText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    errorText!,
                    style: const TextStyle(
                      color: Color(0xFFE25858),
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rangeField({
    required TextEditingController controller,
    required Key key,
  }) {
    return SizedBox(
      width: 60,
      height: 27,
      child: TextField(
        key: key,
        controller: controller,
        enabled: !automatic,
        style: const TextStyle(fontSize: 11.5, color: TalColors.text),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        textInputAction: TextInputAction.done,
        onEditingComplete: _applyManualRange,
        onSubmitted: (_) => _applyManualRange(),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: TalColors.border),
          ),
        ),
      ),
    );
  }

  void _setAutomatic(bool value) {
    setState(() {
      automatic = value;
      errorText = null;
    });
    if (widget.xAxis) {
      controller.configurePlotView({'followLatest': value});
    } else {
      controller.configurePlotView({'plotAutoY': value});
    }
    widget.onChanged();
  }

  void _setMouseEnabled(bool value) {
    setState(() => mouseEnabled = value);
    controller.configurePlotView({
      widget.xAxis ? 'plotMouseXEnabled' : 'plotMouseYEnabled': value,
    });
    widget.onChanged();
  }

  void _setInverted(bool value) {
    setState(() => inverted = value);
    controller.configurePlotView({
      widget.xAxis ? 'plotInvertX' : 'plotInvertY': value,
    });
    widget.onChanged();
  }

  void _applyManualRange() {
    final result = draft.validate(xAxis: widget.xAxis);
    if (result == null) return setState(() {});
    setState(() {
      automatic = false;
      errorText = null;
    });
    controller.configurePlotView({
      if (widget.xAxis) ...{
        'followLatest': false,
        'xMin': result.minimum,
        'xMax': result.maximum,
      } else ...{
        'plotAutoY': false,
        'yMin': result.minimum,
        'yMax': result.maximum,
      },
    });
    widget.onChanged();
  }
}

class _DesktopChoiceRow extends StatelessWidget {
  const _DesktopChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.trailing,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 98,
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: selected ? TalColors.accent : TalColors.muted,
                  ),
                  const SizedBox(width: 4),
                  Text(label),
                ],
              ),
            ),
            const Spacer(),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _DesktopCheckRow extends StatelessWidget {
  const _DesktopCheckRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: enabled ? (next) => onChanged(next ?? false) : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: const VisualDensity(
                  horizontal: -4,
                  vertical: -4,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: enabled ? TalColors.text : TalColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _compactNumber(double value) => value.toStringAsPrecision(6);
