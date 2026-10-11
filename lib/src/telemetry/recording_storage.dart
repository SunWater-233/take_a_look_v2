import 'dart:io';

import 'raw_recording.dart';

/// Startup housekeeping for the portable recording directory. Only file
/// metadata is read; journal contents and active acquisition are untouched.
class RecordingStorage {
  RecordingStorage({Directory? directory})
    : directory = directory ?? RawSampleRecording.defaultDirectory;

  // Match the MB units used by the Windows file manager.
  static const bytesPerMb = 1024 * 1024;
  static const warningThresholdBytes = 500 * bytesPerMb;

  final Directory directory;

  Future<int> totalBytes() async {
    var bytes = 0;
    final pending = <Directory>[directory];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!await current.exists()) continue;
      try {
        await for (final entry in current.list(followLinks: false)) {
          if (entry is Directory) {
            pending.add(entry);
          } else if (entry is File) {
            final stat = await entry.stat();
            // A user may delete a record while the startup scan is running.
            if (stat.type == FileSystemEntityType.file) bytes += stat.size;
          }
        }
      } on FileSystemException {
        if (await current.exists()) rethrow;
      }
    }
    return bytes;
  }

  Future<void> openDirectory() async {
    await directory.create(recursive: true);
    final path = directory.absolute.uri.toFilePath();
    if (Platform.isWindows) {
      // Explorer can hand off to an existing process. Starting it successfully
      // is the signal; its exit code is not a folder-open result.
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
    } else {
      final result = await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [
        path,
      ]);
      if (result.exitCode != 0) {
        throw FileSystemException('无法打开记录文件夹：${result.stderr}', path);
      }
    }
  }
}
