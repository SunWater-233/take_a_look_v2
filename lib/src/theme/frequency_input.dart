import '../models/frequency.dart';
import 'dropdown.dart';

const captureRatePresets = <double>[50, 100, 200, 500, 1000, 2000, 5000, 7000];
const monitorRatePresets = <double>[0.5, 1, 2, 5, 10];

final captureRateEditor = frequencyEditor();
final monitorRateEditor = frequencyEditor(range: (min: 0.5, max: 10));
final watchMonitorRateEditor = frequencyEditor(
  range: (min: 0.5, max: 10),
  allowDefault: true,
);

TalDropdownEditor<double> frequencyEditor({
  ({double min, double max})? range,
  bool allowDefault = false,
}) {
  final hint = range == null
      ? '请输入大于 0 的频率，如 750 Hz 或 1.25 kHz。'
      : '请输入 ${formatReadRate(range.min)}～${formatReadRate(range.max)} 的频率。';
  return TalDropdownEditor<double>(
    parse: (text) {
      final rate = parseFrequencyHz(text);
      if (rate == null) return null;
      if (allowDefault && rate == 0) return 0;
      if (rate <= 0 || !(1e6 / rate).isFinite) return null;
      if (range != null && (rate < range.min || rate > range.max)) return null;
      return rate;
    },
    text: formatReadRate,
    errorMessage: allowDefault ? '$hint 输入 0 使用默认频率。' : hint,
  );
}
