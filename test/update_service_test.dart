import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:take_a_look_v2/src/updates/update_models.dart';
import 'package:take_a_look_v2/src/updates/update_service.dart';

void main() {
  for (final item in [
    ('v1.10.0', '1.9.0', true),
    ('v1.2.3+9', '1.2.3+1', false),
    ('1.2.3', '1.2.3-beta.2', true),
    ('1.2.2', '1.2.3', false),
  ]) {
    test('release comparison ${item.$1} > ${item.$2}', () {
      expect(releaseVersion(item.$1) > releaseVersion(item.$2), item.$3);
    });
  }

  test('select exactly the installed package kind and architecture', () {
    final release = GitHubRelease(
      tag: 'v1.2.3',
      name: '',
      notes: '',
      assets: [
        _asset('Take-A-Look-V2-1.2.3-windows-x64.msi'),
        _asset('Take-A-Look-V2-1.2.3+4-windows-x64-portable.zip'),
        _asset('take-a-look-v2-1.2.3+4-git.abcdef0-linux-x86_64.tar.gz'),
        _asset('take-a-look-v2-1.2.3-linux-aarch64.tar.gz'),
      ],
    );
    for (final kind in ['windows-msi', 'windows-portable', 'linux-archive']) {
      final installed = UpdatePackageManifest(
        kind: kind,
        version: '1.0.0',
        architecture: 'x64',
        files: {'app'},
      );
      expect(release.packageFor(installed), isNotNull);
      expect(
        release.packageFor(installed)!.name,
        contains(
          kind == 'windows-msi'
              ? '.msi'
              : kind == 'windows-portable'
              ? 'portable.zip'
              : 'x86_64.tar.gz',
        ),
      );
    }
    release.assets.add(
      _asset('Take-A-Look-V2-1.2.3+5-windows-x64-portable.zip'),
    );
    expect(
      release.packageFor(
        UpdatePackageManifest(
          kind: 'windows-portable',
          version: '1.0.0',
          architecture: 'x64',
          files: {'app'},
        ),
      ),
      isNull,
    );
  });

  for (final path in [
    '../outside',
    '/absolute',
    'C:/escape',
    'dir/../file',
    'dir\\file',
    'dir//file',
    'a\nfile',
  ]) {
    test(
      'reject unsafe package path $path',
      () => expect(safePackagePath(path), isFalse),
    );
  }

  test('latest handles no release, prereleases, and API failures', () async {
    var status = 404;
    Map<String, dynamic> response = {};
    final server = await _server((request) async {
      request.response.statusCode = status;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final service = UpdateService(latestUri: _url(server, '/latest'));
    expect(await service.latest(), isNull);
    status = 200;
    response = {
      'tag_name': 'v1.2.3',
      'name': '新版本',
      'body': '修复问题',
      'assets': [],
    };
    expect((await service.latest())!.notes, '修复问题');
    response['prerelease'] = true;
    expect(await service.latest(), isNull);
    response['prerelease'] = false;
    response['tag_name'] = 'v2.0.0-rc.1';
    expect(await service.latest(), isNull);
    response['tag_name'] = 'nightly';
    await expectLater(service.latest(), throwsFormatException);
    status = 429;
    await expectLater(service.latest(), throwsA(isA<HttpException>()));
  });

  test(
    'preview selection follows pagination and compares versions rather than list order',
    () async {
      final requests = <Uri>[];
      late HttpServer server;
      server = await _server((request) async {
        requests.add(request.uri);
        if (request.uri.queryParameters['page'] == '2') {
          request.response.write(
            jsonEncode([
              _releaseJson('v1.11.0-rc.10', prerelease: true),
              _releaseJson('v1.11.0-rc.2', prerelease: true),
              _releaseJson('v99.0.0', draft: true),
            ]),
          );
        } else {
          request.response.headers.set(
            'link',
            '<${_url(server, '/repositories/123/releases?page=2&per_page=100')}>; rel="next"',
          );
          request.response.write(
            jsonEncode([
              _releaseJson('v1.9.0'),
              _releaseJson('v1.10.0'),
              _releaseJson('nightly'),
              _releaseJson('v1.11.0-beta.9', prerelease: true),
            ]),
          );
        }
        await request.response.close();
      });
      final service = UpdateService(releasesUri: _url(server, '/releases'));
      final release = await service.latest(includePrereleases: true);
      expect(release!.tag, 'v1.11.0-rc.10');
      expect(release.isPrerelease, isTrue);
      expect(requests, hasLength(2));
      expect(requests.first.queryParameters['per_page'], '100');
    },
  );

  test(
    'preview channel includes flagged previews with stable tags; equal final versions win',
    () async {
      var rows = [
        _releaseJson('v2.0.0', prerelease: true),
        _releaseJson('v1.9.0'),
      ];
      final server = await _server((request) async {
        request.response.write(jsonEncode(rows));
        await request.response.close();
      });
      final service = UpdateService(releasesUri: _url(server, '/releases'));
      final preview = (await service.latest(includePrereleases: true))!;
      expect(preview.tag, 'v2.0.0');
      expect(preview.isPrerelease, isTrue);
      expect(GitHubRelease.fromJson(preview.toJson()).isPrerelease, isTrue);
      rows = [
        _releaseJson('v2.0.0-rc.9'),
        _releaseJson('v2.0.0', prerelease: true),
        _releaseJson('2.0.0'),
      ];
      final stable = (await service.latest(includePrereleases: true))!;
      expect(stable.tag, '2.0.0');
      expect(stable.isPrerelease, isFalse);
    },
  );

  test(
    'preview channel handles empty lists, no releases and rate limits',
    () async {
      var status = 200;
      final server = await _server((request) async {
        request.response.statusCode = status;
        request.response.write('[]');
        await request.response.close();
      });
      final service = UpdateService(releasesUri: _url(server, '/releases'));
      expect(await service.latest(includePrereleases: true), isNull);
      status = 404;
      expect(await service.latest(includePrereleases: true), isNull);
      status = 429;
      await expectLater(
        service.latest(includePrereleases: true),
        throwsA(isA<HttpException>()),
      );
    },
  );

  test('preview pagination refuses cycles and foreign hosts', () async {
    var foreign = false;
    late HttpServer server;
    server = await _server((request) async {
      request.response.headers.set(
        'link',
        '<${foreign ? 'https://evil.example/releases' : _url(server, request.uri.toString())}>; rel="next"',
      );
      request.response.write('[]');
      await request.response.close();
    });
    final service = UpdateService(releasesUri: _url(server, '/releases'));
    await expectLater(
      service.latest(includePrereleases: true),
      throwsA(isA<HttpException>()),
    );
    foreign = true;
    await expectLater(
      service.latest(includePrereleases: true),
      throwsFormatException,
    );
  });

  for (final useCompanion in [false, true]) {
    // Checksum handling is identical for stable and preview release assets.
    test(
      'download streams and verifies ${useCompanion ? 'companion' : 'API digest'} checksum',
      () async {
        final content = utf8.encode('完整安装包内容' * 2000);
        final hash = sha256.convert(content).toString();
        final folder = _temporary();
        final server = await _server((request) async {
          if (request.uri.path.endsWith('.sha256')) {
            request.response.write('$hash  package.zip\n');
          } else {
            request.response.contentLength = content.length;
            request.response.add(content);
          }
          await request.response.close();
        });
        final asset = ReleaseAsset(
          name: 'package.zip',
          url: _url(server, '/package.zip'),
          size: content.length,
          digest: useCompanion ? null : 'sha256:$hash',
        );
        final release = GitHubRelease(
          tag: 'v1.2.3',
          name: '',
          notes: '',
          assets: [
            asset,
            ReleaseAsset(
              name: 'package.zip.sha256',
              url: _url(server, '/package.zip.sha256'),
              size: 100,
            ),
          ],
        );
        var progress = 0;
        final result = await UpdateService(allowLocalhost: true).download(
          release,
          asset,
          folder,
          onProgress: (received, _) => progress = received,
        );
        expect(result.sha256, hash);
        expect(await result.file.readAsBytes(), content);
        expect(progress, content.length);
        expect(
          await File(p.join(folder.path, 'package.zip.part')).exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'checksum mismatch and cancellation never leave a partial package',
    () async {
      final content = List.filled(256 * 1024, 42);
      final folder = _temporary();
      final server = await _server((request) async {
        request.response.contentLength = content.length;
        request.response.add(content);
        await request.response.close();
      });
      final asset = ReleaseAsset(
        name: 'package.zip',
        url: _url(server, '/package.zip'),
        size: content.length,
        digest: 'sha256:${'0' * 64}',
      );
      final release = GitHubRelease(
        tag: '1.2.3',
        name: '',
        notes: '',
        assets: [asset],
      );
      final service = UpdateService(allowLocalhost: true);
      await expectLater(
        service.download(release, asset, folder, onProgress: (_, _) {}),
        throwsFormatException,
      );
      expect(await folder.list().toList(), isEmpty);
      await expectLater(
        service.download(
          release,
          asset,
          folder,
          onProgress: (_, _) => service.cancelDownload(),
        ),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(await folder.list().toList(), isEmpty);
    },
  );

  test('missing checksum and foreign asset URLs cannot be installed', () async {
    final asset = ReleaseAsset(
      name: 'package.zip',
      url: Uri.parse(
        'https://github.com/$updateRepository/releases/download/v1.2.3/package.zip',
      ),
      size: 10,
    );
    final release = GitHubRelease(
      tag: '1.2.3',
      name: '',
      notes: '',
      assets: [asset],
    );
    await expectLater(
      UpdateService().download(
        release,
        asset,
        _temporary(),
        onProgress: (_, _) {},
      ),
      throwsFormatException,
    );
    final foreign = ReleaseAsset(
      name: 'package.zip',
      url: Uri.parse('https://evil.example/package.zip'),
      size: 10,
      digest: 'sha256:${'0' * 64}',
    );
    await expectLater(
      UpdateService().download(
        release,
        foreign,
        _temporary(),
        onProgress: (_, _) {},
      ),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _releaseJson(
  String tag, {
  bool prerelease = false,
  bool draft = false,
}) => {
  'tag_name': tag,
  'name': tag,
  'body': '',
  'assets': [],
  'prerelease': prerelease,
  'draft': draft,
};

ReleaseAsset _asset(String name) => ReleaseAsset(
  name: name,
  url: Uri.parse(
    'https://github.com/$updateRepository/releases/download/v1.2.3/$name',
  ),
  size: 100,
);

Directory _temporary() {
  final directory = Directory.systemTemp.createTempSync('tal-update-service-');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

Future<HttpServer> _server(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) => unawaited(handler(request)));
  addTearDown(() => server.close(force: true));
  return server;
}

Uri _url(HttpServer server, String path) =>
    Uri.parse('http://127.0.0.1:${server.port}$path');
