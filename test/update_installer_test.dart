import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/update_installer.dart';
import 'package:take_a_look_v2/src/updates/update_models.dart';

final _kind = Platform.isWindows ? 'windows-portable' : 'linux-archive';
final _exe = Platform.isWindows ? 'take_a_look_v2.exe' : 'take-a-look';
final _helper = '$updateHelperName${Platform.isWindows ? '.exe' : ''}';

void main() {
  group('native archive updater', () {
    test(
      'upgrade preserves unowned data, removes obsolete program files and keeps a complete backup',
      () async {
        final fixture = await _fixture();
        final installer = UpdateInstaller(fixture.job);
        await installer.prepare();
        final result = await installer.apply();
        expect(result['status'], 'success');
        expect(
          await File(p.join(fixture.install.path, 'obsolete.dll')).exists(),
          isFalse,
        );
        expect(
          await File(
            p.join(fixture.install.path, 'recordings', 'capture.talraw'),
          ).readAsString(),
          'recording',
        );
        expect(
          await File(
            p.join(
              fixture.install.path,
              'backend',
              'recordings',
              'legacy.talraw',
            ),
          ).readAsString(),
          'legacy recording',
        );
        expect(
          await File(
            p.join(fixture.install.path, '用户项目.talproj'),
          ).readAsString(),
          'project',
        );
        expect(
          (await UpdatePackageManifest.read(fixture.install)).version,
          '1.1.0+2',
        );
        final backup = Directory(result['backup'] as String);
        expect(
          await File(p.join(backup.path, 'obsolete.dll')).readAsString(),
          'old library',
        );
        expect((await UpdatePackageManifest.read(backup)).version, '1.0.0+1');
        if (Platform.isLinux) {
          expect(
            (await File(p.join(fixture.install.path, _exe)).stat()).mode & 0x49,
            isNot(0),
          );
        }
      },
    );

    test('failed directory switch restores the entire old version', () async {
      final fixture = await _fixture();
      final installer = UpdateInstaller(
        fixture.job,
        moveDirectory: (directory, destination) async {
          if (p.basename(directory.path).startsWith('.take-a-look-new-')) {
            throw const FileSystemException('simulated locked directory');
          }
          await directory.rename(destination);
        },
      );
      await installer.prepare();
      await expectLater(installer.apply(), throwsA(isA<FileSystemException>()));
      expect(
        (await UpdatePackageManifest.read(fixture.install)).version,
        '1.0.0+1',
      );
      expect(
        await File(p.join(fixture.install.path, 'obsolete.dll')).readAsString(),
        'old library',
      );
      expect(
        await File(
          p.join(fixture.install.path, 'recordings', 'capture.talraw'),
        ).readAsString(),
        'recording',
      );
    });

    test(
      'user-file collision aborts before touching the installation',
      () async {
        final fixture = await _fixture(
          newExtra: {'用户项目.talproj': 'new program file'},
        );
        final installer = UpdateInstaller(fixture.job);
        await installer.prepare();
        await expectLater(installer.apply(), throwsStateError);
        expect(
          (await UpdatePackageManifest.read(fixture.install)).version,
          '1.0.0+1',
        );
        expect(
          await File(
            p.join(fixture.install.path, '用户项目.talproj'),
          ).readAsString(),
          'project',
        );
      },
    );

    test(
      'hash mismatch, wrong architecture, downgrade, and missing files cannot be installed',
      () async {
        final fixture = await _fixture();
        final badHash = {...fixture.job, 'sha256': '0' * 64};
        await expectLater(
          UpdateInstaller(badHash).prepare(),
          throwsFormatException,
        );
        final downgrade = {...fixture.job, 'version': 'v0.9.0'};
        await expectLater(
          UpdateInstaller(downgrade).prepare(),
          throwsFormatException,
        );
        final wrongArchitecture = await _fixture(architecture: 'arm64');
        await expectLater(
          UpdateInstaller(wrongArchitecture.job).prepare(),
          throwsFormatException,
        );
        final missingFile = await _fixture(missingFile: true);
        await expectLater(
          UpdateInstaller(missingFile.job).prepare(),
          throwsFormatException,
        );
      },
    );

    test(
      'malicious archive paths cannot escape the extraction directory',
      () async {
        final fixture = await _fixture(newExtra: {'../escape.txt': 'escaped'});
        await expectLater(
          UpdateInstaller(fixture.job).prepare(),
          throwsFormatException,
        );
        expect(
          await File(p.join(fixture.work.path, 'escape.txt')).exists(),
          isFalse,
        );
        expect(
          (await UpdatePackageManifest.read(fixture.install)).version,
          '1.0.0+1',
        );
      },
    );

    test(
      'an aborted helper never updates a still-running application',
      () async {
        final fixture = await _fixture();
        final jobFile = File(p.join(fixture.work.path, 'job.json'));
        await jobFile.writeAsString(jsonEncode(fixture.job));
        await File(p.join(fixture.work.path, 'abort')).writeAsString('abort');
        await runUpdateHelper(jobFile);
        expect(await File(p.join(fixture.work.path, 'ready')).exists(), isTrue);
        expect(
          (await UpdatePackageManifest.read(fixture.install)).version,
          '1.0.0+1',
        );
        expect(await File(fixture.job['result'] as String).exists(), isFalse);
      },
    );

    test('staging inside the install directory is rejected', () async {
      final fixture = await _fixture();
      final nested = Directory(p.join(fixture.install.path, 'work'))
        ..createSync();
      await expectLater(
        UpdateInstaller({...fixture.job, 'work': nested.path}).prepare(),
        throwsFormatException,
      );
    });
  }, skip: !Platform.isWindows && !Platform.isLinux);
}

