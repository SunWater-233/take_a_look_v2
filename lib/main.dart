import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/panel_types.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final launch = detachedPanelLaunchFromEntrypointArguments(args);
  final panel = launch?.panel;

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      // A detached panel opens at the exact size it occupied in the workspace.
      // There is intentionally no fixed minimum or maximum so the OS can resize it.
      size: launch?.initialSize,
      backgroundColor: const Color(0xFF050505),
      title: panel == null
          ? 'Take A Look - Take A Look 调参上位机'
          : launch!.groupPanels.length > 1
          ? 'Take A Look - ${panel.title} 组合'
          : 'Take A Look - ${panel.title}',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    TakeALookApp(
      detachedPanel: panel,
      detachedPanels: launch?.groupPanels,
      enableBackend: panel == null,
    ),
  );
}
