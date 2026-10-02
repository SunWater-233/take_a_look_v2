import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  test('theme prefers JetBrains Mono and falls back to MiSans', () {
    final theme = buildTalTheme();

    expect(theme.textTheme.bodyMedium?.fontFamily, talFontFamily);
    expect(
      theme.textTheme.bodyMedium?.fontFamilyFallback,
      talFontFamilyFallback,
    );
    expect(talMono.fontFamily, talFontFamily);
    expect(talMono.fontFamilyFallback, talFontFamilyFallback);
    expect(talBrandFontFamily, 'Ibrand');
    expect(talBrandFontFamilyFallback, <String>[
      talFontFamily,
      ...talFontFamilyFallback,
    ]);
  });
}
