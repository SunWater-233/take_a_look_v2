import 'package:file_selector/file_selector.dart';

Future<String?> pickTargetPack() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CMSIS 芯片支持包', extensions: ['pack']),
    ],
  );
  return file?.path;
}

Future<String?> pickSymbolFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'ELF/AXF 固件符号', extensions: ['elf', 'axf']),
    ],
  );
  return file?.path;
}

Future<String?> pickSourceRootDirectory() {
  return getDirectoryPath(confirmButtonText: '选择工程源码根目录');
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

Future<String?> pickCsvImportPath() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV 文件', extensions: ['csv']),
    ],
  );
  return file?.path;
}
