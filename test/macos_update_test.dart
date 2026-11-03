import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/macos_update.dart';
import 'package:take_a_look_v2/src/updates/update_models.dart';

void main() {
  test(
    'locate .app from the executable and read its signed resource manifest',
    () async {
      expect(
        updateInstallationPath(
          '/Applications/Take A Look.app/Contents/MacOS/take_a_look_v2',
          macos: true,
        ),
        '/Applications/Take A Look.app',
      );
      final fixture = await _fixture();
      final manifest = await UpdatePackageManifest.read(fixture.newApp);
      expect(manifest.kind, 'macos-app');
      expect(manifest.helper, 'Contents/Helpers/take_a_look_updater');
      expect(manifest.executable, 'Contents/MacOS/take_a_look_v2');
    },
  );

  test(
    'select native Mac release ZIP, excluding debug ZIPs, DMGs and other architectures',
    () {
      final assets =
          [
                'Take-A-Look-V2-1.2.3+4-macos-arm64.zip',
                'Take-A-Look-V2-1.2.3+4-macos-x64.zip',
                'Take-A-Look-V2-1.2.3+4-macos-arm64.dmg',
                'Take-A-Look-V2-1.2.3+4-macos-arm64-debug.zip',
              ]
              .map(
                (name) => ReleaseAsset(
                  name: name,
                  url: Uri.parse('https://github.com/$name'),
                  size: 10,
                ),
              )
              .toList();
      final release = GitHubRelease(
        tag: 'v1.2.3',
        name: '',
        notes: '',
        assets: assets,
      );
      for (final architecture in ['arm64', 'x64']) {
        final installed = UpdatePackageManifest(
          kind: 'macos-app',
          version: '1.0.0',
          architecture: architecture,
          files: {'Contents/Info.plist'},
        );
        expect(
          release.packageFor(installed)!.name,
          endsWith('macos-$architecture.zip'),
        );
      }
    },
  );

  test(
    'Mac ZIP validation accepts framework aliases and AppleDouble metadata',
    () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'Fixture.app/Contents/Frameworks/Foo.framework/Versions/A/Foo',
            'code',
          ),
        )
        ..addFile(
          ArchiveFile.symlink(
            'Fixture.app/Contents/Frameworks/Foo.framework/Versions/Current',
            'A',
          ),
        )
        ..addFile(
          ArchiveFile.symlink(
            'Fixture.app/Contents/Frameworks/Foo.framework/Foo',
            'Versions/Current/Foo',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            '__MACOSX/Fixture.app/Contents/._Info.plist',
            'metadata',
          ),
        );
      expect(MacosBundleUpdater.validateArchive(archive), 'Fixture.app');
    },
  );

  for (final entry in [
    ArchiveFile.string('../escape', ''),
    ArchiveFile.string('Other.app/Contents/Info.plist', ''),
    ArchiveFile.symlink('Fixture.app/Contents/escape', '../../../outside'),
  ]) {
    test('reject archive escape or extra bundle: ${entry.name}', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('Fixture.app/Contents/Info.plist', '{}'))
        ..addFile(entry);
      expect(
        () => MacosBundleUpdater.validateArchive(archive),
        throwsFormatException,
      );
    });
  }
  test('reject writes through a framework alias', () {
    final archive = Archive()
      ..addFile(ArchiveFile.symlink('Fixture.app/Contents/alias', 'real'))
      ..addFile(
        ArchiveFile.string('Fixture.app/Contents/alias/file', 'content'),
      );
    expect(
      () => MacosBundleUpdater.validateArchive(archive),
      throwsFormatException,
    );
  });

  for (final architecture in ['arm64', 'x64']) {
    test(
      'read thin Mach-O $architecture without requiring Xcode tools',
      () async {
        final root = _temporary();
        final file = File(p.join(root.path, 'binary'));
        await file.writeAsBytes(_machHeader(architecture));
        expect(await MacosBundleUpdater.binaryArchitectures(file), {
          architecture,
        });
      },
    );
  }
  test(
    'read both slices in universal Mach-O and reject truncated headers',
    () async {
      final root = _temporary();
      for (final is64 in [false, true]) {
        for (final endian in [Endian.big, Endian.little]) {
          final size = is64 ? 32 : 20;
          final bytes = ByteData(8 + size * 2)
            ..setUint32(0, is64 ? 0xcafebabf : 0xcafebabe, endian)
            ..setUint32(4, 2, endian)
            ..setUint32(8, 0x01000007, endian)
            ..setUint32(8 + size, 0x0100000c, endian);
          final file = File(p.join(root.path, 'universal'))
            ..writeAsBytesSync(bytes.buffer.asUint8List());
          expect(await MacosBundleUpdater.binaryArchitectures(file), {
            'x64',
            'arm64',
          });
          await file.writeAsBytes(bytes.buffer.asUint8List().take(12).toList());
          await expectLater(
            MacosBundleUpdater.binaryArchitectures(file),
            throwsFormatException,
          );
        }
      }
    },
  );

  test(
    'adhoc releases require valid signatures, matching identity/version and native executable/helper',
    () async {
      final fixture = await _fixture();
      final commands = _Commands(fixture.oldApp);
      await MacosBundleUpdater(
        command: commands.run,
      ).validate(fixture.oldApp, fixture.newApp, fixture.manifest);
      expect(
        commands.calls.where((args) => args.contains('--verify')),
        hasLength(2),
      );
      commands.rejectSignatures = true;
      await expectLater(
        MacosBundleUpdater(
          command: commands.run,
        ).validate(fixture.oldApp, fixture.newApp, fixture.manifest),
        throwsStateError,
      );
    },
  );

  test(
    'signed releases cannot downgrade to ad-hoc or switch publisher',
    () async {
      final fixture = await _fixture();
      for (final newTeam in ['not set', 'DIFFERENT1']) {
        final commands = _Commands(fixture.oldApp)
          ..oldTeam = 'TEAM123456'
          ..newTeam = newTeam;
        await expectLater(
          MacosBundleUpdater(
            command: commands.run,
          ).validate(fixture.oldApp, fixture.newApp, fixture.manifest),
          throwsFormatException,
        );
      }
      final commands = _Commands(fixture.oldApp)
        ..oldTeam = 'TEAM123456'
        ..newTeam = 'TEAM123456';
      await MacosBundleUpdater(
        command: commands.run,
      ).validate(fixture.oldApp, fixture.newApp, fixture.manifest);
      expect(
        commands.calls.any(
          (args) =>
              args.contains('-R') &&
              args.any((value) => value.contains('anchor apple generic')),
        ),
        isTrue,
      );
      expect(commands.calls.any((args) => args.contains('--assess')), isTrue);
      commands.rejectGatekeeper = true;
      await expectLater(
        MacosBundleUpdater(
          command: commands.run,
        ).validate(fixture.oldApp, fixture.newApp, fixture.manifest),
        throwsStateError,
      );
    },
  );

  test(
    'mismatched bundle identity, version and helper architecture are rejected',
    () async {
      final fixture = await _fixture();
      final info = File(p.join(fixture.newApp.path, 'Contents', 'Info.plist'));
      final original =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      final updater = MacosBundleUpdater(
        command: _Commands(fixture.oldApp).run,
      );
      for (final patch in [
        {'CFBundleIdentifier': 'other.product'},
        {'CFBundleShortVersionString': '9.0.0'},
        {'CFBundleVersion': '99'},
      ]) {
        await info.writeAsString(jsonEncode({...original, ...patch}));
        await expectLater(
          updater.validate(fixture.oldApp, fixture.newApp, fixture.manifest),
          throwsFormatException,
        );
      }
      await info.writeAsString(jsonEncode(original));
      await File(
        p.join(fixture.newApp.path, fixture.manifest.helper),
      ).writeAsBytes(_machHeader('x64'));
      await expectLater(
        updater.validate(fixture.oldApp, fixture.newApp, fixture.manifest),
        throwsFormatException,
      );
    },
  );

  test(
    'replace the whole signed bundle, retain backup, leave Application Support data intact',
    () async {
      final fixture = await _fixture();
      final data = File(
        p.join(
          fixture.oldApp.parent.path,
          'Application Support',
          'recordings',
          'capture.talraw',
        ),
      );
      await data.parent.create(recursive: true);
      await data.writeAsString('keep');
      final result = await MacosBundleUpdater(
        command: _Commands(fixture.oldApp).run,
      ).install(fixture.oldApp, fixture.newApp, fixture.manifest);
      expect(
        (await UpdatePackageManifest.read(fixture.oldApp)).version,
        '1.1.0+2',
      );
      expect(
        await File(p.join(fixture.oldApp.path, 'unowned-file')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(result['backup'] as String, 'unowned-file'),
        ).readAsString(),
        'old',
      );
      expect(await data.readAsString(), 'keep');
    },
  );

  test('bundle switch failure restores the old .app', () async {
    final fixture = await _fixture();
    await expectLater(
      MacosBundleUpdater(command: _Commands(fixture.oldApp).run).install(
        fixture.oldApp,
        fixture.newApp,
        fixture.manifest,
        moveDirectory: (directory, destination) async {
          if (p
              .basename(directory.parent.path)
              .startsWith('.take-a-look-new-')) {
            throw const FileSystemException('locked app');
          }
          await directory.rename(destination);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await UpdatePackageManifest.read(fixture.oldApp)).version,
      '1.0.0+1',
    );
    expect(
      await File(p.join(fixture.oldApp.path, 'unowned-file')).readAsString(),
      'old',
    );
  });

  test(
    'cancellation or a newer concurrent installation prevents the bundle swap',
    () async {
      final fixture = await _fixture();
      final updater = MacosBundleUpdater(
        command: _Commands(fixture.oldApp).run,
      );
      await expectLater(
        updater.install(
          fixture.oldApp,
          fixture.newApp,
          fixture.manifest,
          cancelled: () async => true,
        ),
        throwsStateError,
      );
      expect(
        (await UpdatePackageManifest.read(fixture.oldApp)).version,
        '1.0.0+1',
      );
      final info = File(p.join(fixture.oldApp.path, 'Contents', 'Info.plist'));
      final json =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      await info.writeAsString(
        jsonEncode({...json, 'CFBundleShortVersionString': '2.0.0'}),
      );
      await expectLater(
        updater.install(fixture.oldApp, fixture.newApp, fixture.manifest),
        throwsFormatException,
      );
      expect(
        await File(p.join(fixture.oldApp.path, 'unowned-file')).readAsString(),
        'old',
      );
    },
  );

  test(
    'authorization quotes paths in AppleScript, relaunch preserves recovery arguments',
    () async {
      final calls = <(String, List<String>)>[];
      final updater = MacosBundleUpdater(
        command: (tool, arguments) async {
          calls.add((tool, arguments));
          return ProcessResult(0, 0, '', '');
        },
      );
      const job = "/tmp/中文 path/'; touch injected; job.json";
      await updater.authorize('/tmp/helper path', job);
      expect(calls.single.$2.last, job);
      expect(calls.single.$2[1], contains('quoted form'));
      expect(calls.single.$2[1], isNot(contains(job)));
      await updater.relaunch(Directory('/Applications/Fixture.app'), [
        '--restore-after-update',
        job,
      ]);
      expect(calls.last.$1, '/usr/bin/open');
      expect(calls.last.$2, [
        '-n',
        '/Applications/Fixture.app',
        '--args',
        '--restore-after-update',
        job,
      ]);
    },
  );
}

