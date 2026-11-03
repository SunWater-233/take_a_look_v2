// Read-only validation of an existing release MSI. Does not install it.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/update_installer.dart';
import 'package:take_a_look_v2/src/updates/update_models.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 2) {
    throw ArgumentError(
      'Usage: dart run tool/tests/update_msi_preflight_test.dart PACKAGE.msi VERSION',
    );
  }
  final root = await Directory.systemTemp.createTemp('tal MSI preflight 中文 ');
  try {
    final installation = await Directory(
      p.join(root.path, 'installed'),
    ).create();
    final work = await Directory(p.join(root.path, 'download')).create();
    final manifest = UpdatePackageManifest(
      kind: 'windows-msi',
      version: '0.0.0',
      architecture: 'x64',
      files: {'take_a_look_v2.exe'},
    );
    await File(
      p.join(installation.path, updateManifestName),
    ).writeAsString(jsonEncode(manifest.toJson()));
    await File(
      p.join(installation.path, manifest.executable),
    ).writeAsString('fixture');
    final archive = File(args[0]).absolute;
    final job = {
      'work': work.path,
      'installation': installation.path,
      'archive': archive.path,
      'sha256': (await sha256.bind(archive.openRead()).first).toString(),
      'version': args[1],
      'parentPid': pid,
      'result': p.join(work.path, 'result.json'),
    };
    await UpdateInstaller(job).prepare();
    var rejected = false;
    try {
      await UpdateInstaller({...job, 'version': '99.0.0'}).prepare();
    } on StateError {
      rejected = true;
    }
    if (!rejected) throw StateError('MSI version mismatch was not rejected.');
    stdout.writeln(
      'PASS: real MSI UpgradeCode and ProductVersion validated; mismatched release version rejected. No installation performed.',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
