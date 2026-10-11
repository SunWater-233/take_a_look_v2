import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../workspace/panel_types.dart';

export '../workspace/panel_types.dart';

/// Shared native-window startup for the production and UI test entrypoints.
Future<void> launchWorkbench(
  List<String> args, {
  required Widget Function(DetachedPanelLaunch? launch) appBuilder,
  String title = 'Take A Look - Take A Look 调参上位机',
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final launch = detachedPanelLaunchFromEntrypointArguments(args);
  final panel = launch?.panel;
  Completer<void>? firstFrameReady;

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    firstFrameReady = Completer<void>();
    final options = WindowOptions(
      // Detached panels retain their workspace size without a fixed minimum.
      size: launch?.initialSize,
      backgroundColor: const Color(0xFF050505),
      title: panel == null
          ? title
          : launch?.role == SecondaryWindowRole.dragPreview
          ? '$title - 拖动预览'
          : launch!.groupPanels.length > 1
          ? '$title - ${panel.title} 组合'
          : '$title - ${panel.title}',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await firstFrameReady!.future;
        // Secondary engines remain hidden until the main window assigns them.
        if (panel == null) {
          await windowManager.show();
          await windowManager.focus();
        }
      }),
    );
  }

  final frameReady = firstFrameReady;
  if (frameReady != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!frameReady.isCompleted) frameReady.complete();
    });
  }
  runApp(appBuilder(launch));
}
