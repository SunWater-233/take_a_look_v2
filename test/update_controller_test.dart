import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/updates/update_controller.dart';
import 'package:take_a_look_v2/src/updates/update_models.dart';
import 'package:take_a_look_v2/src/updates/update_service.dart';

void main() {
  test(
    'automatic preference and 24 hour throttle survive restarts; manual bypasses them',
    () async {
      final folder = _temporary();
      final prefs = File('${folder.path}/updates.json');
      var now = DateTime.utc(2026, 11, 4);
      final service = FakeUpdateService();
      final first = _controller(folder, prefs, service, () => now);
      await first.initialize(automatic: true);
      expect(service.requests, 1);
      expect(first.hasUpdate, isTrue);
      await first.ignoreVersion();
      expect(first.shouldNotify, isFalse);
      first.dispose();
      final second = _controller(folder, prefs, service, () => now);
      await second.initialize(automatic: true);
      expect(service.requests, 1);
      expect(second.ignoredTag, 'v1.10.0');
      expect(second.hasUpdate, isTrue);
      now = now.add(const Duration(hours: 25));
      await second.check(automatic: true);
      expect(service.requests, 2);
      await second.setAutoCheck(false);
      second.dispose();
      final third = _controller(folder, prefs, service, () => now);
      await third.initialize(automatic: true);
      expect(third.autoCheck, isFalse);
      expect(service.requests, 2);
      await third.check();
      expect(service.requests, 3);
      third.dispose();
    },
  );

  test(
    'duplicate checks share one request, failure is retryable, disposal is safe',
    () async {
      final folder = _temporary();
      final pending = Completer<GitHubRelease?>();
      final service = FakeUpdateService()..pending = pending.future;
      final controller = _controller(
        folder,
        File('${folder.path}/prefs'),
        service,
        DateTime.now,
      );
      await controller.initialize();
      final first = controller.check();
      final second = controller.check();
      await Future<void>.delayed(Duration.zero);
      expect(service.requests, 1);
      pending.completeError(const SocketException('offline'));
      await Future.wait([first, second]);
      expect(controller.error, contains('检查更新失败'));
      service.pending = null;
      await controller.check();
      expect(controller.error, isNull);
      expect(controller.hasUpdate, isTrue);
      controller.dispose();
    },
  );

  test(
    'preview preference survives restart and switching invalidates cache and downloaded candidates',
    () async {
      final folder = _temporary();
      final prefs = File('${folder.path}/prefs');
      final service = FakeUpdateService()
        ..preview = GitHubRelease(
          tag: 'v1.11.0-beta.1',
          name: '',
          notes: '',
          assets: [],
        );
      var controller = _controller(folder, prefs, service, DateTime.now);
      await controller.initialize();
      expect(controller.includePrereleases, isFalse);
      await controller.setAutoCheck(false);
      await controller.check();
      await controller.setIncludePrereleases(true);
      expect(service.channels, [false, true]);
      expect(controller.release!.tag, 'v1.11.0-beta.1');
      expect(controller.shouldNotify, isTrue);
      expect(
        jsonDecode(prefs.readAsStringSync())['includePrereleases'],
        isTrue,
      );
      controller.dispose();
      controller = _controller(folder, prefs, service, DateTime.now);
      await controller.initialize();
      expect(controller.includePrereleases, isTrue);
      expect(controller.release!.isPrerelease, isTrue);
      controller.transfer = UpdateTransfer.ready;
      controller.downloadedFile = File('${folder.path}/preview.zip');
      controller.downloadedHash = 'old hash';
      await controller.setIncludePrereleases(false);
      expect(service.channels, [false, true, false]);
      expect(controller.release!.tag, 'v1.10.0');
      expect(controller.transfer, UpdateTransfer.idle);
      expect(controller.downloadedFile, isNull);
      expect(controller.downloadedHash, isNull);
      expect(controller.autoCheck, isFalse);
      controller.dispose();
    },
  );

  test(
    'stable channel discards cached GitHub-flagged previews and clears their throttle',
    () async {
      final folder = _temporary();
      final prefs = File('${folder.path}/prefs');
      final preview = GitHubRelease(
        tag: 'v1.11.0',
        name: '',
        notes: '',
        assets: [],
        prerelease: true,
      );
      prefs.writeAsStringSync(
        jsonEncode({
          'autoCheck': true,
          'includePrereleases': false,
          'lastAttempt': DateTime.now().toUtc().toIso8601String(),
          'release': preview.toJson(),
        }),
      );
      final service = FakeUpdateService();
      final controller = _controller(folder, prefs, service, DateTime.now);
      await controller.initialize(automatic: true);
      expect(service.channels, [false]);
      expect(controller.release!.tag, 'v1.10.0');
      controller.dispose();
    },
  );

  test(
    'preview preference cannot change during a request and rolls back on save failure',
    () async {
      final folder = _temporary();
      File('${folder.path}/blocked').writeAsStringSync('file, not a directory');
      final service = FakeUpdateService();
      final controller = _controller(
        folder,
        File('${folder.path}/blocked/prefs'),
        service,
        DateTime.now,
      );
      await controller.initialize();
      await controller.setIncludePrereleases(true);
      expect(controller.includePrereleases, isFalse);
      expect(controller.error, contains('无法保存预览版更新设置'));
      expect(service.requests, 0);
      controller.transfer = UpdateTransfer.downloading;
      await controller.setIncludePrereleases(true);
      expect(controller.includePrereleases, isFalse);
      controller.dispose();
    },
  );

  test('missing helper does not invoke shutdown or quit', () async {
    final folder = _temporary();
    final controller = _controller(
      folder,
      File('${folder.path}/prefs'),
      FakeUpdateService(),
      DateTime.now,
    );
    await controller.initialize();
    controller.package = UpdatePackageManifest(
      kind: 'windows-portable',
      version: '1.9.0',
      architecture: 'x64',
      files: {'app'},
    );
    controller.work = Directory('${folder.path}/work')..createSync();
    controller.transfer = UpdateTransfer.ready;
    var shutdown = false;
    var quit = false;
    await controller.install(
      beforeExit: () async {
        shutdown = true;
      },
      quit: () => quit = true,
    );
    expect(shutdown, isFalse);
    expect(quit, isFalse);
    expect(controller.transfer, UpdateTransfer.ready);
    expect(controller.error, contains('缺少独立更新程序'));
    final attempt = controller.work!.listSync().whereType<Directory>().single;
    expect(File('${attempt.path}/abort').existsSync(), isTrue);
    await controller.install(
      beforeExit: () async {
        shutdown = true;
      },
      quit: () => quit = true,
    );
    final attempts = controller.work!
        .listSync()
        .whereType<Directory>()
        .toList();
    expect(attempts, hasLength(2));
    expect(
      attempts.every(
        (directory) => File('${directory.path}/abort').existsSync(),
      ),
      isTrue,
    );
    expect(shutdown, isFalse);
    expect(quit, isFalse);
    controller.dispose();
  });

  test('damaged preferences do not prevent manual checking', () async {
    final folder = _temporary();
    final prefs = File('${folder.path}/prefs')..writeAsStringSync('bad JSON');
    final controller = _controller(
      folder,
      prefs,
      FakeUpdateService(),
      DateTime.now,
    );
    await controller.initialize();
    expect(controller.initialized, isTrue);
    await controller.check();
    expect(controller.hasUpdate, isTrue);
    expect(jsonDecode(prefs.readAsStringSync())['autoCheck'], isTrue);
    controller.dispose();
  });

  test(
    'unreadable installed version never reports an update or crashes comparison',
    () async {
      final folder = _temporary();
      final controller = AppUpdateController(
        service: FakeUpdateService(),
        preferencesFile: File('${folder.path}/prefs'),
        installation: folder,
        readVersion: () async => 'unknown',
      );
      await controller.initialize();
      await controller.check();
      expect(controller.currentVersion, isEmpty);
      expect(controller.hasUpdate, isFalse);
      expect(controller.asset, isNull);
      controller.dispose();
    },
  );
}

class FakeUpdateService extends UpdateService {
  int requests = 0;
  final channels = <bool>[];
  GitHubRelease? preview;
  Future<GitHubRelease?>? pending;
  @override
  Future<GitHubRelease?> latest({bool includePrereleases = false}) async {
    requests++;
    channels.add(includePrereleases);
    if (includePrereleases && preview != null) return preview;
    return pending ??
        GitHubRelease(tag: 'v1.10.0', name: '新版', notes: '更新说明', assets: []);
  }
}

AppUpdateController _controller(
  Directory root,
  File prefs,
  UpdateService service,
  DateTime Function() now,
) => AppUpdateController(
  service: service,
  preferencesFile: prefs,
  installation: root,
  readVersion: () async => '1.9.0+5',
  now: now,
);

Directory _temporary() {
  final directory = Directory.systemTemp.createTempSync(
    'tal-update-controller-',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}