class _Commands {
  _Commands(this.oldApp);
  final Directory oldApp;
  final calls = <List<String>>[];
  String oldTeam = 'not set', newTeam = 'not set';
  bool rejectSignatures = false, rejectGatekeeper = false;
  Future<ProcessResult> run(String executable, List<String> args) async {
    calls.add(args);
    if (executable.endsWith('/plutil')) {
      return ProcessResult(0, 0, await File(args.last).readAsString(), '');
    }
    if (executable.endsWith('/codesign')) {
      if (args.contains('--verify') && rejectSignatures) {
        return ProcessResult(0, 1, '', 'invalid signature');
      }
      if (args.contains('-d')) {
        return ProcessResult(
          0,
          0,
          '',
          'TeamIdentifier=${args.last == oldApp.path ? oldTeam : newTeam}\n',
        );
      }
    }
    if (executable.endsWith('/spctl') && rejectGatekeeper) {
      return ProcessResult(0, 1, '', 'not notarized');
    }
    if (executable.endsWith('/ditto') && args.length == 2) {
      final from = Directory(args[0]), to = Directory(args[1]);
      await to.create(recursive: true);
      await for (final entity in from.list(recursive: true)) {
        final destination = p.join(
          to.path,
          p.relative(entity.path, from: from.path),
        );
        if (entity is Directory) {
          await Directory(destination).create(recursive: true);
        } else if (entity is File) {
          await File(destination).parent.create(recursive: true);
          await entity.copy(destination);
        }
      }
    }
    return ProcessResult(0, 0, '', '');
  }
}

