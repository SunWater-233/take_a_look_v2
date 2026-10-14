import 'dart:async';
import 'dart:io';

import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';

// Automatic startup restoration must never read or overwrite a developer's
// saved layout. Explicit layoutFile fixtures still use their own files.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final directory = Directory.systemTemp.createTempSync('tal_test_settings_');
  final overrides = _LayoutFileOverrides(
    WorkspaceLayoutRepository.defaultFile().path,
    '${directory.path}/layout.json',
  );
  try {
    await IOOverrides.runWithIOOverrides(testMain, overrides);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

final class _LayoutFileOverrides extends IOOverrides {
  _LayoutFileOverrides(this.defaultPath, this.testPath);

  final String defaultPath;
  final String testPath;

  @override
  File createFile(String path) =>
      super.createFile(path == defaultPath ? testPath : path);
}
