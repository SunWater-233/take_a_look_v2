import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/theme.dart';
import 'source_search.dart';

class PreparedSourceText {
  PreparedSourceText(this.lines)
    : maximumLineLength = lines.fold(
        0,
        (length, line) => math.max(length, line.textLength),
      );
  final List<HighlightedSourceLine> lines;
  final int maximumLineLength;
}

/// Shares work for an already cached document, including in-flight requests.
class SourceHighlighter {
  final _prepared = Expando<Map<bool, Future<PreparedSourceText>>>();

  Future<PreparedSourceText> prepare(
    SourceSearchText document, {
    String path = '',
  }) {
    final assembly = _assemblyPath.hasMatch(path);
    final prepared = _prepared[document] ??= {};
    return prepared.putIfAbsent(assembly, () {
      final input = (text: document.text, assembly: assembly);
      return document.text.length < 256 * 1024
          ? Future.value(_prepareSource(input))
          : compute(_prepareSource, input);
    });
  }

  static final _assemblyPath = RegExp(
    r'\.(?:s|asm|inc|sx)$',
    caseSensitive: false,
  );
}

PreparedSourceText _prepareSource(({String text, bool assembly}) input) =>
    PreparedSourceText(
      _SourceSyntaxHighlighter(assembly: input.assembly).highlight(input.text),
    );

enum _SourceTokenKind {
  plain,
  keyword,
  type,
  number,
  string,
  comment,
  preprocessor,
  label,
}

class HighlightedSourceLine {
  const HighlightedSourceLine(
    this.spans,
    this.textLength,
    this.rawText, {
    this.identifiers = const [],
  });

  final List<TextSpan> spans;
  final int textLength;
  final String rawText;
  final List<({int start, int end})> identifiers;
}

typedef SourceSpanDecoration = ({int start, int end, TextStyle style});

/// Splits syntax spans only at decoration boundaries, retaining syntax colors.
List<TextSpan> decorateSourceSpans(
  List<TextSpan> spans,
  List<SourceSpanDecoration> decorations,
) {
  if (decorations.isEmpty) return spans;
  final result = <TextSpan>[];
  var offset = 0;
  for (final span in spans) {
    final text = span.text ?? '';
    final end = offset + text.length;
    final boundaries = <int>{offset, end};
    for (final decoration in decorations) {
      if (decoration.start > offset && decoration.start < end) {
        boundaries.add(decoration.start);
      }
      if (decoration.end > offset && decoration.end < end) {
        boundaries.add(decoration.end);
      }
    }
    final cuts = boundaries.toList()..sort();
    for (var index = 0; index + 1 < cuts.length; index++) {
      final start = cuts[index];
      final stop = cuts[index + 1];
      var style = span.style;
      for (final decoration in decorations) {
        if (start >= decoration.start && stop <= decoration.end) {
          style = (style ?? const TextStyle()).merge(decoration.style);
        }
      }
      result.add(
        TextSpan(
          text: text.substring(start - offset, stop - offset),
          style: style,
        ),
      );
    }
    offset = end;
  }
  return result;
}

class _SourceSyntaxHighlighter {
  _SourceSyntaxHighlighter({required this.assembly});

  final bool assembly;
  bool _gnuAssembly = false;

