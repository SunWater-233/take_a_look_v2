import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/source_search.dart';

void main() {
  List<String> search(List<String> paths, String query, {int limit = 1000}) =>
      searchSourceFiles(
        paths.map(
          (path) => SourceSearchFile(path: path, sourceRoot: 'C:/project'),
        ),
        query,
        limit: limit,
      ).map((file) => file.path).toList();

  test('C sources and headers precede exact ordinary and artifact matches', () {
    expect(
      search([
        'motor',
        'motor.txt',
        'motor.OBJ',
        'motor.elf',
        'motor.H',
        'motor.C',
        'motor.cpp',
      ], 'MOTOR'),
      [
        'motor.C',
        'motor.H',
        'motor',
        'motor.cpp',
        'motor.txt',
        'motor.elf',
        'motor.OBJ',
      ],
    );
  });

  test(
    'literal filename matches precede fuzzy abbreviations in each group',
    () {
      expect(search(['motor.c', 'a_mtr.c', 'mtr.h'], 'mtr'), [
        'mtr.h',
        'a_mtr.c',
        'motor.c',
      ]);
      expect(
        search(['motor_controller.c', 'motor.c'], 'motor.c').first,
        'motor.c',
      );
    },
  );

  test('abbreviations match ordered characters and favor word boundaries', () {
    expect(
      search([
        'motor_controller.c',
        'motor_controller.h',
        'monitor.c',
      ], 'MTRCTRL'),
      ['motor_controller.c', 'motor_controller.h'],
    );
    expect(
      search(['magic.c', 'motor_controller.c'], 'mc').first,
      'motor_controller.c',
    );
    expect(search(['motor_controller.c'], 'rlctrlm'), isEmpty);
    expect(search(['motor_controller.c'], '   '), isEmpty);
  });

  test('fuzzy path search accepts either separator and whitespace', () {
    final paths = [
      'C:/project/src/motor_controller.c',
      'C:/project/include/motor_controller.h',
    ];
    expect(search(paths, r'SRC\mtr ctrl'), [paths.first]);
    expect(search(paths, 'incl mtrctrl'), [paths.last]);
    expect(search(paths, 'SRC/MOTOR_CONTROLLER.C'), [paths.first]);
  });

  test(
    'fuzzy matching excludes unrelated absolute root directory characters',
    () {
      final file = SourceSearchFile(
        path: 'C:/abbreviated_project/src/motor.c',
        sourceRoot: 'C:/abbreviated_project',
      );
      expect(searchSourceFiles([file], 'abbrprj'), isEmpty);
      expect(searchSourceFiles([file], 'srcmtr'), [file]);
    },
  );

  test('both local paths and DWARF paths remain searchable', () {
    final file = SourceSearchFile(
      path: 'Z:/build/source/motor.c',
      localPath: 'C:/project/src/motor.c',
      sourceRoot: 'C:/project',
    );
    expect(searchSourceFiles([file], 'src/mtr'), [file]);
    expect(searchSourceFiles([file], r'Z:\build\source'), [file]);
  });

  test('file priority applies before the result limit', () {
    expect(
      search(
        [
          for (var index = 0; index < 2000; index += 1) 'build/motor_$index.o',
          'motor.txt',
          'src/motor_controller.c',
          'include/motor_controller.h',
        ],
        'motor',
        limit: 2,
      ),
      ['src/motor_controller.c', 'include/motor_controller.h'],
    );
  });

  test(
    'binary artifacts skip content search while text outputs remain readable',
    () {
      for (final name in ['motor.O', 'motor.OBJ', 'motor.elf', 'motor.so.1']) {
        expect(SourceSearchFile(path: name).isBinaryArtifact, isTrue);
      }
      for (final name in ['motor.c', 'motor.map', 'motor.lst', 'motor.hex']) {
        expect(SourceSearchFile(path: name).isBinaryArtifact, isFalse);
      }
    },
  );

  test(
    'content searches preserve literal text and original line locations',
    () {
      final document = SourceSearchText(
        'int READY;\r\n  motor_controller();\rready READY;',
      );
      expect(document.search('READY').toList(), [
        (line: 1, column: 5, preview: 'int READY;'),
        (line: 3, column: 1, preview: 'ready READY;'),
      ]);
      expect(document.search('mtrctrl'), isEmpty);
      expect(document.search('motor_controller();').single, (
        line: 2,
        column: 3,
        preview: 'motor_controller();',
      ));
      expect(document.search('ready', limit: 1).length, 1);
      expect(document.search('missing'), isEmpty);
      expect(document.search('ready').length, 2);
      expect(document.search(''), isEmpty);
    },
  );
}
