import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/app.dart';
import 'src/workspace/panel_types.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final launch = detachedPanelLaunchFromEntrypointArguments(args);
  final panel = launch?.panel;
  Completer<void>? firstFrameReady;

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    firstFrameReady = Completer<void>();
    final options = WindowOptions(
      // A detached panel opens at the exact size it occupied in the workspace.
      // There is intentionally no fixed minimum or maximum so the OS can resize it.
      size: launch?.initialSize,
      backgroundColor: const Color(0xFF050505),
      title: panel == null
          ? 'Take A Look - Take A Look 调参上位机'
          : launch?.role == SecondaryWindowRole.dragPreview
          ? 'Take A Look - 拖动预览'
          : launch!.groupPanels.length > 1
          ? 'Take A Look - ${panel.title} 组合'
          : 'Take A Look - ${panel.title}',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await firstFrameReady!.future;
        // Detached engines are prewarmed while hidden. Their owning main
        // window shows them only after assigning panel content.
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
  runApp(
    TakeALookApp(
      detachedPanel: panel,
      detachedPanels: launch?.groupPanels,
      secondaryWindowRole: launch?.role ?? SecondaryWindowRole.detachedPanel,
      enableBackend: panel == null,
    ),
  );
}