  static final _gnuDirective = RegExp(
    r'^\s*\.(?:syntax|section|text|data|bss|thumb|cpu|arch|global|globl|type|'
    r'word|byte|equ|include|macro|cfi_\w+)\b',
    multiLine: true,
    caseSensitive: false,
  );
  static final _preprocessorDirective = RegExp(
    r'^#\s*(?:include|define|undef|if|ifdef|ifndef|elif|else|endif|error|'
    r'warning|pragma|line|[0-9]+)\b',
  );
  static final _assemblyDirectives = {
    ...('align area arm assert code16 code32 common data dcb dcd dcdu dcf dci '
            'dcfd dcfdu dcfs dcfsu dcq dcqu dcw dcwu end endfunc endp entry equ '
            'export exportas extern field fill function gbla gbll gbls get '
            'global if else elif endif import incbin include info keep lcla '
            'lcll lcls ltorg macro mend map mexit nofp opt preserve8 proc '
            'reloc require require8 rlist rn rout seta setl sets space thumb '
            'thumbx ttl subt while wend')
        .split(' '),
  };
  static final _gnuDirectives = {
    ...('align ascii asciz balign bss byte code cpu data double eabi_attribute '
            'else elseif end endfunc endif endm endr equ equiv error extern '
            'file float fpu func global globl hword if ifdef ifndef include '
            'incbin inst int irp irpc lcomm loc long ltorg macro object_arch '
            'octa org p2align pool popsection previous pushsection quad req '
            'rept section set short size skip space string subsection syntax '
            'text thumb thumb_func thumb_set type unreq weak word arch '
            'arch_extension arm even fnstart fnend cantunwind save pad '
            'personality personalityindex handlerdata vsave')
        .split(' '),
  };
  static final _assemblyRegisters = RegExp(
    r'^(?:r(?:1[0-5]|[0-9])|[sdq](?:[12]?[0-9]|3[01])|'
    r'a[1-4]|v[1-8]|sp|lr|pc|ip|fp|sl|sb|apsr(?:_\w+)?|[ix]psr|'
    r'epsr|cpsr|spsr|msp|psp|primask|basepri(?:_max)?|faultmask|control|'
    r'fpscr|fpexc|fpsid)$',
  );
  static final _assemblyInstruction = RegExp(
    r'^(?:adc|add|addw|adr|adrl|and|asr|b|bfc|bfi|bic|bkpt|bl|blx|bx|'
    r'cbnz|cbz|clrex|clz|cmn|cmp|cps|cpsid|cpsie|csdb|dbg|dmb|dsb|eor|'
    r'isb|it[te]{0,3}|ldm(?:ia|ib|da|db|fd|fa|ed|ea)?|'
    r'ldr(?:b|h|sb|sh|d|t|bt|ht|sbt|sht)?|ldrex(?:b|h|d)?|'
    r'lsl|lsr|mla|mls|mov|movs|movt|movw|mrs|msr|mul|mvn|neg|nop|orn|orr|'
    r'pkhbt|pkhtb|pop|push|qadd|qdadd|qdsub|qsub|rbit|rev|rev16|revsh|'
    r'ror|rrx|rsb|rsc|sbc|sbfx|sdiv|sel|sev|sevl|smc|smlal|smull|ssat|'
    r'stm(?:ia|ib|da|db|fd|fa|ed|ea)?|str(?:b|h|d|t|bt|ht)?|strex(?:b|h|d)?|'
    r'sub|subw|svc|sxtb|sxth|tbb|tbh|teq|tst|ubfx|udf|udiv|umlal|umull|'
    r'usat|uxtb|uxth|wfe|wfi|yield|'
    r'v(?:abs|add|cmp|cmpe|cvt|cvtr|div|fma|fms|fnma|fnms|ldm(?:ia|db)?|'
    r'ldr|mla|mls|mov|mrs|msr|mul|neg|nmla|nmls|nmul|pop|push|sqrt|'
    r'stm(?:ia|db)?|str|sub))'
    r's?(?:eq|ne|cs|hs|cc|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?s?'
    r'(?:\.(?:w|n|f16|f32|f64|s16|s32|u16|u32|16|32|64))*$',
  );
  static const _keywords = <String>{
    'alignas',
    'alignof',
    'asm',
    'auto',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'constexpr',
    'continue',
    'default',
    'delete',
    'do',
    'else',
    'enum',
    'explicit',
    'export',
    'extern',
    'for',
    'friend',
    'goto',
    'if',
    'inline',
    'namespace',
    'new',
    'noexcept',
    'operator',
    'private',
    'protected',
    'public',
    'register',
    'return',
    'sizeof',
    'static',
    'struct',
    'switch',
    'template',
    'this',
    'throw',
    'try',
    'typedef',
    'typename',
    'union',
    'using',
    'virtual',
    'volatile',
    'while',
  };
  static const _types = <String>{
    'bool',
    'char',
    'double',
    'float',
    'int',
    'long',
    'short',
    'signed',
    'unsigned',
    'void',
    'wchar_t',
    'size_t',
    'int8_t',
    'int16_t',
    'int32_t',
    'int64_t',
    'uint8_t',
    'uint16_t',
    'uint32_t',
    'uint64_t',
    'true',
    'false',
    'nullptr',
    'NULL',
  };

  List<HighlightedSourceLine> highlight(String source) {
    _gnuAssembly = assembly && _gnuDirective.hasMatch(source);
    final rawLines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    var inBlockComment = false;
    return [
      for (final line in rawLines)
        _highlightLine(
          line,
          () => inBlockComment,
          (value) => inBlockComment = value,
        ),
    ];
  }

