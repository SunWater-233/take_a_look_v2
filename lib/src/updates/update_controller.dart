import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../workspace/workspace_layout.dart';
import 'update_models.dart';
import 'update_service.dart';

enum UpdateTransfer { idle, downloading, ready, installing }

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    UpdateService? service,
    File? preferencesFile,
    Directory? installation,
    Future<String> Function()? readVersion,
    DateTime Function()? now,
  }) : service = service ?? UpdateService(),
       preferencesFile =
           preferencesFile ??
           File(
             p.join(
               WorkspaceLayoutRepository.defaultFile().parent.path,
               'updates.json',
             ),
           ),
       installation = installation ?? File(Platform.resolvedExecutable).parent,
       _readVersion = readVersion ?? _platformVersion,
       _now = now ?? DateTime.now;

  final UpdateService service;
  final File preferencesFile;
  final Directory installation;
  final Future<String> Function() _readVersion;
  final DateTime Function() _now;
  Future<void>? _initialization;
  Future<void>? _checking;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  bool initialized = false;
  bool autoCheck = true;
  bool includePrereleases = false;
  bool dialogOpen = false;
  String currentVersion = '';
  String? ignoredTag;
  DateTime? lastAttempt;
  GitHubRelease? release;
  UpdatePackageManifest? package;
  String? error;
  String? lastUpdateMessage;
  bool lastUpdateFailed = false;
  bool checked = false;
  UpdateTransfer transfer = UpdateTransfer.idle;
  int receivedBytes = 0;
  int totalBytes = 0;
  File? downloadedFile;
  String? downloadedHash;
  Directory? work;

  File get resultFile =>
      File(p.join(preferencesFile.parent.path, 'update-result.json'));
  bool get checking => _checking != null;
  bool get busy =>
      checking ||
      transfer == UpdateTransfer.downloading ||
      transfer == UpdateTransfer.installing;
  bool get hasUpdate =>
      currentVersion.isNotEmpty &&
      release != null &&
      (includePrereleases || !release!.isPrerelease) &&
      releaseVersion(release!.tag) > releaseVersion(currentVersion);
  bool get shouldNotify =>
      !dialogOpen && hasUpdate && ignoredTag != release!.tag;
  ReleaseAsset? get asset =>
      package == null || !hasUpdate ? null : release!.packageFor(package!);

  static Future<String> _platformVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}${info.buildNumber.isEmpty ? '' : '+${info.buildNumber}'}';
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void reportError(String message) {
    error = message;
    _changed();
  }

  Future<void> initialize({bool automatic = false}) async {
    await (_initialization ??= _load());
    if (automatic && !_disposed) await check(automatic: true);
  }

  Future<void> _load() async {
    try {
      final version = await _readVersion();
      releaseVersion(version);
      currentVersion = version;
      if (await preferencesFile.exists()) {
        final json =
            jsonDecode(await preferencesFile.readAsString())
                as Map<String, dynamic>;
        autoCheck = json['autoCheck'] as bool? ?? true;
        includePrereleases = json['includePrereleases'] as bool? ?? false;
        ignoredTag = json['ignoredTag'] as String?;
        lastAttempt = DateTime.tryParse(json['lastAttempt'] as String? ?? '');
        if (json['release'] != null) {
          release = GitHubRelease.fromJson(
            Map<String, dynamic>.from(json['release'] as Map),
          );
          if (!includePrereleases && release!.isPrerelease) {
            release = null;
            lastAttempt = null;
          }
        }
      }
    } catch (failure) {
      error = '读取更新设置或当前版本失败：$failure';
    }
    try {
      package = await UpdatePackageManifest.read(installation);
      // Build metadata can differ in MSI; the three-part release must agree.
      if (currentVersion.isEmpty ||
          releaseVersion(package!.version) != releaseVersion(currentVersion)) {
        package = null;
      }
    } catch (_) {
      package = null;
    }
    try {
      if (await resultFile.exists()) {
        final json =
            jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
        lastUpdateFailed = json['status'] != 'success';
        lastUpdateMessage = lastUpdateFailed
            ? '上次更新未完成：${json['message']}'
            : '已更新到 ${json['version']}。${json['backup'] == null ? '' : '\n旧版本备份：${json['backup']}'}${json['restartRequired'] == true ? '\nWindows 提示需要重启系统以完成部分文件替换。' : ''}';
        if (lastUpdateFailed) error = lastUpdateMessage;
      }
    } catch (_) {
      /* A damaged result never prevents starting the workbench. */
    }
    initialized = true;
    _changed();
  }

  Future<void> _persist() {
    final contents = jsonEncode({
      'autoCheck': autoCheck,
      'includePrereleases': includePrereleases,
      'ignoredTag': ignoredTag,
      'lastAttempt': lastAttempt?.toUtc().toIso8601String(),
      'release': release?.toJson(),
    });
    _writes = _writes.catchError((Object _) {}).then((_) async {
      await preferencesFile.parent.create(recursive: true);
      final temporary = File('${preferencesFile.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(preferencesFile.path);
    });
    return _writes;
  }

  Future<void> setAutoCheck(bool value) async {
    await initialize();
    final previous = autoCheck;
    autoCheck = value;
    _changed();
    try {
      await _persist();
    } catch (failure) {
      autoCheck = previous;
      error = '无法保存自动检测设置：$failure';
      _changed();
    }
  }

  Future<void> ignoreVersion() async {
    ignoredTag = release?.tag;
    try {
      await _persist();
    } catch (failure) {
      error = '无法保存忽略版本设置：$failure';
    }
    _changed();
  }

  Future<void> setIncludePrereleases(bool value) async {
    await initialize();
    if (_disposed || busy || value == includePrereleases) return;
    final previous = (
      include: includePrereleases,
      release: release,
      attempt: lastAttempt,
      checked: checked,
      transfer: transfer,
      file: downloadedFile,
      hash: downloadedHash,
      received: receivedBytes,
      total: totalBytes,
    );
    includePrereleases = value;
    release = null;
    lastAttempt = null;
    checked = false;
    transfer = UpdateTransfer.idle;
    downloadedFile = null;
    downloadedHash = null;
    receivedBytes = totalBytes = 0;
    error = null;
    _changed();
    try {
      await _persist();
    } catch (failure) {
      includePrereleases = previous.include;
      release = previous.release;
      lastAttempt = previous.attempt;
      checked = previous.checked;
      transfer = previous.transfer;
      downloadedFile = previous.file;
      downloadedHash = previous.hash;
      receivedBytes = previous.received;
      totalBytes = previous.total;
      error = '无法保存预览版更新设置：$failure';
      _changed();
      return;
    }
    // Changing channels is an explicit check, independent of the startup switch
    // and its 24-hour interval. Previously downloaded candidates are invalidated.
    await check();
  }

  Future<void> check({bool automatic = false}) async {
    await initialize();
    if (_disposed || transfer != UpdateTransfer.idle) return;
    if (_checking != null) return _checking;
    if (automatic &&
        (!autoCheck ||
            (lastAttempt != null &&
                _now().difference(lastAttempt!).inHours < 24 &&
                !_now().isBefore(lastAttempt!)))) {
      return;
    }
    final completion = Completer<void>();
    _checking = completion.future;
    _changed();
    try {
      error = null;
      lastAttempt = _now();
      release = await service.latest(includePrereleases: includePrereleases);
      checked = true;
      await _persist();
    } catch (failure) {
      error = '检查更新失败，请检查网络后重试。\n$failure';
      // Throttle failed startup attempts too, without suppressing manual retry.
      try {
        await _persist();
      } catch (_) {}
    } finally {
      _checking = null;
      completion.complete();
      _changed();
    }
  }

  Future<void> download() async {
    if (busy || asset == null || !hasUpdate || _disposed) return;
    transfer = UpdateTransfer.downloading;
    error = null;
    receivedBytes = 0;
    totalBytes = asset!.size;
    _changed();
    try {
      work ??= await Directory.systemTemp.createTemp('take-a-look-update-');
      final downloaded = await service.download(
        release!,
        asset!,
        work!,
        onProgress: (received, total) {
          receivedBytes = received;
          totalBytes = total;
          _changed();
        },
      );
      downloadedFile = downloaded.file;
      downloadedHash = downloaded.sha256;
      transfer = UpdateTransfer.ready;
    } on UpdateCancelled {
      transfer = UpdateTransfer.idle;
    } catch (failure) {
      transfer = UpdateTransfer.idle;
      error = '下载更新失败：$failure';
    }
    _changed();
  }

  void cancelDownload() => service.cancelDownload();

  /// Prepare and acknowledge the external helper before closing the backend.
  /// A separate commit file prevents an abandoned helper from applying an
  /// update merely because the app is closed at a later time.
  Future<void> install({
    required Future<void> Function() beforeExit,
    required void Function() quit,
    List<String> restartArguments = const [],
  }) async {
    if (transfer != UpdateTransfer.ready || package == null || work == null) {
      return;
    }
    transfer = UpdateTransfer.installing;
    error = null;
    _changed();
    Directory? attempt;
    try {
      // Each retry has its own handshake. An older, slow helper can never
      // consume a newer attempt's commit file after its own abort was written.
      attempt = await work!.createTemp('install-');
      final ready = File(p.join(attempt.path, 'ready'));
      final commit = File(p.join(attempt.path, 'commit'));
      final attemptResult = File(p.join(attempt.path, 'result.json'));
      final helper = File(p.join(installation.path, package!.helper));
      if (!await helper.exists()) throw StateError('安装包缺少独立更新程序，请重新安装完整发布包。');
      final executable = await helper.copy(
        p.join(attempt.path, package!.helper),
      );
      final job = File(p.join(attempt.path, 'job.json'));
      await job.writeAsString(
        jsonEncode({
          'work': attempt.absolute.path,
          'installation': installation.absolute.path,
          'archive': downloadedFile!.absolute.path,
          'sha256': downloadedHash,
          'version': release!.tag,
          'parentPid': pid,
          'result': attemptResult.absolute.path,
          'startupResult': resultFile.absolute.path,
          'restartArguments': restartArguments,
        }),
        flush: true,
      );
      await Process.start(
        executable.path,
        ['--job', job.path],
        workingDirectory: attempt.path,
        mode: ProcessStartMode.detached,
      );
      final elapsed = Stopwatch()..start();
      while (!await ready.exists()) {
        if (await attemptResult.exists()) {
          final result = jsonDecode(await attemptResult.readAsString()) as Map;
          throw StateError(result['message'].toString());
        }
        if (_disposed || elapsed.elapsed > const Duration(minutes: 2)) {
          throw StateError('更新程序准备超时。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await beforeExit();
      await commit.writeAsString('apply', flush: true);
      quit();
    } catch (failure) {
      if (attempt != null) {
        try {
          await File(
            p.join(attempt.path, 'abort'),
          ).writeAsString('abort', flush: true);
        } catch (_) {}
      }
      transfer = UpdateTransfer.ready;
      error = '准备安装失败：$failure';
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    service.cancelDownload();
    super.dispose();
  }
}