Future<({Directory install, Directory work, Map<String, dynamic> job})>
_fixture({
  Map<String, String> newExtra = const {},
  String architecture = 'x64',
  bool missingFile = false,
}) async {
  final root = Directory.systemTemp.createTempSync('tal updater 中文 ');
  addTearDown(() => root.delete(recursive: true));
  final install = Directory(p.join(root.path, '应用 程序'))..createSync();
  final work = Directory(p.join(root.path, '下载'))..createSync();
  final oldFiles = {_exe, _helper, 'obsolete.dll', updateManifestName};
  final old = UpdatePackageManifest(
    kind: _kind,
    version: '1.0.0+1',
    architecture: 'x64',
    files: oldFiles,
  );
  await File(
    p.join(install.path, updateManifestName),
  ).writeAsString(jsonEncode(old.toJson()));
  for (final entry in {
    _exe: 'old program',
    _helper: 'old helper',
    'obsolete.dll': 'old library',
    'recordings/capture.talraw': 'recording',
    'backend/recordings/legacy.talraw': 'legacy recording',
    '用户项目.talproj': 'project',
  }.entries) {
    final file = File(p.join(install.path, entry.key));
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  final newFiles = {
    _exe: Platform.isLinux ? '#!/bin/sh\nexit 0\n' : 'new program',
    _helper: 'new helper',
    'new.dll': 'new library',
    ...newExtra,
  };
  final manifest = UpdatePackageManifest(
    kind: _kind,
    version: '1.1.0+2',
    architecture: architecture,
    files: {
      ...newFiles.keys.where(safePackagePath),
      updateManifestName,
      if (missingFile) 'missing.dll',
    },
  );
  final archive = Archive();
  for (final entry in {
    ...newFiles,
    updateManifestName: jsonEncode(manifest.toJson()),
  }.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value)..mode = 0x1ed);
  }
  final bytes = Platform.isWindows
      ? ZipEncoder().encode(archive)
      : gzip.encode(TarEncoder().encode(archive));
  final file = File(
    p.join(work.path, Platform.isWindows ? 'update.zip' : 'update.tar.gz'),
  );
  await file.writeAsBytes(bytes);
  return (
    install: install,
    work: work,
    job: {
      'work': work.path,
      'installation': install.path,
      'archive': file.path,
      'sha256': sha256.convert(bytes).toString(),
      'version': 'v1.1.0',
      'parentPid': pid,
      'result': p.join(root.path, 'result.json'),
    },
  );
}