  HighlightedSourceLine _highlightLine(
    String line,
    bool Function() isInBlockComment,
    void Function(bool) setBlockComment,
  ) {
    final spans = <TextSpan>[];
    final identifiers = <({int start, int end})>[];
    var index = 0;
    var hasOperation = false;
    final firstNonSpace = line.length - line.trimLeft().length;
    if (!isInBlockComment() &&
        firstNonSpace < line.length &&
        line[firstNonSpace] == '#') {
      spans.add(
        TextSpan(
          text: line,
          style: _style(
            assembly &&
                    !_preprocessorDirective.hasMatch(
                      line.substring(firstNonSpace),
                    )
                ? _SourceTokenKind.comment
                : _SourceTokenKind.preprocessor,
          ),
        ),
      );
      return HighlightedSourceLine(spans, line.length, line);
    }
    while (index < line.length) {
      if (isInBlockComment()) {
        final end = line.indexOf('*/', index);
        if (end < 0) {
          _add(spans, line.substring(index), _SourceTokenKind.comment);
          index = line.length;
        } else {
          _add(spans, line.substring(index, end + 2), _SourceTokenKind.comment);
          index = end + 2;
          setBlockComment(false);
        }
        continue;
      }
      if (line.startsWith('//', index) ||
          assembly &&
              (line[index] == '@' || line[index] == ';' && !_gnuAssembly)) {
        _add(spans, line.substring(index), _SourceTokenKind.comment);
        break;
      }
      if (line.startsWith('/*', index)) {
        final end = line.indexOf('*/', index + 2);
        if (end < 0) {
          _add(spans, line.substring(index), _SourceTokenKind.comment);
          setBlockComment(true);
          break;
        }
        _add(spans, line.substring(index, end + 2), _SourceTokenKind.comment);
        index = end + 2;
        continue;
      }
      final char = line[index];
      // The apostrophe in the ARM banked register R8' is not a string opener.
      if (char == '"' ||
          char == "'" &&
              !(assembly && index > 0 && _isIdentifierPart(line[index - 1]))) {
        final quote = char;
        var end = index + 1;
        while (end < line.length) {
          if (line[end] == '\\') {
            end += 2;
            continue;
          }
          if (line[end++] == quote) break;
        }
        end = math.min(end, line.length);
        _add(spans, line.substring(index, end), _SourceTokenKind.string);
        index = end;
        continue;
      }
      if (_isIdentifierStart(char) ||
          assembly && (char == '.' || char == r'$')) {
        var end = index + 1;
        while (end < line.length &&
            (_isIdentifierPart(line[end]) ||
                assembly && (line[end] == '.' || line[end] == r'$'))) {
          end += 1;
        }
        final word = line.substring(index, end);
        final kind = assembly
            ? _assemblyKind(word, line, index, end, hasOperation)
            : _keywords.contains(word)
            ? _SourceTokenKind.keyword
            : _types.contains(word)
            ? _SourceTokenKind.type
            : _SourceTokenKind.plain;
        _add(spans, word, kind);
        if (kind == _SourceTokenKind.plain || kind == _SourceTokenKind.label) {
          identifiers.add((start: index, end: end));
        }
        if (kind == _SourceTokenKind.keyword ||
            kind == _SourceTokenKind.preprocessor) {
          hasOperation = true;
        }
        index = end;
        continue;
      }
      if (_isDigit(char)) {
        var end = index + 1;
        while (end < line.length &&
            (_isIdentifierPart(line[end]) || line[end] == '.')) {
          end += 1;
        }
        _add(spans, line.substring(index, end), _SourceTokenKind.number);
        index = end;
        continue;
      }
      _add(spans, char, _SourceTokenKind.plain);
      if (assembly && char == ';') hasOperation = false;
      index += 1;
    }
    if (line.isEmpty) spans.add(const TextSpan(text: ''));
    return HighlightedSourceLine(
      spans,
      line.length,
      line,
      identifiers: identifiers,
    );
  }

  _SourceTokenKind _assemblyKind(
    String word,
    String line,
    int start,
    int end,
    bool hasOperation,
  ) {
    final lower = word.toLowerCase();
    final rest = line.substring(end).trimLeft();
    if (!hasOperation && rest.startsWith(':')) return _SourceTokenKind.label;
    if (!hasOperation &&
        (lower.startsWith('.') &&
                (_gnuDirectives.contains(lower.substring(1)) ||
                    lower.startsWith('.cfi_')) ||
            _assemblyDirectives.contains(lower))) {
      return _SourceTokenKind.preprocessor;
    }
    if (!hasOperation && _assemblyInstruction.hasMatch(lower)) {
      return _SourceTokenKind.keyword;
    }
    if (_assemblyRegisters.hasMatch(lower)) return _SourceTokenKind.type;
    // armasm permits a label in column zero without a colon.
    if (!hasOperation && start == 0) return _SourceTokenKind.label;
    return _SourceTokenKind.plain;
  }

  static void _add(List<TextSpan> spans, String text, _SourceTokenKind kind) {
    spans.add(TextSpan(text: text, style: _style(kind)));
  }

  static final _styles = {
    for (final kind in _SourceTokenKind.values) kind: _createStyle(kind),
  };
  static TextStyle _style(_SourceTokenKind kind) => _styles[kind]!;
  static TextStyle _createStyle(_SourceTokenKind kind) => TextStyle(
    color: switch (kind) {
      _SourceTokenKind.plain => TalColors.text,
      _SourceTokenKind.keyword => TalSyntaxColors.keyword,
      _SourceTokenKind.type => TalSyntaxColors.type,
      _SourceTokenKind.number => TalSyntaxColors.number,
      _SourceTokenKind.string => TalSyntaxColors.string,
      _SourceTokenKind.comment => TalSyntaxColors.comment,
      _SourceTokenKind.preprocessor => TalSyntaxColors.preprocessor,
      _SourceTokenKind.label => TalSyntaxColors.type,
    },
  );

  static bool _isIdentifierStart(String value) {
    final code = value.codeUnitAt(0);
    return code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95;
  }

  static bool _isIdentifierPart(String value) =>
      _isIdentifierStart(value) || _isDigit(value);
  static bool _isDigit(String value) {
    final code = value.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }
}
