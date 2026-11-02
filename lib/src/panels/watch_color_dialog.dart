import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../theme/theme.dart';

class WatchColorDialog extends StatefulWidget {
  const WatchColorDialog({required this.initialColor, super.key});

  final Color initialColor;

  @override
  State<WatchColorDialog> createState() => WatchColorDialogState();
}

class WatchColorDialogState extends State<WatchColorDialog> {
  static const _presets = TalChartColors.presets;

  late HSVColor _hsv;
  late final TextEditingController _hexController;

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(
      text: watchColorHex(widget.initialColor),
    );
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _setColor(Color color) {
    setState(() => _hsv = HSVColor.fromColor(color));
    _hexController.text = watchColorHex(color);
  }

  void _setHsv(HSVColor color) {
    setState(() => _hsv = color);
    _hexController.text = watchColorHex(color.toColor());
  }

  void _applyHex(String value) {
    if (value.length != 6) return;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed)));
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return SizedBox(
      height: TalUiTheme.of(context).targetExtent(42),
      child: Row(
        children: [
          SizedBox(width: 48, child: Text(label, style: talMuted)),
          Expanded(
            child: Slider(
              value: value.clamp(0, max),
              max: max,
              activeColor: _color,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              max == 360
                  ? value.round().toString()
                  : '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: talMono,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TalDialog(
      title: const Row(
        children: [
          Icon(Icons.palette_outlined, size: 19),
          SizedBox(width: 8),
          Text('选择绘制颜色'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey('watch-color-preview'),
              height: 34,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: TalColors.border),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in _presets)
                  Material(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                    child: InkWell(
                      key: ValueKey('watch-color-preset-${color.toARGB32()}'),
                      onTap: () => _setColor(color),
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        width: TalUiTheme.of(context).targetExtent(26),
                        height: TalUiTheme.of(context).compactIconButtonSize,
                        child: color == _color
                            ? Icon(
                                Icons.check,
                                size: 15,
                                color: color.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _slider(
              label: '色相',
              value: _hsv.hue,
              max: 360,
              onChanged: (value) => _setHsv(_hsv.withHue(value)),
            ),
            _slider(
              label: '饱和度',
              value: _hsv.saturation,
              max: 1,
              onChanged: (value) => _setHsv(_hsv.withSaturation(value)),
            ),
            _slider(
              label: '亮度',
              value: _hsv.value,
              max: 1,
              onChanged: (value) => _setHsv(_hsv.withValue(value)),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('watch-color-hex'),
              controller: _hexController,
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              ],
              textCapitalization: TextCapitalization.characters,
              style: talMono,
              decoration: const InputDecoration(
                labelText: 'HEX',
                prefixText: '#',
                counterText: '',
              ),
              onChanged: _applyHex,
            ),
          ],
        ),
      ),
      actions: [
        TalButton(
          variant: TalButtonVariant.text,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TalButton(
          variant: TalButtonVariant.filled,
          key: const ValueKey('watch-color-confirm'),
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

String watchColorHex(Color color) => (color.toARGB32() & 0xFFFFFF)
    .toRadixString(16)
    .padLeft(6, '0')
    .toUpperCase();
