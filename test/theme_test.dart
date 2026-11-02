import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  test('primary text stays readable in every enabled interaction state', () {
    final theme = buildTalTheme();
    final style = theme.filledButtonTheme.style!;
    for (final states in <Set<WidgetState>>[
      {},
      {WidgetState.hovered},
      {WidgetState.focused},
      {WidgetState.pressed},
      {WidgetState.hovered, WidgetState.pressed},
    ]) {
      final foreground = style.foregroundColor!.resolve(states)!;
      final background = style.backgroundColor!.resolve(states)!;
      expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
      expect(foreground, theme.colorScheme.onPrimary);
    }
    for (final surface in [
      theme.scaffoldBackgroundColor,
      theme.colorScheme.surface,
      theme.colorScheme.surfaceContainerHighest,
    ]) {
      expect(_contrast(TalColors.text, surface), greaterThanOrEqualTo(4.5));
      expect(_contrast(TalColors.muted, surface), greaterThanOrEqualTo(4.5));
    }
  });

  for (final mode in TalInputMode.values) {
    testWidgets('$mode renders primary, disabled, and dialog controls', (
      tester,
    ) async {
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: Scaffold(
            body: TalDialog(
              title: const Text('采集设置'),
              content: const Text('1 kHz'),
              actions: [
                const TalButton(
                  variant: TalButtonVariant.filled,
                  onPressed: null,
                  child: Text('不可用'),
                ),
                TalButton(
                  variant: TalButtonVariant.filled,
                  onPressed: () => presses++,
                  child: const Text('应用'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final primary = find.widgetWithText(FilledButton, '应用');
      final disabled = find.widgetWithText(FilledButton, '不可用');
      Material surface(Finder button) => tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first,
      );
      expect(surface(primary).color, TalColors.accent);
      expect(surface(disabled).color, TalColors.surfaceAlt);
      expect(
        DefaultTextStyle.of(tester.element(find.text('应用'))).style.color,
        TalColors.onAccent,
      );
      expect(
        DefaultTextStyle.of(tester.element(find.text('采集设置'))).style.color,
        TalColors.heading,
      );
      expect(
        tester.getSize(primary).height,
        mode == TalInputMode.touch ? 48 : 32,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(primary));
      await tester.pumpAndSettle();
      expect(surface(primary).color, TalColors.accentHover);
      await mouse.down(tester.getCenter(primary));
      await tester.pumpAndSettle();
      expect(surface(primary).color, TalColors.accentPressed);
      await mouse.up();
      await mouse.moveTo(tester.getCenter(disabled));
      await tester.pumpAndSettle();
      expect(surface(disabled).color, TalColors.surfaceAlt);
      expect(presses, 1);
      await mouse.removePointer();
    });
  }

  testWidgets('menu trigger keeps its enabled appearance and opens once', (
    tester,
  ) async {
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: TalPopupMenuButton<String>(
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('复位运行')),
            ],
            onSelected: (_) => selections++,
            child: const Text('复位'),
          ),
        ),
      ),
    );
    expect(
      DefaultTextStyle.of(tester.element(find.text('复位'))).style.color,
      TalColors.text,
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('复位运行'), findsOneWidget);
    await tester.tap(find.text('复位运行'));
    await tester.pumpAndSettle();
    expect(selections, 1);
  });
}

double _contrast(Color foreground, Color background) {
  final levels = [foreground.computeLuminance(), background.computeLuminance()]
    ..sort();
  return (levels.last + 0.05) / (levels.first + 0.05);
}
