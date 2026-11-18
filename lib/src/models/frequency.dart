final _frequencyPattern = RegExp(
  r'^([+]?(?:\d+(?:\.\d*)?|\.\d+))(?:e([+-]?\d+))?\s*(hz|khz|mhz)?$',
  caseSensitive: false,
);

/// Parses a frequency in Hz, kHz, or MHz. A bare number is in Hz.
double? parseFrequencyHz(String text) {
  final match = _frequencyPattern.firstMatch(text.trim());
  if (match == null) return null;
  final exponent = int.tryParse(match[2] ?? '0');
  if (exponent == null) return null;
  final unitExponent = switch (match[3]?.toLowerCase()) {
    'mhz' => 6,
    'khz' => 3,
    _ => 0,
  };
  // Shift the decimal exponent before conversion so e.g. 1.001 kHz is 1001 Hz.
  final value = double.tryParse('${match[1]}e${exponent + unitExponent}');
  if (value == null || !value.isFinite) return null;
  if (value == 0 && double.tryParse(match[1]!) != 0) return null;
  return value;
}

String formatReadRate(double value, {bool useMegahertz = false}) {
  if (useMegahertz && value >= 1000000) {
    final text = '${_formatNumber(value / 1000000)} MHz';
    if (parseFrequencyHz(text) == value) return text;
  }
  if (value >= 1000) {
    final text = '${_formatNumber(value / 1000)} kHz';
    if (parseFrequencyHz(text) == value) return text;
  }
  return '${_formatNumber(value)} Hz';
}

String _formatNumber(double value) {
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
