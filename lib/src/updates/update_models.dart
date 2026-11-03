import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const updateManifestName = 'UPDATE-MANIFEST.json';
const updateHelperName = 'take_a_look_updater';
const updateRepository = String.fromEnvironment(
  'TAL_UPDATE_REPOSITORY',
  defaultValue: 'SunWater-233/take_a_look_v2',
);

Version releaseVersion(String value) {
  final text = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
  // Flutter build numbers describe a build of the same release, not an upgrade.
  final version = Version.parse(text);
  return Version.parse(version.toString().split('+').first);
}

bool safePackagePath(String value) =>
    value.isNotEmpty &&
    !value.contains(RegExp(r'[\\:\x00-\x1f]')) &&
    !p.posix.isAbsolute(value) &&
    !value
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..');

class UpdatePackageManifest {
  UpdatePackageManifest({
    required this.kind,
    required this.version,
    required this.architecture,
    required this.files,
  }) {
    if (!['windows-msi', 'windows-portable', 'linux-archive'].contains(kind) ||
        !['x64', 'arm64'].contains(architecture) ||
        files.isEmpty ||
        files.any((file) => !safePackagePath(file))) {
      throw const FormatException('更新包清单无效。');
    }
    releaseVersion(version);
  }

  final String kind;
  final String version;
  final String architecture;
  final Set<String> files;
  String get executable =>
      kind.startsWith('windows-') ? 'take_a_look_v2.exe' : 'take-a-look';
  String get helper =>
      '$updateHelperName${kind.startsWith('windows-') ? '.exe' : ''}';

  factory UpdatePackageManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) throw const FormatException('不支持的更新包清单。');
    return UpdatePackageManifest(
      kind: json['kind'] as String,
      version: json['version'] as String,
      architecture: json['architecture'] as String,
      files: (json['files'] as List).cast<String>().toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'kind': kind,
    'version': version,
    'architecture': architecture,
    'files': files.toList()..sort(),
  };

  static Future<UpdatePackageManifest> read(Directory root) async =>
      UpdatePackageManifest.fromJson(
        jsonDecode(
              await File(p.join(root.path, updateManifestName)).readAsString(),
            )
            as Map<String, dynamic>,
      );
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.digest,
  });
  final String name;
  final Uri url;
  final int size;
  final String? digest;

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) => ReleaseAsset(
    name: json['name'] as String,
    url: Uri.parse(json['browser_download_url'] as String),
    size: json['size'] as int,
    digest: json['digest'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'browser_download_url': url.toString(),
    'size': size,
    'digest': digest,
  };
}

class GitHubRelease {
  GitHubRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.assets,
  }) {
    releaseVersion(tag);
  }
  final String tag;
  final String name;
  final String notes;
  final List<ReleaseAsset> assets;
  Uri get page =>
      Uri.https('github.com', '/$updateRepository/releases/tag/$tag');

  factory GitHubRelease.fromJson(Map<String, dynamic> json) => GitHubRelease(
    tag: json['tag_name'] as String,
    name: (json['name'] as String?)?.trim() ?? '',
    notes: json['body'] as String? ?? '',
    assets: (json['assets'] as List? ?? [])
        .map(
          (item) =>
              ReleaseAsset.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'tag_name': tag,
    'name': name,
    'body': notes,
    'assets': assets.map((asset) => asset.toJson()).toList(),
  };

  ReleaseAsset? packageFor(UpdatePackageManifest installed) {
    final version = releaseVersion(tag).toString();
    final architecture = installed.architecture;
    final pattern = switch (installed.kind) {
      'windows-msi' => RegExp(
        '^Take-A-Look-V2-${RegExp.escape(version)}-windows-$architecture\\.msi\$',
        caseSensitive: false,
      ),
      'windows-portable' => RegExp(
        '^Take-A-Look-V2-${RegExp.escape(version)}(?:\\+[0-9]+)?-windows-$architecture-portable\\.zip\$',
        caseSensitive: false,
      ),
      _ => RegExp(
        '^take-a-look-v2-${RegExp.escape(version)}(?:\\+[0-9]+)?(?:-git\\.[0-9a-f]+)?-linux-${architecture == 'x64' ? 'x86_64' : 'aarch64'}\\.tar\\.gz\$',
        caseSensitive: false,
      ),
    };
    final matches = assets
        .where((asset) => pattern.hasMatch(asset.name))
        .toList();
    // Ambiguous releases require the publisher to fix the assets.
    return matches.length == 1 ? matches.single : null;
  }
}
