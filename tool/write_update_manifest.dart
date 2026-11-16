import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:take_a_look_v2/src/updates/update_models.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError('Usage: write_update_manifest ROOT KIND VERSION ARCH');
  }
  final root = Directory(args[0]);
  final files = <String>{updateManifestName};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! Directory) {
      files.add(p.relative(entity.path, from: root.path).replaceAll('\\', '/'));
    }
  }
  final manifest = UpdatePackageManifest(
    kind: args[1],
    version: args[2],
    architecture: args[3],
    files: files,
  );
  if (!files.contains(manifest.executable) ||
      !files.contains(manifest.helper)) {
    throw StateError('Package is missing its application or updater.');
  }
  await File(p.join(root.path, updateManifestName)).writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
  );
}
