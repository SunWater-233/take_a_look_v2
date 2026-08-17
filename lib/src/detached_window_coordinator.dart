import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'panel_types.dart';
import 'window_sync.dart';

class DetachedWindowCoordinator {
  DetachedWindowCoordinator(this.windowSync);

  final MainWindowSync windowSync;
  final Map<WorkspacePanelId, WindowController> _windows =
      <WorkspacePanelId, WindowController>{};

  Map<WorkspacePanelId, WindowController> get windows => _windows;
  Stream<void> get changes => onWindowsChanged;

  Future<bool> showIfOpen(WorkspacePanelId panel) async {
    final window = _windows[panel];
    if (window == null) return false;
    await window.show();
    return true;
  }

  Future<WindowController> create({
    required WorkspacePanelId activePanel,
    required List<WorkspacePanelId> panels,
    required Size initialSize,
  }) async {
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: encodePanelArguments(
          activePanel,
          initialSize,
          panels: panels,
        ),
        hiddenAtLaunch: true,
      ),
    );
    for (final panel in panels) {
      _windows[panel] = window;
    }
    windowSync.registerWindow(activePanel, window);
    return window;
  }

  Future<List<WorkspacePanelId>> reconcile() async {
    final windows = await WindowController.getAll();
    final livePanels = <WorkspacePanelId>{};
    for (final window in windows) {
      final panels = _panelsFromArguments(window.arguments);
      for (final panel in panels) {
        livePanels.add(panel);
        _windows[panel] = window;
      }
    }
    final closed = _windows.keys
        .where((panel) => !livePanels.contains(panel))
        .toList(growable: false);
    for (final panel in closed) {
      _windows.remove(panel);
      windowSync.unregisterWindow(panel);
    }
    return closed;
  }

  List<WorkspacePanelId> _panelsFromArguments(String arguments) {
    return detachedPanelLaunchFromEntrypointArguments([
          'multi_window',
          '0',
          arguments,
        ])?.groupPanels ??
        const <WorkspacePanelId>[];
  }
}
