// Real-process test; never installs the production app or uses its data.
// Run with the platform's Dart SDK from the project root.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/update_models.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp(
    'tal updater lifecycle 中文 ',
  );
  Process? parent;
  Process? helper;
  try {
    final suffix = Platform.isWindows ? '.exe' : '';
    final helperName = '$updateHelperName$suffix';
    final application = Platform.isWindows
        ? 'take_a_look_v2.exe'
        : 'take-a-look';
    final compiledHelper = p.join(root.path, helperName);
    final fixture = p.join(root.path, 'fixture$suffix');
    await _command(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'tool/update_helper.dart',
      '-o',
      compiledHelper,
    ]);
    await _command(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'tool/tests/update_restart_fixture.dart',
      '-o',
      fixture,
    ]);
    await _command(compiledHelper, ['--self-test']);
    final installation = await Directory(p.join(root.path, '应用 程序')).create();
    final work = await Directory(p.join(root.path, '下载 缓存')).create();
    await File(fixture).copy(p.join(installation.path, application));
    await File(compiledHelper).copy(p.join(installation.path, helperName));
    await File(
      p.join(installation.path, 'obsolete.txt'),
    ).writeAsString('old program file');
    final old = UpdatePackageManifest(
      kind: Platform.isWindows ? 'windows-portable' : 'linux-archive',
      version: '1.0.0',
      architecture: 'x64',
      files: {application, helperName, 'obsolete.txt', updateManifestName},
    );
    await File(
      p.join(installation.path, updateManifestName),
    ).writeAsString(jsonEncode(old.toJson()));
    final journal = File(
      p.join(installation.path, 'recordings', 'live.talraw'),
    );
    await journal.parent.create();
    await journal.writeAsString('keep my recordings');
    final replacement = UpdatePackageManifest(
      kind: old.kind,
      version: '1.1.0',
      architecture: 'x64',
      files: {application, helperName, updateManifestName},
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(application, await File(fixture).readAsBytes())
          ..mode = 0x1ed,
      )
      ..addFile(
        ArchiveFile.bytes(helperName, await File(compiledHelper).readAsBytes())
          ..mode = 0x1ed,
      )
      ..addFile(
        ArchiveFile.string(
          updateManifestName,
          jsonEncode(replacement.toJson()),
        ),
      );
    final bytes = Platform.isWindows
        ? ZipEncoder().encode(archive)
        : gzip.encode(TarEncoder().encode(archive));
    final download = File(
      p.join(work.path, Platform.isWindows ? 'update.zip' : 'update.tar.gz'),
    );
    await download.writeAsBytes(bytes);
    final stop = File(p.join(root.path, 'close-parent'));
    final restarted = File(p.join(root.path, 'restarted'));
    parent = await Process.start(p.join(installation.path, application), [
      '--wait',
      stop.path,
    ]);
    // Consume pipes, even though the fixture normally writes no output.
    unawaited(parent.stdout.drain<void>());
    unawaited(parent.stderr.drain<void>());
    final resultFile = File(p.join(root.path, 'result.json'));
    final startupResult = File(p.join(root.path, 'startup-result.json'));
    final job = File(p.join(work.path, 'job.json'));
    await job.writeAsString(
      jsonEncode({
        'work': work.path,
        'installation': installation.path,
        'archive': download.path,
        'sha256': sha256.convert(bytes).toString(),
        'version': 'v1.1.0',
        'parentPid': parent.pid,
        'result': resultFile.path,
        'startupResult': startupResult.path,
        'restartArguments': ['--record', restarted.path],
      }),
    );
    helper = await Process.start(compiledHelper, [
      '--job',
      job.path,
    ], workingDirectory: work.path);
    final errors = helper.stderr.transform(utf8.decoder).join();
    unawaited(helper.stdout.drain<void>());
    await _waitFor(File(p.join(work.path, 'ready')));
    _expect(
      (await UpdatePackageManifest.read(installation)).version == '1.0.0',
      'updated before commit',
    );
    await File(p.join(work.path, 'commit')).writeAsString('apply', flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _expect(
      (await UpdatePackageManifest.read(installation)).version == '1.0.0',
      'updated while parent was alive',
    );
    await stop.writeAsString('close', flush: true);
    await parent.exitCode.timeout(const Duration(seconds: 10));
    final exit = await helper.exitCode.timeout(const Duration(seconds: 30));
    _expect(exit == 0, 'helper exited $exit: ${await errors}');
    final result = jsonDecode(await resultFile.readAsString()) as Map;
    _expect(result['status'] == 'success', 'update failed: $result');
    _expect(
      (jsonDecode(await startupResult.readAsString()) as Map)['status'] ==
          'success',
      'startup result was not published',
    );
    await _waitFor(restarted);
    _expect(
      (await UpdatePackageManifest.read(installation)).version == '1.1.0',
      'wrong installed version',
    );
    _expect(
      await journal.readAsString() == 'keep my recordings',
      'recordings changed',
    );
    _expect(
      !await File(p.join(installation.path, 'obsolete.txt')).exists(),
      'obsolete file survived',
    );
    _expect(
      await File(p.join(result['backup'] as String, 'obsolete.txt')).exists(),
      'backup missing',
    );
    stdout.writeln(
      'PASS: standalone helper waits for commit AND parent exit, upgrades in a Chinese/spaced path, preserves recordings, keeps backup, and restarts the new application.',
    );
  } finally {
    parent?.kill();
    helper?.kill();
    // Allow the tiny detached restart fixture to release its executable.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await root.delete(recursive: true);
  }
}

Future<void> _command(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw StateError('${args.join(' ')}\n${result.stdout}\n${result.stderr}');
  }
}

Future<void> _waitFor(File file) async {
  final stopwatch = Stopwatch()..start();
  while (!await file.exists()) {
    if (stopwatch.elapsed > const Duration(seconds: 30)) {
      throw StateError('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
