import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/source_debug_panel.dart';
import 'package:take_a_look_v2/src/panels/source_documents.dart';
import 'package:take_a_look_v2/src/panels/source_highlighter.dart';
import 'package:take_a_look_v2/src/panels/source_peek.dart';
import 'package:take_a_look_v2/src/panels/source_references.dart';
import 'package:take_a_look_v2/src/panels/source_search.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  for (final peek in [false, true]) {
    testWidgets('assembly colors reach the ${peek ? 'peek' : 'source'} panel', (
      tester,
    ) async {
      late Directory directory;
      late String path;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('tal_assembly_');
        path = '${directory.path}/startup.S';
        await File(
          path,
        ).writeAsString('.syntax unified\nentry:\n    MOV R0, #16 @ value\n');
      });
      addTearDown(() => directory.delete(recursive: true));
      final controller = TakeALookController();
      controller.applyDebugState({
        'executionState': 'halted',
        'sourceFiles': [path],
        'stoppedLocation': {'path': path, 'line': 3, 'address': 0x08000100},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: peek
                ? SourcePeekPanel(
                    kind: SourcePeekKind.definitions,
                    token: 'entry',
                    locations: [SourceCodeLocation(path: path, line: 2)],
                    documents: SourceDocuments(),
                    highlighter: SourceHighlighter(),
                    sourceRoot: '',
                    onClose: () {},
                    onOpen: (_) {},
                    onResize: (_) {},
                  )
                : SourceDebugPanel(controller: controller),
          ),
        ),
      );
      final codeLine = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText().contains('MOV R0') == true,
      );
      for (
        var attempt = 0;
        attempt < 30 && codeLine.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(codeLine, findsOneWidget);
      final spans = _leafSpans(
        tester.widget<Text>(codeLine).textSpan!,
      ).toList();
      expect(
        spans.singleWhere((span) => span.text == 'MOV').style?.color,
        TalSyntaxColors.keyword,
      );
      expect(
        spans.singleWhere((span) => span.text == 'R0').style?.color,
        TalSyntaxColors.type,
      );
      expect(
        spans.singleWhere((span) => span.text == '@ value').style?.color,
        TalSyntaxColors.comment,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final extension in ['s', 'S', 'asm', 'ASM', 'inc', 'sx']) {
    test('selects assembly highlighting for .$extension', () async {
      final source = await SourceHighlighter().prepare(
        SourceSearchText('    MOV R0, #42 ; immediate'),
        path: 'C:\\firmware\\startup.$extension',
      );
      final line = source.lines.single;
      expect(_colorOf(line, 'MOV'), TalSyntaxColors.keyword);
      expect(_colorOf(line, 'R0'), TalSyntaxColors.type);
      expect(_colorOf(line, '42'), TalSyntaxColors.number);
      expect(_colorOf(line, '; immediate'), TalSyntaxColors.comment);
    });
  }

  test(
    'highlights a Keil startup file and retains navigable symbols',
    () async {
      const text =
          '    AREA RESET, DATA, READONLY\r\n'
          '__Vectors DCD __initial_sp\r\n'
          '    DCD Reset_Handler ; entry point\r\n'
          'Reset_Handler PROC\r\n'
          '    EXPORT Reset_Handler [WEAK]\r\n'
          '    LDR R0, =SystemInit\r\n'
          '    BLX R0\r\n'
          '    BNE.W Reset_Handler\r\n'
          '    VLDMIA R0!, {S16-S31}\r\n'
          '    ENDP\r\n';
      final source = await SourceHighlighter().prepare(
        SourceSearchText(text),
        path: 'startup_stm32h723xx.s',
      );
      expect(_colorOf(source.lines[0], 'AREA'), TalSyntaxColors.preprocessor);
      expect(_colorOf(source.lines[1], '__Vectors'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[1], 'DCD'), TalSyntaxColors.preprocessor);
      expect(
        _colorOf(source.lines[2], '; entry point'),
        TalSyntaxColors.comment,
      );
      expect(_colorOf(source.lines[3], 'PROC'), TalSyntaxColors.preprocessor);
      expect(_colorOf(source.lines[4], 'EXPORT'), TalSyntaxColors.preprocessor);
      expect(_colorOf(source.lines[7], 'BNE.W'), TalSyntaxColors.keyword);
      expect(_colorOf(source.lines[8], 'VLDMIA'), TalSyntaxColors.keyword);
      expect(_colorOf(source.lines[8], 'S31'), TalSyntaxColors.type);
      expect(_identifiers(source.lines[5]), ['SystemInit']);
      expect(_identifiers(source.lines[7]), ['Reset_Handler']);
      expect(_identifiers(source.lines[3]), ['Reset_Handler']);
      _expectPreserved(source, text);
    },
  );

  test(
    'highlights GNU directives, local labels and ARM instruction suffixes',
    () async {
      const text =
          '.syntax unified\n'
          '.thumb\n'
          '.section .text.Reset_Handler,"ax",%progbits\n'
          '.type Reset_Handler, %function\n'
          'Reset_Handler:\n'
          '    ldr r0, =0x20000000 @ stack\n'
          '    adds r1, r0, #0b1010; bx lr\n'
          '.Lloop: subs.w r1, r1, #1\n'
          '    bne .Lloop\n'
          '    vmov.f32 s0, s1\n'
          '    .ltorg\n'
          '    .cfi_endproc\n';
      final source = await SourceHighlighter().prepare(
        SourceSearchText(text),
        path: '/firmware/startup.S',
      );
      expect(
        _colorOf(source.lines[0], '.syntax'),
        TalSyntaxColors.preprocessor,
      );
      expect(_colorOf(source.lines[2], '"ax"'), TalSyntaxColors.string);
      expect(_colorOf(source.lines[4], 'Reset_Handler'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[5], '0x20000000'), TalSyntaxColors.number);
      expect(_colorOf(source.lines[5], '@ stack'), TalSyntaxColors.comment);
      expect(_colorOf(source.lines[6], '0b1010'), TalSyntaxColors.number);
      expect(_colorOf(source.lines[6], 'bx'), TalSyntaxColors.keyword);
      expect(_colorOf(source.lines[6], 'lr'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[7], '.Lloop'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[7], 'subs.w'), TalSyntaxColors.keyword);
      expect(_identifiers(source.lines[8]), ['.Lloop']);
      expect(_colorOf(source.lines[9], 'vmov.f32'), TalSyntaxColors.keyword);
      expect(
        _colorOf(source.lines[10], '.ltorg'),
        TalSyntaxColors.preprocessor,
      );
      expect(
        _colorOf(source.lines[11], '.cfi_endproc'),
        TalSyntaxColors.preprocessor,
      );
      _expectPreserved(source, text);
    },
  );

  test(
    'comments and strings do not consume immediates or expose identifiers',
    () async {
      const text =
          '#include "device.h"\n'
          '    MOV r0, #16 // value\n'
          '    DCB "text; @ /*", 0 ; trailing\n'
          '/* MOV r1, #2\n'
          '   still comment */ MOV r2, #3\n'
          '    MSR BASEPRI, r0\n'
          '    LDM r0, {r8\'}\n'
          '# GNU comment\n';
      final source = await SourceHighlighter().prepare(
        SourceSearchText(text),
        path: 'startup.asm',
      );
      expect(
        _colorOf(source.lines[0], '#include'),
        TalSyntaxColors.preprocessor,
      );
      expect(_colorOf(source.lines[1], '16'), TalSyntaxColors.number);
      expect(_colorOf(source.lines[1], '// value'), TalSyntaxColors.comment);
      expect(_colorOf(source.lines[2], '"text; @ /*"'), TalSyntaxColors.string);
      expect(_colorOf(source.lines[2], '; trailing'), TalSyntaxColors.comment);
      expect(_colorOf(source.lines[3], 'MOV'), TalSyntaxColors.comment);
      expect(_colorOf(source.lines[4], 'MOV'), TalSyntaxColors.keyword);
      expect(_colorOf(source.lines[5], 'BASEPRI'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[6], 'r8'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[6], "'"), TalColors.text);
      expect(
        _colorOf(source.lines[7], '# GNU comment'),
        TalSyntaxColors.comment,
      );
      expect(source.lines.expand((line) => line.identifiers), isEmpty);
      _expectPreserved(source, text);
    },
  );

  test(
    'operand symbols keep their names even when they match instructions',
    () async {
      final source = await SourceHighlighter().prepare(
        SourceSearchText('b: LDR r0, =add\n    BL b'),
        path: 'symbols.s',
      );
      expect(_identifiers(source.lines[0]), ['b', 'add']);
      expect(_identifiers(source.lines[1]), ['b']);
      expect(_colorOf(source.lines[0], 'LDR'), TalSyntaxColors.keyword);
    },
  );

  test(
    'cached preparations distinguish assembly from C and reuse each language',
    () async {
      final highlighter = SourceHighlighter();
      final text = SourceSearchText('    MOV r0, #1; // asm\n' * 13000);
      final assembly = highlighter.prepare(text, path: 'startup.S');
      final cpp = highlighter.prepare(text, path: 'main.cpp');
      expect(
        identical(assembly, highlighter.prepare(text, path: 'other.asm')),
        isTrue,
      );
      expect(identical(cpp, highlighter.prepare(text)), isTrue);
      expect(identical(assembly, cpp), isFalse);
      final prepared = await assembly;
      expect(prepared.lines, hasLength(13001));
      expect(_colorOf(prepared.lines.first, 'MOV'), TalSyntaxColors.keyword);
      expect(_colorOf((await cpp).lines.first, 'MOV'), TalColors.text);
    },
  );

  test(
    'C and C++ highlighting retains keywords, types and comment rules',
    () async {
      final source = await SourceHighlighter().prepare(
        SourceSearchText('const uint32_t r0 = 42; // MOV\nreturn r0;'),
        path: 'main.c',
      );
      expect(_colorOf(source.lines[0], 'const'), TalSyntaxColors.keyword);
      expect(_colorOf(source.lines[0], 'uint32_t'), TalSyntaxColors.type);
      expect(_colorOf(source.lines[0], 'r0'), TalColors.text);
      expect(_colorOf(source.lines[0], ';'), TalColors.text);
      expect(_colorOf(source.lines[0], '// MOV'), TalSyntaxColors.comment);
      expect(_identifiers(source.lines[1]), ['r0']);
    },
  );
}

Iterable<TextSpan> _leafSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    if (span.text != null) yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _leafSpans(child);
    }
  }
}

Color? _colorOf(HighlightedSourceLine line, String token) {
  final start = line.rawText.indexOf(token);
  expect(start, greaterThanOrEqualTo(0));
  var offset = 0;
  for (final span in line.spans) {
    offset += span.text?.length ?? 0;
    if (offset > start) return span.style?.color;
  }
  fail('No span for $token');
}

List<String> _identifiers(HighlightedSourceLine line) => [
  for (final range in line.identifiers)
    line.rawText.substring(range.start, range.end),
];

void _expectPreserved(PreparedSourceText source, String original) {
  final normalized = original.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  expect(source.lines.map((line) => line.rawText).join('\n'), normalized);
  for (final line in source.lines) {
    expect(line.spans.map((span) => span.text).join(), line.rawText);
    expect(line.textLength, line.rawText.length);
  }
  expect(
    source.maximumLineLength,
    source.lines
        .map((line) => line.rawText.length)
        .reduce((a, b) => a > b ? a : b),
  );
}
