// This library deliberately has no Flutter imports: the same code is compiled
// into a small standalone process which survives closing all Flutter engines.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'update_models.dart';
import 'macos_update.dart';

class UpdateInstaller {
  UpdateInstaller(this.job, {this.moveDirectory});
  final Map<String, dynamic> job;
  final Future<void> Function(Directory directory, String destination)?
  moveDirectory;
  Directory get work => Directory(job['work'] as String);
  Directory get installation => Directory(job['installation'] as String);
  File get archive => File(job['archive'] as String);
  late UpdatePackageManifest installed;
  Directory? payload;
  bool needsElevation = false;

  Future<void> prepare() async {
    final root = await installation.resolveSymbolicLinks();
    final workRoot = await work.resolveSymbolicLinks();
    if (!p.isAbsolute(root) ||
        p.equals(root, p.dirname(root)) ||
        p.isWithin(root, workRoot) ||
        p.isWithin(workRoot, root) ||
        p.equals(root, workRoot) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(job['sha256'] as String)) {
      throw const FormatException('更新路径或校验值无效。');
    }
    if (!p.equals(p.normalize(installation.absolute.path), p.normalize(root))) {
      throw const FormatException('安装目录不能是符号链接。');
    }
    installed = await UpdatePackageManifest.read(installation);
    if ((installed.kind.startsWith('windows-') && !Platform.isWindows) ||
        (installed.kind == 'linux-archive' && !Platform.isLinux) ||
        (installed.kind == 'macos-app' && !Platform.isMacOS)) {
      throw const FormatException('安装包平台与当前系统不匹配。');
    }
    if (!await File(p.join(root, installed.executable)).exists() ||
        releaseVersion(job['version'] as String) <=
            releaseVersion(installed.version)) {
      throw const FormatException('更新版本或安装目录不匹配。');
    }
    final digest = (await sha256.bind(archive.openRead()).first).toString();
    if (digest != job['sha256']) throw const FormatException('更新包校验失败。');
    if (installed.kind == 'windows-msi') {
      await _validateMsi();
    }
    if (installed.kind != 'windows-msi') {
      payload = await _extract();
      final replacement = await UpdatePackageManifest.read(payload!);
      if (replacement.kind != installed.kind ||
          replacement.architecture != installed.architecture ||
          releaseVersion(replacement.version) !=
              releaseVersion(job['version'] as String) ||
          !replacement.files.contains(replacement.executable) ||
          !replacement.files.contains(replacement.helper)) {
        throw const FormatException('更新包类型、架构或版本不匹配。');
      }
      for (final path in replacement.files) {
        if (await FileSystemEntity.type(
              p.join(payload!.path, path),
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound) {
          throw FormatException('更新包缺少文件：$path');
        }
      }
      if (installed.kind == 'macos-app') {
        await MacosBundleUpdater().validate(
          installation,
          payload!,
          replacement,
        );
      }
      if (Platform.isLinux) {
        final check = await Process.run(p.join(payload!.path, 'take-a-look'), [
          '--doctor',
        ]).timeout(const Duration(minutes: 2));
        if (check.exitCode != 0) {
          throw StateError('新版运行环境检查失败：${check.stderr}\n${check.stdout}');
        }
      }
      try {
        final probe = await installation.parent.createTemp(
          '.take-a-look-probe-',
        );
        await probe.delete();
      } on FileSystemException catch (error) {
        if (Platform.isMacOS) {
          if (error.osError?.errorCode == 30) {
            throw StateError('应用位于只读磁盘或临时转移目录，请先将 .app 移到 Applications，再进行更新。');
          }
          needsElevation = true;
          return;
        }
        if (!Platform.isLinux) rethrow;
        needsElevation = true;
        final polkit = await Process.run('sh', ['-c', 'command -v pkexec']);
        if (polkit.exitCode != 0) {
          throw StateError('此安装目录需要管理员权限；请安装 polkit 或手动更新。');
        }
      }
    }
  }

  Future<Directory> _extract() async {
    if (installed.kind == 'macos-app') {
      return MacosBundleUpdater().extract(archive, work);
    }
    final extracted = await work.createTemp('payload-');
    File inputFile = archive;
    if (installed.kind == 'linux-archive') {
      inputFile = File('${extracted.path}.tar');
      var bytes = 0;
      final stream = gzip.decoder.bind(archive.openRead()).map((chunk) {
        bytes += chunk.length;
        if (bytes > 8 * 1024 * 1024 * 1024) {
          throw const FormatException('更新包解压大小超出限制。');
        }
        return chunk;
      });
      await stream.pipe(inputFile.openWrite());
    }
    final input = InputFileStream(inputFile.path);
    try {
      final entries = installed.kind == 'windows-portable'
          ? ZipDecoder().decodeStream(input, verify: true)
          : TarDecoder().decodeStream(input, verify: true);
      var total = 0;
      final seen = <String>{};
      final links = <ArchiveFile>[];
      final executablePaths = <String>[];
      for (final entry in entries) {
        final name = entry.name.replaceAll(RegExp(r'/+$'), '');
        if (!safePackagePath(name)) {
          throw FormatException('更新包包含无效路径：${entry.name}');
        }
        final key = Platform.isWindows ? name.toLowerCase() : name;
        if (!seen.add(key)) throw FormatException('更新包包含重复路径：$name');
        total += entry.size;
        if (total > 8 * 1024 * 1024 * 1024) {
          throw const FormatException('更新包解压大小超出限制。');
        }
        final destination = p.joinAll([extracted.path, ...name.split('/')]);
        if (entry.isSymbolicLink) {
          if (Platform.isWindows) {
            throw const FormatException('Windows 更新包包含符号链接。');
          }
          final target = entry.symbolicLink!;
          final resolved = p.normalize(p.join(p.dirname(destination), target));
          if (p.isAbsolute(target) || !p.isWithin(extracted.path, resolved)) {
            throw const FormatException('更新包链接指向包外。');
          }
          links.add(entry);
        } else if (entry.isFile) {
          await File(destination).parent.create(recursive: true);
          final output = OutputFileStream(destination);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
          if ((entry.mode & 0x49) != 0) executablePaths.add(destination);
        } else {
          await Directory(destination).create(recursive: true);
        }
      }
      // Links are last so archive entries can never write through a link.
      for (final entry in links) {
        final link = Link(p.join(extracted.path, entry.name));
        await link.parent.create(recursive: true);
        await link.create(entry.symbolicLink!);
      }
      if (Platform.isLinux) {
        for (var i = 0; i < executablePaths.length; i += 100) {
          final paths = executablePaths.skip(i).take(100).toList();
          final result = await Process.run('chmod', ['+x', '--', ...paths]);
          if (result.exitCode != 0) throw StateError('无法恢复更新文件的执行权限。');
        }
      }
    } finally {
      await input.close();
    }
    if (await File(p.join(extracted.path, updateManifestName)).exists()) {
      return extracted;
    }
    final children = await extracted.list(followLinks: false).toList();
    if (children.length == 1 &&
        children.single is Directory &&
        await File(p.join(children.single.path, updateManifestName)).exists()) {
      return Directory(children.single.path);
    }
    throw const FormatException('更新包缺少包清单。');
  }

  Future<Map<String, dynamic>> apply() async {
    final current = await UpdatePackageManifest.read(installation);
    if (current.version != installed.version ||
        current.kind != installed.kind) {
      throw StateError('安装目录在准备更新后发生变化，请重新检查更新。');
    }
    if (installed.kind == 'windows-msi') {
      final log = p.join(work.path, 'msi.log');
      final result = await Process.run('msiexec.exe', [
        '/i',
        archive.path,
        '/passive',
        '/norestart',
        '/L*v',
        log,
      ]);
      if (![0, 3010].contains(result.exitCode)) {
        throw StateError('Windows Installer 返回 ${result.exitCode}，安装日志：$log');
      }
      final updated = await UpdatePackageManifest.read(installation);
      if (releaseVersion(updated.version) !=
          releaseVersion(job['version'] as String)) {
        throw StateError('安装后的版本与下载版本不符。安装日志：$log');
      }
      return {'status': 'success', 'restartRequired': result.exitCode == 3010};
    }
    if (installed.kind == 'macos-app') {
      final replacement = await UpdatePackageManifest.read(payload!);
      return MacosBundleUpdater().install(
        installation,
        payload!,
        replacement,
        moveDirectory: moveDirectory,
        cancelled: () => File(p.join(work.path, 'abort')).exists(),
      );
    }
    return applyArchive();
  }

  Future<void> _validateMsi() async {
    final script = File(p.join(work.path, 'validate-msi.ps1'));
    await script.writeAsString(r'''
param([string]$PackagePath, [string]$ExpectedVersion)
$ErrorActionPreference = 'Stop'
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($PackagePath, 0)
function Read-Property([string]$Name) {
  $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$Name'")
  $view.Execute()
  $record = $view.Fetch()
  if ($null -eq $record) { throw "Missing MSI property $Name" }
  return $record.StringData(1)
}
if ((Read-Property 'UpgradeCode') -ne '{0A9CF9B8-3C51-4D96-9CB7-A306F0FE9806}') { throw 'MSI belongs to a different application.' }
if ((Read-Property 'ProductVersion') -ne $ExpectedVersion) { throw 'MSI version does not match the release tag.' }
''');
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-PackagePath',
      archive.path,
      '-ExpectedVersion',
      releaseVersion(job['version'] as String).toString(),
    ]).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) throw StateError('MSI 元数据校验失败：${result.stderr}');
  }

  Future<void> _move(Directory directory, String destination) async {
    if (moveDirectory != null) {
      await moveDirectory!(directory, destination);
    } else {
      await directory.rename(destination);
    }
  }

  Future<Map<String, dynamic>> applyArchive() async {
    final replacement = await UpdatePackageManifest.read(payload!);
    final stage = await installation.parent.createTemp('.take-a-look-new-');
    final backupSlot = await installation.parent.createTemp(
      '.take-a-look-backup-',
    );
    await backupSlot.delete();
    var movedOld = false;
    var movedNew = false;
    try {
      await _copyTree(payload!, stage);
      // Preserve every file not owned by the previous package: recordings,
      // projects, user configuration and other locally added files. Never
      // resurrect an obsolete DLL or Python module from the previous package.
      final owned = {...installed.files, updateManifestName};
      final newOwned = {...replacement.files, updateManifestName};
      await for (final entity in installation.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Directory) continue;
        final relative = p
            .relative(entity.path, from: installation.path)
            .replaceAll('\\', '/');
        if (owned.contains(relative)) continue;
        if (newOwned.contains(relative)) {
          throw StateError('新版程序文件与用户文件冲突：$relative');
        }
        final destination = p.join(stage.path, relative);
        await _assertNoLinkParent(stage, destination);
        if (await FileSystemEntity.type(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('更新文件与现有数据冲突：$relative');
        }
        await _copyEntity(entity, destination);
      }
      // Both directories are siblings on the same filesystem. Keep the entire
      // old installation until a later, explicit cleanup, even after success.
      await _move(installation, backupSlot.path);
      movedOld = true;
      await _move(stage, installation.path);
      movedNew = true;
      return {'status': 'success', 'backup': backupSlot.path};
    } catch (_) {
      if (movedOld && !movedNew) await _move(backupSlot, installation.path);
      rethrow;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static Future<void> _assertNoLinkParent(Directory root, String path) async {
    var parent = p.dirname(path);
    while (!p.equals(parent, root.path)) {
      if (!p.isWithin(root.path, parent) ||
          await FileSystemEntity.isLink(parent)) {
        throw const FormatException('更新数据路径穿过符号链接。');
      }
      parent = p.dirname(parent);
    }
  }

  static Future<void> _copyEntity(
    FileSystemEntity entity,
    String destination,
  ) async {
    await Directory(p.dirname(destination)).create(recursive: true);
    if (entity is Link) {
      await Link(destination).create(await entity.target());
    } else if (entity is File) {
      await entity.copy(destination);
    }
  }

  static Future<void> _copyTree(Directory from, Directory to) async {
    final links = <Link>[];
    final executables = <String>[];
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final destination = p.join(
        to.path,
        p.relative(entity.path, from: from.path),
      );
      if (entity is Link) {
        links.add(entity);
        continue;
      }
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else {
        await _copyEntity(entity, destination);
        if (Platform.isLinux && ((await entity.stat()).mode & 0x49) != 0) {
          executables.add(destination);
        }
      }
    }
    for (final link in links) {
      await _copyEntity(
        link,
        p.join(to.path, p.relative(link.path, from: from.path)),
      );
    }
    for (var i = 0; i < executables.length; i += 100) {
      final result = await Process.run('chmod', [
        '+x',
        '--',
        ...executables.skip(i).take(100),
      ]);
      if (result.exitCode != 0) throw StateError('无法设置新版程序的执行权限。');
    }
  }
}

