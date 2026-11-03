import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'update_models.dart';

typedef MacosUpdateCommand =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Native bundle tools preserve framework symlinks, executable permissions,
/// resource forks and code signatures. App data lives outside the signed app.
class MacosBundleUpdater {
  MacosBundleUpdater({MacosUpdateCommand? command}) : command = command ?? _run;
  final MacosUpdateCommand command;

  static Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(executable, arguments);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final code = await process.exitCode.timeout(
        Duration(minutes: executable.endsWith('/osascript') ? 10 : 2),
      );
      return ProcessResult(process.pid, code, await output, await errors);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  Future<ProcessResult> _checked(
    String executable,
    List<String> arguments,
  ) async {
    final result = await command(executable, arguments);
    if (result.exitCode != 0) {
      throw StateError(
        'macOS 更新检查失败（${p.basename(executable)}）：${result.stderr}',
      );
    }
    return result;
  }

  /// Validate paths before ditto touches the filesystem, including link
  /// ancestors. __MACOSX contains AppleDouble metadata, not another app.
  static String validateArchive(Archive entries) {
    final names = <String>{};
    final links = <String, String>{};
    final roots = <String>{};
    var total = 0;
    for (final entry in entries) {
      final name = entry.name.replaceAll(RegExp(r'/+$'), '');
      if (!safePackagePath(name) || !names.add(name.toLowerCase())) {
        throw const FormatException('Mac 更新包包含无效或重复路径。');
      }
      final root = name.split('/').first;
      if (root != '__MACOSX') roots.add(root);
      total += entry.size;
      if (total > 8 * 1024 * 1024 * 1024) {
        throw const FormatException('Mac 更新包解压大小超出限制。');
      }
      if (entry.isSymbolicLink) {
        final target = entry.symbolicLink!;
        final resolved = p.posix.normalize(
          p.posix.join(p.posix.dirname(name), target),
        );
        if (root == '__MACOSX' ||
            target.contains('\\') ||
            p.posix.isAbsolute(target) ||
            !p.posix.isWithin(root, resolved)) {
          throw const FormatException('Mac 更新包的符号链接指向应用外。');
        }
        links[name] = target;
      }
    }
    if (roots.length != 1 || !roots.single.endsWith('.app')) {
      throw const FormatException('Mac 更新 ZIP 必须只包含一个完整的 .app。');
    }
    for (final link in links.keys) {
      if (names.any((name) => name.startsWith('${link.toLowerCase()}/'))) {
        throw const FormatException('Mac 更新包不能通过符号链接写入文件。');
      }
    }
    return roots.single;
  }

  Future<Directory> extract(File archive, Directory work) async {
    final input = InputFileStream(archive.path);
    late final String name;
    try {
      name = validateArchive(ZipDecoder().decodeStream(input, verify: true));
    } finally {
      await input.close();
    }
    final directory = await work.createTemp('macos-payload-');
    await _checked('/usr/bin/ditto', [
      '-x',
      '-k',
      archive.path,
      directory.path,
    ]);
    return Directory(p.join(directory.path, name));
  }

  Future<Map<String, dynamic>> _info(Directory bundle) async {
    final result = await _checked('/usr/bin/plutil', [
      '-convert',
      'json',
      '-o',
      '-',
      p.join(bundle.path, 'Contents', 'Info.plist'),
    ]);
    return jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
  }

  Future<String?> _team(Directory bundle) async {
    final result = await _checked('/usr/bin/codesign', [
      '-d',
      '--verbose=4',
      bundle.path,
    ]);
    final match = RegExp(
      r'^TeamIdentifier=(.+)$',
      multiLine: true,
    ).firstMatch('${result.stdout}\n${result.stderr}');
    final value = match?.group(1)?.trim();
    return value == null || value == 'not set' ? null : value;
  }

