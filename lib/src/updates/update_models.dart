import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const updateManifestName = 'UPDATE-MANIFEST.json';
const updateHelperName = 'take_a_look_updater';
const macosBundleIdentifier = 'com.example.takeALookV2';
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
    if (![
          'windows-msi',
          'windows-portable',
          'linux-archive',
          'macos-app',
        ].contains(kind) ||
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
  String get executable => switch (kind) {
    'macos-app' => 'Contents/MacOS/take_a_look_v2',
    'linux-archive' => 'take-a-look',
    _ => 'take_a_look_v2.exe',
  };
  String get helper => kind == 'macos-app'
      ? 'Contents/Helpers/$updateHelperName'
      : '$updateHelperName${kind.startsWith('windows-') ? '.exe' : ''}';
  String get manifestPath => kind == 'macos-app'
      ? 'Contents/Resources/$updateManifestName'
      : updateManifestName;

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

  static Future<UpdatePackageManifest> read(Directory root) async {
    final bundleManifest = File(
      p.join(root.path, 'Contents', 'Resources', updateManifestName),
    );
    final file = await bundleManifest.exists()
        ? bundleManifest
        : File(p.join(root.path, updateManifestName));
    return UpdatePackageManifest.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }
}

/// macOS runs an executable inside Contents/MacOS; upgrades replace the .app.
String updateInstallationPath(String executable, {required bool macos}) {
  if (macos) {
    final paths = p.posix;
    final directory = paths.dirname(executable);
    final contents = paths.dirname(directory);
    final bundle = paths.dirname(contents);
    if (paths.basename(directory) == 'MacOS' &&
        paths.basename(contents) == 'Contents' &&
        bundle.endsWith('.app')) {
      return bundle;
    }
  }
  return p.dirname(executable);
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
      'macos-app' => RegExp(
        '^Take-A-Look-V2-${RegExp.escape(version)}(?:\\+[0-9]+)?-macos-$architecture\\.zip\$',
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