Future<void> writeUpdateResult(
  Map<String, dynamic> job,
  Map<String, dynamic> result, {
  bool publish = true,
}) async {
  final contents = jsonEncode({
    ...result,
    'version': job['version'],
    'time': DateTime.now().toUtc().toIso8601String(),
  });
  for (final path in {
    job['result'] as String,
    if (publish && job['startupResult'] != null) job['startupResult'] as String,
  }) {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File('$path.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(path);
  }
}

Future<bool> updateParentIsAlive(int parentPid) async {
  if (Platform.isLinux) return Directory('/proc/$parentPid').exists();
  if (Platform.isMacOS) {
    final result = await Process.run('/bin/ps', [
      '-p',
      '$parentPid',
      '-o',
      'pid=',
    ]);
    if (result.exitCode == 1) return false;
    if (result.exitCode != 0) throw StateError('无法确认 Mac 主程序已退出。');
    return int.tryParse(result.stdout.toString().trim()) == parentPid;
  }
  final result = await Process.run('tasklist.exe', [
    '/FI',
    'PID eq $parentPid',
    '/NH',
    '/FO',
    'CSV',
  ]);
  if (result.exitCode != 0) throw StateError('无法确认主程序已退出。');
  return result.stdout.toString().contains('","$parentPid",');
}

Future<void> runUpdateHelper(File jobFile, {bool elevated = false}) async {
  final job = jsonDecode(await jobFile.readAsString()) as Map<String, dynamic>;
  final installer = UpdateInstaller(job);
  var committed = elevated;
  var parentExited = elevated;
  try {
    await installer.prepare();
    if (!elevated) {
      await File(
        p.join(installer.work.path, 'ready'),
      ).writeAsString('ready', flush: true);
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (!await File(p.join(installer.work.path, 'commit')).exists()) {
        if (await File(p.join(installer.work.path, 'abort')).exists() ||
            DateTime.now().isAfter(deadline)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      committed = true;
      while (await updateParentIsAlive(job['parentPid'] as int)) {
        if (await File(p.join(installer.work.path, 'abort')).exists()) return;
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('等待主程序退出超时，未替换文件。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      parentExited = true;
    }
    if (installer.needsElevation && !elevated) {
      final process = Platform.isMacOS
          ? await MacosBundleUpdater().authorize(
              Platform.resolvedExecutable,
              jobFile.path,
            )
          : await Process.run('pkexec', [
              Platform.resolvedExecutable,
              '--apply',
              jobFile.path,
            ]);
      if (process.exitCode != 0) {
        throw StateError('管理员授权或更新安装未完成：${process.stderr}');
      }
    } else {
      await writeUpdateResult(job, await installer.apply());
    }
  } catch (error, stack) {
    if (!elevated) {
      // A late administrator response must not install after restarting the
      // old app. The privileged worker checks this before swapping bundles.
      await File(
        p.join(installer.work.path, 'abort'),
      ).writeAsString('abort', flush: true);
    }
    await writeUpdateResult(job, {
      'status': 'failed',
      'message': error.toString(),
      'details': stack.toString(),
      'work': installer.work.path,
    }, publish: committed && parentExited);
    if (elevated) {
      exitCode = 1;
      return;
    }
  }
  if (committed && parentExited && !elevated) {
    try {
      final manifest = await UpdatePackageManifest.read(installer.installation);
      if (Platform.isMacOS) {
        await MacosBundleUpdater().relaunch(
          installer.installation,
          (job['restartArguments'] as List? ?? []).cast<String>(),
        );
      } else {
        await Process.start(
          p.join(installer.installation.path, manifest.executable),
          (job['restartArguments'] as List? ?? []).cast<String>(),
          workingDirectory: installer.installation.path,
          mode: ProcessStartMode.detached,
        );
      }
    } catch (error) {
      await writeUpdateResult(job, {
        'status': 'failed',
        'message': '安装后无法启动程序：$error',
        'work': installer.work.path,
      });
    }
  }
}