List<int> _machHeader(String architecture) =>
    (ByteData(32)
          ..setUint32(0, 0xfeedfacf, Endian.little)
          ..setUint32(
            4,
            architecture == 'arm64' ? 0x0100000c : 0x01000007,
            Endian.little,
          ))
        .buffer
        .asUint8List();

Directory _temporary() {
  final root = Directory.systemTemp.createTempSync('tal mac updater 中文 ');
  addTearDown(() => root.delete(recursive: true));
  return root;
}

Future<({Directory oldApp, Directory newApp, UpdatePackageManifest manifest})>
_fixture() async {
  final root = _temporary();
  final oldApp = Directory(p.join(root.path, 'installed', 'Fixture.app'));
  final newApp = Directory(p.join(root.path, 'download', 'Fixture.app'));
  late UpdatePackageManifest manifest;
  for (final bundle in [oldApp, newApp]) {
    final isOld = bundle == oldApp;
    manifest = UpdatePackageManifest(
      kind: 'macos-app',
      version: isOld ? '1.0.0+1' : '1.1.0+2',
      architecture: 'arm64',
      files: {
        'Contents/MacOS/take_a_look_v2',
        'Contents/Helpers/take_a_look_updater',
        'Contents/Resources/UPDATE-MANIFEST.json',
      },
    );
    final file = File(p.join(bundle.path, manifest.manifestPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(manifest.toJson()));
    for (final path in [manifest.executable, manifest.helper]) {
      final file = File(p.join(bundle.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_machHeader('arm64'));
    }
    await File(p.join(bundle.path, 'Contents', 'Info.plist')).writeAsString(
      jsonEncode({
        'CFBundleIdentifier': macosBundleIdentifier,
        'CFBundleExecutable': 'take_a_look_v2',
        'CFBundleShortVersionString': isOld ? '1.0.0' : '1.1.0',
        'CFBundleVersion': isOld ? '1' : '2',
      }),
    );
  }
  await File(p.join(oldApp.path, 'unowned-file')).writeAsString('old');
  return (oldApp: oldApp, newApp: newApp, manifest: manifest);
}
