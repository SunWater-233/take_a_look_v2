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
  final _prepared = Expando<Future<PreparedSourceText>>();
  Future<PreparedSourceText> prepare(SourceSearchText document) =>
      _prepared[document] ??= document.text.length < 256 * 1024
      ? Future.value(_prepareSource(document.text))
      : compute(_prepareSource, document.text);
}

PreparedSourceText _prepareSource(String source) =>
    PreparedSourceText(_CppSyntaxHighlighter().highlight(source));

enum _SourceTokenKind {
  plain,
  keyword,
  type,
  number,
  string,
  comment,
  preprocessor,
}

class HighlightedSourceLine {
  const HighlightedSourceLine(this.spans, this.textLength, this.rawText);

  final List<TextSpan> spans;
  final int textLength;
  final String rawText;
}

class _CppSyntaxHighlighter {
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
    var index = 0;
    final firstNonSpace = line.length - line.trimLeft().length;
    if (!isInBlockComment() &&
        firstNonSpace < line.length &&
        line[firstNonSpace] == '#') {
      spans.add(
        TextSpan(text: line, style: _style(_SourceTokenKind.preprocessor)),
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
      if (line.startsWith('//', index)) {
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
      if (char == '"' || char == "'") {
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
      if (_isIdentifierStart(char)) {
        var end = index + 1;
        while (end < line.length && _isIdentifierPart(line[end])) {
          end += 1;
        }
        final word = line.substring(index, end);
        final kind = _keywords.contains(word)
            ? _SourceTokenKind.keyword
            : _types.contains(word)
            ? _SourceTokenKind.type
            : _SourceTokenKind.plain;
        _add(spans, word, kind);
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
      index += 1;
    }
    if (line.isEmpty) spans.add(const TextSpan(text: ''));
    return HighlightedSourceLine(spans, line.length, line);
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
