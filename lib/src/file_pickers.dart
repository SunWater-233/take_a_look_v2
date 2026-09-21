import 'package:file_selector/file_selector.dart';

Future<String?> pickSymbolFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'ELF/AXF 固件符号', extensions: ['elf', 'axf']),
    ],
  );
  return file?.path;
}

Future<String?> pickSourceFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'C/C++ 源码',
        extensions: [
          'c',
          'cc',
          'cpp',
          'cxx',
          'h',
          'hh',
          'hpp',
          'hxx',
          's',
          'S',
        ],
      ),
    ],
  );
  return file?.path;
}

Future<String?> pickCsvExportPath() async {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final name =
      'raw_samples_${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.csv';
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV 文件', extensions: ['csv']),
    ],
  );
  return location?.path;
}

/// Opens a CSV file and returns its text so callers do not need to depend on
/// dart:io (the picker itself also works on the web target).
Future<String?> pickCsvImportContents() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV 文件', extensions: ['csv']),
    ],
  );
  return file?.readAsString();
}
