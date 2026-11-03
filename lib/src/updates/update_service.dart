import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'update_models.dart';

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class UpdateService {
  UpdateService({Uri? latestUri, this.allowLocalhost = false})
    : latestUri =
          latestUri ??
          Uri.https(
            'api.github.com',
            '/repos/$updateRepository/releases/latest',
          );

  final Uri latestUri;
  final bool allowLocalhost;
  HttpClient? _downloadClient;
  bool _cancelled = false;

  Future<String> _text(Uri uri, {int limit = 1024 * 1024}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'Take-A-Look-Updater');
        final response = await request.close();
        if (response.statusCode == 404) throw const HttpException('not-found');
        if ([403, 429].contains(response.statusCode)) {
          throw const HttpException('GitHub 请求受限，请稍后重试。');
        }
        if (response.statusCode != 200) {
          throw HttpException('服务器返回 HTTP ${response.statusCode}。');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('服务器响应过大。');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }

  Future<GitHubRelease?> latest() async {
    try {
      final json = jsonDecode(await _text(latestUri)) as Map<String, dynamic>;
      if (json['draft'] == true || json['prerelease'] == true) return null;
      final release = GitHubRelease.fromJson(json);
      return releaseVersion(release.tag).isPreRelease ? null : release;
    } on HttpException catch (error) {
      if (error.message == 'not-found') return null;
      rethrow;
    }
  }

  void _validateAsset(ReleaseAsset asset) {
    final url = asset.url;
    final local =
        allowLocalhost && ['127.0.0.1', 'localhost'].contains(url.host);
    if ((!local &&
            (url.scheme != 'https' ||
                url.host != 'github.com' ||
                !url.path.startsWith(
                  '/$updateRepository/releases/download/',
                ))) ||
        !safePackagePath(asset.name) ||
        asset.name.contains('/') ||
        asset.size < 0) {
      throw const FormatException('更新文件地址无效。');
    }
  }

  Future<String> _checksum(GitHubRelease release, ReleaseAsset asset) async {
    final digest = asset.digest;
    if (digest != null &&
        RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
      return digest.substring(7).toLowerCase();
    }
    final matches = release.assets
        .where((item) => item.name == '${asset.name}.sha256')
        .toList();
    if (matches.length != 1) {
      throw const FormatException('此发布缺少 SHA-256 校验文件，无法自动安装。');
    }
    _validateAsset(matches.single);
    final text = (await _text(matches.single.url, limit: 4096)).trim();
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(text);
    if (match == null || match.group(2) != asset.name) {
      throw const FormatException('SHA-256 校验文件无效。');
    }
    return match.group(1)!.toLowerCase();
  }

  Future<({File file, String sha256})> download(
    GitHubRelease release,
    ReleaseAsset asset,
    Directory directory, {
    required void Function(int received, int total) onProgress,
  }) async {
    _validateAsset(asset);
    _cancelled = false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    _downloadClient = client;
    final partial = File(p.join(directory.path, '${asset.name}.part'));
    IOSink? sink;
    try {
      final expected = await _checksum(release, asset);
      if (_cancelled) throw const UpdateCancelled();
      await directory.create(recursive: true);
      final request = await client
          .getUrl(asset.url)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, 'Take-A-Look-Updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${response.statusCode}。');
      }
      if (response.contentLength >= 0 && response.contentLength != asset.size) {
        throw const FormatException('更新文件大小与发布信息不符。');
      }
      sink = partial.openWrite();
      // Observe asynchronous disk errors immediately, including while waiting
      // for the next network chunk. flush/close below still report the failure.
      unawaited(sink.done.catchError((Object _) {}));
      var received = 0;
      var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw const UpdateCancelled();
        received += chunk.length;
        if (received > asset.size) throw const FormatException('下载内容超过声明大小。');
        sink.add(chunk);
        // Backpressure prevents a fast download from retaining the entire
        // backend bundle in memory while a slow disk catches up.
        await sink.flush();
        final now = DateTime.now();
        if (now.difference(lastProgress).inMilliseconds >= 100) {
          onProgress(received, asset.size);
          lastProgress = now;
        }
      }
      await sink.close();
      sink = null;
      if (_cancelled) throw const UpdateCancelled();
      if (received != asset.size) throw const FormatException('更新文件下载不完整。');
      final actual = (await sha256.bind(partial.openRead()).first).toString();
      if (_cancelled) throw const UpdateCancelled();
      if (actual != expected) {
        throw const FormatException('SHA-256 校验失败，请重新下载。');
      }
      onProgress(received, asset.size);
      final file = await partial.rename(p.join(directory.path, asset.name));
      return (file: file, sha256: expected);
    } catch (_) {
      if (_cancelled) throw const UpdateCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      _downloadClient = null;
      try {
        await sink?.close();
      } catch (_) {}
      if (await partial.exists()) await partial.delete();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _downloadClient?.close(force: true);
  }
}
