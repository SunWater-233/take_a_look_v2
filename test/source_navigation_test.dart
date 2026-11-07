import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/source_debug_panel.dart';
import 'package:take_a_look_v2/src/panels/source_highlighter.dart';
import 'package:take_a_look_v2/src/panels/source_search.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  test(
    'definitions prefer implementations, preserve ambiguity and match case',
    () {
      const definitions = [
        SourceDefinition(
          name: 'step',
          path: 'motor.h',
          line: 2,
          kind: 'function',
          isDeclaration: true,
        ),
        SourceDefinition(
          name: 'step',
          path: 'motor.c',
          line: 8,
          kind: 'function',
        ),
        SourceDefinition(
          name: 'step',
          path: 'motor.c',
          line: 8,
          kind: 'function',
        ),
        SourceDefinition(
          name: 'Step',
          path: 'other.c',
          line: 8,
          kind: 'function',
        ),
        SourceDefinition(
          name: 'step',
          path: 'other.c',
          line: 9,
          kind: 'function',
          scope: 'Other',
        ),
        SourceDefinition(
          name: 'step',
          path: 'other.c',
          line: 10,
          kind: 'variable',
          isLocal: true,
        ),
      ];
      final results = findSourceDefinitions(
        definitions,
        'step',
        isCurrentFile: (path) => path == 'motor.c',
      );
      expect(results.map((item) => item.path), ['motor.c', 'other.c']);
      expect(results.last.qualifiedName, 'Other::step');
      expect(
        findSourceDefinitions(
          [definitions.first],
          'step',
          isCurrentFile: (_) => false,
        ).single.isDeclaration,
        isTrue,
      );
    },
  );

  test('only code identifiers can initiate navigation', () async {
    final prepared = await SourceHighlighter().prepare(
      SourceSearchText(
        'gain = step(gain); // gain\n'
        '/* step\n'
        'gain */ const char *message = "gain";\n'
        '#include "gain.h"\n',
      ),
    );
    List<String> identifiers(int line) => [
      for (final range in prepared.lines[line].identifiers)
        prepared.lines[line].rawText.substring(range.start, range.end),
    ];
    expect(identifiers(0), ['gain', 'step', 'gain']);
    expect(identifiers(1), isEmpty);
    expect(identifiers(2), ['message']);
    expect(identifiers(3), isEmpty);
  });

  test('definition snapshots reach detached windows and clear on reload', () {
    final controller = TakeALookController();
    final detached = TakeALookController();
    addTearDown(controller.dispose);
    addTearDown(detached.dispose);
    controller.applyDebugState({
      'sourceDefinitions': [
        const SourceDefinition(
          name: 'gain',
          path: 'motor.c',
          line: 2,
          kind: 'variable',
        ).toJson(),
      ],
    });
    controller.applyDebugState({'executionState': 'running'});
    expect(controller.debugState.hasSourceDefinitionIndex, isTrue);
    expect(controller.debugState.sourceDefinitions.single.name, 'gain');
    detached.applySnapshot(controller.snapshot());
    expect(detached.debugState.sourceDefinitions.single.path, 'motor.c');
    expect(detached.debugState.hasSourceDefinitionIndex, isTrue);
    controller.applyDebugState({'sourceDefinitions': <Object?>[]});
    expect(controller.debugState.sourceDefinitions, isEmpty);
    expect(controller.debugState.hasSourceDefinitionIndex, isTrue);
    controller.applySnapshot({
      'symbols': <Object?>[],
      'debug': {
        'sourceFiles': ['motor.c'],
      },
    });
    expect(controller.debugState.hasSourceDefinitionIndex, isFalse);
    detached.applySnapshot(controller.snapshot());
    expect(detached.debugState.hasSourceDefinitionIndex, isFalse);
  });

  testWidgets(
    'legacy backend reports a missing index instead of a missing definition',
    (tester) async {
      final fixture = await _fixture(tester);
      final controller = fixture.controller;
      controller.applySnapshot({
        'sourceProject': {'firmwarePath': 'legacy.axf'},
        'firmware': {'status': 'ready'},
        'symbols': <Object?>[],
        'debug': {
          'sourceFiles': [fixture.main, fixture.motor],
        },
      });
      await _mount(tester, controller);
      await _waitForSource(tester, fixture.main);
      await _clickToken(tester, 2, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();
      expect(find.text('当前后端尚未提供源码定义索引，请重启完整新版应用后刷新符号文件。'), findsOneWidget);
      expect(controller.sourceWorkspace.selectedPath, fixture.main);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('Ctrl click, F12 and history reveal cross-file definitions', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    final controller = fixture.controller;
    await _mount(tester, controller);
    await _waitForSource(tester, fixture.main);

    // The definition is a build-machine path, mapped to the local root.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _clickToken(tester, 2, 3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _waitForSource(tester, fixture.motor);
    expect(
      find.byKey(ValueKey('source-tab-active-${fixture.motor}')),
      findsOneWidget,
    );
    final line = find.byKey(const ValueKey('source-line-45'));
    expect(line.hitTestable(), findsOneWidget);
    expect(
      _lineBackground(tester, line),
      TalColors.amber.withValues(alpha: 0.16),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _waitForSource(tester, fixture.main);
    expect(
      _lineBackground(tester, find.byKey(const ValueKey('source-line-2'))),
      TalColors.amber.withValues(alpha: 0.16),
    );

    // Returning restores the selected token, so F12 works without another click.
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await _waitForSource(tester, fixture.motor);
    await tester.tap(find.byKey(const ValueKey('source-navigation-back')));
    await _waitForSource(tester, fixture.main);
    await tester.tap(find.byKey(const ValueKey('source-navigation-forward')));
    await _waitForSource(tester, fixture.motor);
    expect(
      _lineBackground(tester, find.byKey(const ValueKey('source-line-45'))),
      TalColors.amber.withValues(alpha: 0.16),
    );

    await tester.tap(find.byKey(const ValueKey('source-navigation-back')));
    await _waitForSource(tester, fixture.main);
    await _clickToken(tester, 3, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await _waitForSource(tester, fixture.motor);
    expect(
      find.byKey(const ValueKey('source-line-40')).hitTestable(),
      findsOneWidget,
    );
    expect(controller.debugState.currentSource, isNull);
    expect(controller.debugState.requestedBreakpoints, isEmpty);
    expect(controller.watches, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('context menu chooses ambiguous definitions and reports misses', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    final controller = fixture.controller;
    await _mount(tester, controller);
    await _waitForSource(tester, fixture.main);
    controller.applyDebugState({
      'sourceDefinitions': [
        for (final line in [40, 45])
          SourceDefinition(
            name: 'gain',
            path: fixture.motor,
            line: line,
            kind: 'variable',
            scope: 'scope$line',
          ).toJson(),
      ],
    });
    await tester.pump();

    // A prior selection on this line must not override the right-clicked token.
    await _clickToken(tester, 3, 11);
    await _clickToken(tester, 3, 2, secondary: true);
    await tester.pumpAndSettle();
    expect(find.text('跳转到定义    F12'), findsOneWidget);
    for (final element in find.byType(PopupMenuItem<String>).evaluate()) {
      expect(tester.getSize(find.byWidget(element.widget)).height, 32);
    }
    await tester.tap(find.byKey(const ValueKey('source-menu-definition')));
    await _waitForPeek(tester);
    expect(find.text('gain 的定义 (2)'), findsOneWidget);
    expect(controller.sourceWorkspace.selectedPath, fixture.main);
    await tester.tap(find.byKey(const ValueKey('source-peek-close')));
    await tester.pumpAndSettle();
    expect(controller.sourceWorkspace.selectedPath, fixture.main);

    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await _waitForPeek(tester);
    await tester.tap(find.byKey(const ValueKey('source-peek-location-1')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('source-peek-open')));
    await _waitForSource(tester, fixture.motor);
    expect(
      find.byKey(const ValueKey('source-line-45')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('source-navigation-back')));
    await _waitForSource(tester, fixture.main);
    await _clickToken(tester, 3, 11);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    expect(find.textContaining('未找到 missing 的定义'), findsOneWidget);
    expect(controller.sourceWorkspace.selectedPath, fixture.main);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'Ctrl hover decorates only a resolvable identifier and resets on release',
    (tester) async {
      final fixture = await _fixture(tester);
      await _mount(tester, fixture.controller);
      await _waitForSource(tester, fixture.main);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final point = _tokenPosition(tester, 2, 3);
      await mouse.addPointer(location: point);
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(
        _tokenSpans(
          tester,
          2,
        ).where((span) => span.style?.decoration == TextDecoration.underline),
        isEmpty,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final link = _tokenSpans(
        tester,
        2,
      ).singleWhere((span) => span.text == 'motor_step');
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.style?.color, TalColors.info);
      expect(
        link.style?.backgroundColor,
        TalColors.info.withValues(alpha: .14),
      );
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('source-mouse-line-2')),
            )
            .cursor,
        SystemMouseCursors.click,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        _tokenSpans(
          tester,
          2,
        ).where((span) => span.style?.decoration == TextDecoration.underline),
        isEmpty,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await mouse.moveTo(_tokenPosition(tester, 3, 11));
      await tester.pump();
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const ValueKey('source-mouse-line-3')),
            )
            .cursor,
        SystemMouseCursors.text,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.controller.dispose();
    },
  );

  testWidgets('Alt F12 previews a definition without opening a source tab', (
    tester,
  ) async {
    final fixture = await _fixture(tester);
    await _mount(tester, fixture.controller);
    await _waitForSource(tester, fixture.main);
    await _clickToken(tester, 2, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _waitForPeek(tester);
    expect(find.text('motor_step 的定义 (1)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-peek-code-line-45')).hitTestable(),
      findsOneWidget,
    );
    expect(fixture.controller.sourceWorkspace.openPaths, [fixture.main]);
    expect(fixture.controller.sourceWorkspace.selectedPath, fixture.main);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-peek-panel')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _waitForPeek(tester);
    final result = find.byKey(const ValueKey('source-peek-location-0'));
    await tester.tap(result);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(result);
    await _waitForSource(tester, fixture.motor);
    expect(find.byKey(const ValueKey('source-peek-panel')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.controller.dispose();
  });

  testWidgets('a hidden inline preview does not handle Enter', (tester) async {
    final fixture = await _fixture(tester);
    await _mount(tester, fixture.controller);
    await _waitForSource(tester, fixture.main);
    await _clickToken(tester, 2, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _waitForPeek(tester);
    await tester.tap(find.byKey(const ValueKey('source-peek-location-0')));
    await tester.pump(const Duration(milliseconds: 350));
    await _mount(tester, fixture.controller, visible: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.controller.sourceWorkspace.openPaths, [fixture.main]);
    expect(fixture.controller.sourceWorkspace.selectedPath, fixture.main);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.controller.dispose();
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets('references preview and keyboard navigation fit width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final screenshots = Platform.environment['TAL_SOURCE_PEEK_SCREENSHOTS'];
      if (screenshots != null) {
        await tester.runAsync(() async {
          await (FontLoader(talFontFamily)..addFont(
                rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'),
              ))
              .load();
          await (FontLoader('MiSans')
                ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf')))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      final fixture = await _fixture(tester);
      await _mount(tester, fixture.controller);
      await _waitForSource(tester, fixture.main);
      await _clickToken(tester, 3, 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _waitForPeek(tester, references: true);
      expect(find.text('gain 的引用 (3)'), findsOneWidget);
      expect(fixture.controller.sourceWorkspace.openPaths, [fixture.main]);
      await tester.tap(find.byKey(const ValueKey('source-peek-location-1')));
      await tester.pump(const Duration(milliseconds: 350));
      await _waitForPeek(tester);
      expect(
        find.byKey(const ValueKey('source-peek-code-line-40')).hitTestable(),
        findsOneWidget,
      );
      expect(fixture.controller.sourceWorkspace.selectedPath, fixture.main);
      expect(tester.takeException(), isNull);
      if (screenshots != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('source-panel-capture')),
        );
        await tester.runAsync(() async {
          final snapshot = await boundary.toImage(pixelRatio: 1);
          final bytes = await snapshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          snapshot.dispose();
          final file = File('$screenshots/source-peek-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      if (width > 560) {
        final originalHeight = tester
            .getSize(find.byKey(const ValueKey('source-peek-panel')))
            .height;
        await tester.drag(
          find.byKey(const ValueKey('source-peek-resize')),
          const Offset(0, 40),
        );
        await tester.pump();
        expect(
          tester
              .getSize(find.byKey(const ValueKey('source-peek-panel')))
              .height,
          greaterThan(originalHeight),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _waitForPeek(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _waitForSource(tester, fixture.motor);
      expect(find.byKey(const ValueKey('source-peek-panel')), findsNothing);
      expect(
        find.byKey(const ValueKey('source-line-45')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.controller.dispose();
    });
  }
}

typedef _Fixture = ({
  TakeALookController controller,
  String main,
  String motor,
});

Future<_Fixture> _fixture(WidgetTester tester) async {
  late Directory root;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('tal_source_navigation_');
    await File('${root.path}/main.c').writeAsString(
      'int main(void) {\n  motor_step();\n  gain = missing;\n}\n',
    );
    await File('${root.path}/motor.c').writeAsString(
      [
        for (var line = 1; line <= 60; line++)
          line == 40
              ? 'int gain = 2;'
              : line == 45
              ? 'int motor_step(void) { return gain; }'
              : '// line $line',
      ].join('\n'),
    );
  });
  addTearDown(() => root.delete(recursive: true));
  const main = 'Z:/build/firmware/main.c';
  const motor = 'Z:/build/firmware/motor.c';
  final controller = TakeALookController()..setSourceRoot(root.path);
  controller.applyDebugState({
    'executionState': 'running',
    'sourceFiles': [main, motor],
    'sourceDefinitions': [
      const SourceDefinition(
        name: 'motor_step',
        path: motor,
        line: 45,
        kind: 'function',
      ).toJson(),
      const SourceDefinition(
        name: 'gain',
        path: motor,
        line: 40,
        kind: 'variable',
      ).toJson(),
    ],
  });
  controller.openSourceFile(main);
  return (controller: controller, main: main, motor: motor);
}

Future<void> _mount(
  WidgetTester tester,
  TakeALookController controller, {
  bool visible = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(),
      home: RepaintBoundary(
        key: const ValueKey('source-panel-capture'),
        child: Scaffold(
          body: SourceDebugPanel(
            controller: controller,
            externalOutput: true,
            visible: visible,
          ),
        ),
      ),
    ),
  );
}

Future<void> _waitForSource(WidgetTester tester, String path) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump();
    if (find.byKey(ValueKey('source-view-$path')).evaluate().isNotEmpty) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byKey(ValueKey('source-view-$path')), findsOneWidget);
}

Future<void> _clickToken(
  WidgetTester tester,
  int line,
  int character, {
  bool secondary = false,
}) async {
  await tester.tapAt(
    _tokenPosition(tester, line, character),
    buttons: secondary ? kSecondaryMouseButton : kPrimaryMouseButton,
  );
  await tester.pump(const Duration(milliseconds: 350));
}

Offset _tokenPosition(WidgetTester tester, int line, int character) {
  final finder = find.byKey(ValueKey('source-line-$line'));
  final text = tester.widget<Text>(
    find.descendant(of: finder, matching: find.byType(Text)),
  );
  final painter = TextPainter(
    text: TextSpan(children: [text.textSpan!], style: text.style),
    textDirection: TextDirection.ltr,
  )..layout();
  final offset = painter.getOffsetForCaret(
    TextPosition(offset: character),
    Rect.zero,
  );
  painter.dispose();
  return tester.getTopLeft(finder) + Offset(offset.dx + 1, 11);
}

List<TextSpan> _tokenSpans(WidgetTester tester, int line) {
  final widget = tester.widget<Text>(
    find.descendant(
      of: find.byKey(ValueKey('source-line-$line')),
      matching: find.byType(Text),
    ),
  );
  final spans = <TextSpan>[];
  void collect(InlineSpan span) {
    if (span is TextSpan) {
      spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        collect(child);
      }
    }
  }

  collect(widget.textSpan!);
  return spans;
}

Future<void> _waitForPeek(
  WidgetTester tester, {
  bool references = false,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    final loading =
        find.text('正在查找引用…').evaluate().isNotEmpty ||
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
        find
            .descendant(
              of: find.byKey(const ValueKey('source-peek-panel')),
              matching: find.byType(CircularProgressIndicator),
            )
            .evaluate()
            .isNotEmpty;
    if (find.byKey(const ValueKey('source-peek-panel')).evaluate().isNotEmpty &&
        !loading) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump(const Duration(milliseconds: 150));
  expect(find.byKey(const ValueKey('source-peek-panel')), findsOneWidget);
}

Color _lineBackground(WidgetTester tester, Finder line) => tester
    .widget<ColoredBox>(
      find.ancestor(of: line, matching: find.byType(ColoredBox)).first,
    )
    .color;