  Future<void> validate(
    Directory installed,
    Directory replacement,
    UpdatePackageManifest manifest,
  ) async {
    if (!installed.path.endsWith('.app') ||
        !replacement.path.endsWith('.app')) {
      throw const FormatException('Mac 更新必须替换完整的 .app。');
    }
    final old = await _info(installed);
    final info = await _info(replacement);
    if (old['CFBundleIdentifier'] != macosBundleIdentifier ||
        info['CFBundleIdentifier'] != macosBundleIdentifier ||
        info['CFBundleExecutable'] != 'take_a_look_v2' ||
        releaseVersion(info['CFBundleShortVersionString'] as String) !=
            releaseVersion(manifest.version) ||
        info['CFBundleVersion'].toString() !=
            (manifest.version.contains('+')
                ? manifest.version.split('+').last
                : '0')) {
      throw const FormatException('Mac 更新包的应用标识、可执行文件或版本不匹配。');
    }
    if (releaseVersion(old['CFBundleShortVersionString'] as String) >=
        releaseVersion(manifest.version)) {
      throw const FormatException('已安装的 Mac 版本发生变化，请重新检查更新。');
    }
    await _checked('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      installed.path,
    ]);
    await _checked('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      replacement.path,
    ]);
    final oldTeam = await _team(installed);
    final newTeam = await _team(replacement);
    if (oldTeam != null) {
      if (oldTeam != newTeam || !RegExp(r'^[A-Z0-9]+$').hasMatch(oldTeam)) {
        throw const FormatException('更新包的签名发布者与已安装版本不同。');
      }
      // A matching OU string alone is not a trust anchor. Require Apple's
      // certificate chain and the same identity, even if a fake cert uses it.
      final requirement =
          'anchor apple generic and identifier "$macosBundleIdentifier" and certificate leaf[subject.OU] = "$oldTeam"';
      await _checked('/usr/bin/codesign', [
        '--verify',
        '--strict',
        '-R',
        requirement,
        replacement.path,
      ]);
      await _checked('/usr/sbin/spctl', [
        '--assess',
        '--type',
        'execute',
        replacement.path,
      ]);
    }
    final expected = manifest.architecture;
    for (final path in [manifest.executable, manifest.helper]) {
      if (!(await binaryArchitectures(
        File(p.join(replacement.path, path)),
      )).contains(expected)) {
        throw const FormatException('Mac 更新包架构与当前安装不符。');
      }
    }
  }

  /// Read Mach-O headers directly: end users do not need Xcode's lipo tool.
  static Future<Set<String>> binaryArchitectures(File file) async {
    final input = await file.open();
    try {
      final header = await input.read(8);
      if (header.length != 8) throw const FormatException('Mac 可执行文件头不完整。');
      final data = ByteData.sublistView(header);
      final magic = data.getUint32(0);
      final types = <int>[];
      if ([0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)) {
        final endian = [0xbebafeca, 0xbfbafeca].contains(magic)
            ? Endian.little
            : Endian.big;
        final count = data.getUint32(4, endian);
        final size = [0xcafebabf, 0xbfbafeca].contains(magic) ? 32 : 20;
        if (count == 0 || count > 16) {
          throw const FormatException('Mac 通用二进制文件头无效。');
        }
        final bytes = await input.read(count * size);
        if (bytes.length != count * size) {
          throw const FormatException('Mac 通用二进制文件头不完整。');
        }
        final architectures = ByteData.sublistView(bytes);
        for (var i = 0; i < count; i++) {
          types.add(architectures.getUint32(i * size, endian));
        }
      } else if ([
        0xfeedface,
        0xfeedfacf,
        0xcefaedfe,
        0xcffaedfe,
      ].contains(magic)) {
        types.add(
          data.getUint32(
            4,
            [0xcefaedfe, 0xcffaedfe].contains(magic)
                ? Endian.little
                : Endian.big,
          ),
        );
      } else {
        throw const FormatException('Mac 更新包中的程序不是 Mach-O 文件。');
      }
      return {
        if (types.contains(0x01000007)) 'x64',
        if (types.contains(0x0100000c)) 'arm64',
      };
    } finally {
      await input.close();
    }
  }

  /// Never merge loose files into a signed .app. Keep its complete old bundle
  /// for recovery; user recordings and configuration are in Application Support.
  Future<Map<String, dynamic>> install(
    Directory installed,
    Directory replacement,
    UpdatePackageManifest manifest, {
    Future<void> Function(Directory directory, String destination)?
    moveDirectory,
    Future<bool> Function()? cancelled,
  }) async {
    final staging = await installed.parent.createTemp('.take-a-look-new-');
    final backup = await installed.parent.createTemp('.take-a-look-backup-');
    final staged = Directory(p.join(staging.path, p.basename(installed.path)));
    final previous = Directory(p.join(backup.path, p.basename(installed.path)));
    Future<void> move(Directory directory, String destination) async {
      if (moveDirectory == null) {
        await directory.rename(destination);
      } else {
        await moveDirectory(directory, destination);
      }
    }

    var movedOld = false;
    var movedNew = false;
    try {
      await _checked('/usr/bin/ditto', [replacement.path, staged.path]);
      await validate(installed, staged, manifest);
      if (await cancelled?.call() == true) throw StateError('Mac 更新安装已取消。');
      await move(installed, previous.path);
      movedOld = true;
      await move(staged, installed.path);
      movedNew = true;
      return {'status': 'success', 'backup': previous.path};
    } catch (_) {
      if (movedOld && !movedNew) await move(previous, installed.path);
      rethrow;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
      if (!movedOld && await backup.exists()) await backup.delete();
    }
  }

  Future<void> relaunch(Directory bundle, List<String> arguments) async {
    await _checked('/usr/bin/open', [
      '-n',
      bundle.path,
      '--args',
      ...arguments,
    ]);
  }

  Future<ProcessResult> authorize(
    String helper,
    String job,
  ) => command('/usr/bin/osascript', [
    '-e',
    'on run argv\n do shell script ((quoted form of (item 1 of argv)) & " --apply " & (quoted form of (item 2 of argv))) with administrator privileges\nend run',
    helper,
    job,
  ]);
}
