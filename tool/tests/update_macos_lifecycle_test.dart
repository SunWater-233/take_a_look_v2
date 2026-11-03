// Native macOS integration: real signatures, ditto archives, symlinks,
// process-exit handshake, whole-bundle replacement and Launch Services restart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/update_models.dart';

Future<void> main() async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('Run this integration test on macOS.');
  }
  final temporary = await Directory.systemTemp.createTemp(
    'tal mac updater 中文 ',
  );
  final root = Directory(await temporary.resolveSymbolicLinks());
  Process? parent;
  Process? helper;
  try {
    final compiled = p.join(root.path, updateHelperName);
    final fixture = p.join(root.path, 'fixture');
    await _run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'tool/update_helper.dart',
      '-o',
      compiled,
    ]);
    await _run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'tool/tests/update_restart_fixture.dart',
      '-o',
      fixture,
    ]);
    final installed = Directory(p.join(root.path, 'installed', 'Fixture.app'));
    final replacement = Directory(p.join(root.path, 'download', 'Fixture.app'));
    final architecture =
        (await _run('/usr/bin/uname', ['-m'])).stdout.toString().trim() ==
            'arm64'
        ? 'arm64'
        : 'x64';
    for (final bundle in [installed, replacement]) {
      final old = bundle == installed;
      final manifest = UpdatePackageManifest(
        kind: 'macos-app',
        version: old ? '1.0.0+1' : '1.1.0+2',
        architecture: architecture,
        files: {
          'Contents/MacOS/take_a_look_v2',
          'Contents/Helpers/$updateHelperName',
          'Contents/Info.plist',
          'Contents/Resources/$updateManifestName',
        },
      );
      for (final entry in {
        manifest.executable: fixture,
        manifest.helper: compiled,
      }.entries) {
        final target = File(p.join(bundle.path, entry.key));
        await target.parent.create(recursive: true);
        await File(entry.value).copy(target.path);
        await _run('/bin/chmod', ['u+x', target.path]);
        await _run('/usr/bin/codesign', [
          '--force',
          '--sign',
          '-',
          '--timestamp=none',
          target.path,
        ]);
      }
      final resources = Directory(p.join(bundle.path, 'Contents', 'Resources'));
      await resources.create(recursive: true);
      await File(
        p.join(bundle.path, manifest.manifestPath),
      ).writeAsString(jsonEncode(manifest.toJson()));
      await File(p.join(bundle.path, 'Contents', 'Info.plist')).writeAsString(
        '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$macosBundleIdentifier</string>
<key>CFBundleExecutable</key><string>take_a_look_v2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Take A Look Update Test</string>
<key>CFBundleShortVersionString</key><string>${old ? '1.0.0' : '1.1.0'}</string>
<key>CFBundleVersion</key><string>${old ? '1' : '2'}</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
''',
      );
      final versioned = Directory(p.join(resources.path, 'versioned'));
      await versioned.create();
      await File(
        p.join(versioned.path, 'data'),
      ).writeAsString(old ? 'old' : 'new');
      await Link(p.join(resources.path, 'current')).create('versioned');
      if (old) {
        await File(
          p.join(resources.path, 'old-only'),
        ).writeAsString('retained in backup');
      }
      await _run('/usr/bin/codesign', [
        '--force',
        '--deep',
        '--sign',
        '-',
        '--timestamp=none',
        bundle.path,
      ]);
      await _run('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        bundle.path,
      ]);
    }
    final archive = File(p.join(root.path, 'update.zip'));
    await _run('/usr/bin/ditto', [
      '-c',
      '-k',
      '--sequesterRsrc',
      '--keepParent',
      replacement.path,
      archive.path,
    ]);
    final hash = (await sha256.bind(archive.openRead()).first).toString();
    final stop = File(p.join(root.path, 'stop'));
    final restarted = File(p.join(root.path, 'restarted'));
    parent = await Process.start(
      p.join(installed.path, 'Contents', 'MacOS', 'take_a_look_v2'),
      ['--wait', stop.path],
    );
    unawaited(parent.stdout.drain<void>());
    unawaited(parent.stderr.drain<void>());
    final work = await Directory(p.join(root.path, 'work')).create();
    final copied = await File(
      p.join(installed.path, 'Contents', 'Helpers', updateHelperName),
    ).copy(p.join(work.path, updateHelperName));
    await _run('/bin/chmod', ['u+x', copied.path]);
    final resultFile = File(p.join(root.path, 'result.json'));
    final job = File(p.join(work.path, 'job.json'));
    await job.writeAsString(
      jsonEncode({
        'work': work.path,
        'installation': installed.path,
        'archive': archive.path,
        'sha256': hash,
        'version': 'v1.1.0',
        'parentPid': parent.pid,
        'result': resultFile.path,
        'restartArguments': ['--record', restarted.path],
      }),
    );
    helper = await Process.start(copied.path, [
      '--job',
      job.path,
    ], workingDirectory: work.path);
    unawaited(helper.stdout.drain<void>());
    final errors = helper.stderr.transform(utf8.decoder).join();
    await _waitFor(File(p.join(work.path, 'ready')), result: resultFile);
    _expect(
      (await UpdatePackageManifest.read(installed)).version == '1.0.0+1',
      'updated before commit',
    );
    await File(p.join(work.path, 'commit')).writeAsString('apply', flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _expect(
      (await UpdatePackageManifest.read(installed)).version == '1.0.0+1',
      'updated before parent exit',
    );
    await stop.writeAsString('close', flush: true);
    await parent.exitCode.timeout(const Duration(seconds: 10));
    final code = await helper.exitCode.timeout(const Duration(seconds: 45));
    _expect(code == 0, 'helper exit $code: ${await errors}');
    final result = jsonDecode(await resultFile.readAsString()) as Map;
    _expect(result['status'] == 'success', 'update failed: $result');
    await _waitFor(restarted);
    _expect(
      (await UpdatePackageManifest.read(installed)).version == '1.1.0+2',
      'wrong installed version',
    );
    _expect(
      await Link(
            p.join(installed.path, 'Contents', 'Resources', 'current'),
          ).target() ==
          'versioned',
      'symlink lost',
    );
    _expect(
      await File(
            p.join(installed.path, 'Contents', 'Resources', 'current', 'data'),
          ).readAsString() ==
          'new',
      'wrong bundle contents',
    );
    _expect(
      !await File(
        p.join(installed.path, 'Contents', 'Resources', 'old-only'),
      ).exists(),
      'old resources merged into signed app',
    );
    _expect(
      await File(
        p.join(result['backup'] as String, 'Contents', 'Resources', 'old-only'),
      ).exists(),
      'old signed bundle backup missing',
    );
    await _run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      installed.path,
    ]);
    stdout.writeln(
      'PASS: macOS signed .app ZIP, native helper, commit/parent wait, intact symlinks/signature, complete backup and Launch Services restart with recovery arguments.',
    );
  } finally {
    parent?.kill();
    helper?.kill();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await root.delete(recursive: true);
  }
}

Future<ProcessResult> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw StateError('${args.join(' ')}\n${result.stdout}\n${result.stderr}');
  }
  return result;
}

Future<void> _waitFor(File file, {File? result}) async {
  final watch = Stopwatch()..start();
  while (!await file.exists()) {
    if (result != null && await result.exists()) {
      throw StateError(await result.readAsString());
    }
    if (watch.elapsed > const Duration(seconds: 45)) {
      throw StateError('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
