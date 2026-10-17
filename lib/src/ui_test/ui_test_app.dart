import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app.dart';
import '../analysis/analysis.dart';
import '../controller/controller.dart';
import '../models/models.dart';
import '../theme/theme.dart';
import '../panels/panels.dart';
import '../workspace/panel_types.dart';
import '../workspace/workspace.dart';
import 'ui_test_session.dart';

class UiTestApp extends StatefulWidget {
  const UiTestApp({required this.directory, this.smokeTest = false, super.key});

  final Directory directory;
  final bool smokeTest;

  @override
  State<UiTestApp> createState() => _UiTestAppState();
}

class _UiTestAppState extends State<UiTestApp> {
  final _captureKey = GlobalKey();
  late final UiTestSession _session;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  TalInputMode? _inputMode;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _session = UiTestSession(
      sourcePath: '${widget.directory.path}/motor_control.c',
    );
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _session.recordError(details.exception, details.stack);
      _previousFlutterError?.call(details);
    };
    _previousPlatformError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      _session.recordError(error, stack);
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    if (widget.smokeTest) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_smokeTest()),
      );
    }
  }

  Future<void> _capture(String name) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${widget.directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
    await _session.writeDiagnostics(
      File('${widget.directory.path}/$name.json'),
    );
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final name = 'ui-test-${DateTime.now().millisecondsSinceEpoch}';
      await _capture(name);
      _session.controller.addLog('诊断和截图已保存：${widget.directory.path}/$name');
    } catch (error, stack) {
      _session.recordError(error, stack);
      _session.controller.addLog('诊断导出失败：$error', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // Runs in the actual compiled Windows engine. Pointer/keyboard interactions
  // are covered separately by widget tests; these checks cover native startup.
  Future<void> _smokeTest() async {
    var passed = false;
    void check(bool value, String message) {
      if (!value) throw StateError(message);
    }

    try {
      // Cold native startup includes font upload and the storage notice's
      // entrance animation. Capture only after both have had time to settle.
      await Future<void>.delayed(const Duration(seconds: 2));
      final controller = _session.controller;
      check(
        controller.watches.first.totalSampleCount > 400,
        'Live samples did not advance.',
      );
      await _capture('smoke-live');
      DockingWorkspaceState? workspace;
      void findWorkspace(Element element) {
        if (element is StatefulElement &&
            element.state is DockingWorkspaceState) {
          workspace = element.state as DockingWorkspaceState;
        }
        element.visitChildren(findWorkspace);
      }

      (context as Element).visitChildren(findWorkspace);
      check(workspace != null, 'Workbench layout was not mounted.');
      final monitor = controller.watches[2], manual = controller.watches[3];
      controller.setWatchReadMode(monitor.symbol.key, WatchReadMode.monitor);
      controller.setWatchReadMode(manual.symbol.key, WatchReadMode.manual);
      final monitorCount = monitor.totalSampleCount,
          manualCount = manual.totalSampleCount;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      controller.readWatch(manual.symbol.key);
      controller.writeWatch(manual.symbol.key, '42.5');
      check(manual.value == 42.5, 'Manual write readback failed.');
      check(
        monitor.totalSampleCount == monitorCount &&
            manual.totalSampleCount == manualCount,
        'Latest-only values entered history.',
      );
      await _capture('smoke-watch-modes');
      await workspace!.activateWorkbenchView(WorkspacePanelId.sourceDebug);
      controller.openSourceFile(_session.sourcePath);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _capture('smoke-source');
      final currentWorkspace = workspace!;
      if (!currentWorkspace.mounted) return;
      final navigator = Navigator.of(currentWorkspace.context);
      final settings = showWorkbenchProjectSettings(
        currentWorkspace.context,
        controller,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _capture('smoke-project-settings');
      if (navigator.mounted) navigator.pop();
      await settings;
      controller.analysisSession.replaceData([
        for (final watch in controller.watches.take(2))
          AnalysisSeries.fromSamples(
            name: watch.symbol.name,
            color: watch.color,
            samples: watch.samples,
          ),
      ], '当前实时数据');
      controller.analysisSession
        ..selectionStart = 1
        ..selectionEnd = 3
        ..fftVisible = true
        ..updateSelectionStats();
      controller.commitAnalysisSession(includeData: true);
      await workspace!.activateWorkbenchView(WorkspacePanelId.analysis);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _capture('smoke-analysis');
      await workspace!.activateWorkbenchView(WorkspacePanelId.plot);
      controller.toggleSampling();
      final count = controller.watches.first.totalSampleCount;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      check(
        controller.watches.first.totalSampleCount == count,
        'Pause did not stop sampling.',
      );
      controller.toggleSampling();
      controller.haltTarget();
      controller.stepTarget();
      check(controller.debugState.currentLine == 11, 'Source step failed.');
      controller.resumeTarget();
      await _session.simulateLoad();
      check(
        controller.symbolLoadProgress?.status == SymbolLoadStatus.complete,
        'Load did not finish.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _session.simulateLoad(fail: true);
      check(
        controller.symbolLoadProgress?.status == SymbolLoadStatus.failed,
        'Load failure was not reported.',
      );
      check(controller.watches.isNotEmpty, 'Load failure discarded watches.');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _capture('smoke-error');

      _session.reset(UiTestScenario.dense);
      controller.configurePlotView({'plotRetentionSeconds': 60});
      await Future<void>.delayed(const Duration(milliseconds: 3800));
      controller.toggleSampling();
      check(
        controller.watches.length == 32,
        'Dense fixture did not create 32 channels.',
      );
      check(
        controller.watches.every(
          (watch) =>
              watch.samples.length == watch.totalSampleCount &&
              watch.samples.first.dx == 0.01,
        ),
        'Dense history disappeared before its retention deadline.',
      );
      await _capture('smoke-dense-history');
      controller.configurePlotView({'plotRetentionSeconds': 1});
      controller.toggleSampling();
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      controller.toggleSampling();
      final recorded = _session.recording.sampleCount;
      check(
        controller.watches.first.samples.length < recorded,
        'Dense fixture did not roll over its plot cache.',
      );
      final exported = await _session.recording.exportCsv(
        '${widget.directory.path}/smoke-dense-full.csv',
      );
      check(
        exported == recorded,
        'CSV did not include the complete raw recording.',
      );
      await _capture('smoke-dense-retention');
      controller.configurePlotView({'plotRetentionSeconds': 60});
      check(
        _session.errors.isEmpty,
        'Flutter reported errors during smoke checks.',
      );
      passed = true;
    } catch (error, stack) {
      _session.recordError(error, stack);
    } finally {
      await _session.writeDiagnostics(
        File('${widget.directory.path}/smoke-result.json'),
        smokePassed: passed,
      );
      // Let the native runner close its engines and input-method hooks on the
      // platform thread. dart:io exit() can interrupt those window callbacks.
      await windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _captureKey,
    child: TakeALookApp(
      controller: _session.controller,
      layoutFile: File('${widget.directory.path}/layout.json'),
      inputModeOverride: _inputMode,
      workbenchToolbar: UiTestToolbar(
        session: _session,
        inputMode: _inputMode,
        onInputMode: (mode) => setState(() => _inputMode = mode),
        onExport: _exporting ? null : _export,
      ),
    ),
  );

  @override
  void dispose() {
    FlutterError.onError = _previousFlutterError;
    ui.PlatformDispatcher.instance.onError = _previousPlatformError;
    _session.dispose();
    super.dispose();
  }
}

class UiTestToolbar extends StatelessWidget {
  const UiTestToolbar({
    required this.session,
    required this.inputMode,
    required this.onInputMode,
    required this.onExport,
    super.key,
  });

  final UiTestSession session;
  final TalInputMode? inputMode;
  final ValueChanged<TalInputMode?> onInputMode;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session,
      session.controller.symbolLoadChanges,
    ]),
    builder: (context, _) {
      final busy = session.controller.isSymbolLoading;
      return Container(
        decoration: const BoxDecoration(
          color: TalColors.input,
          border: Border(bottom: BorderSide(color: TalColors.amber)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Text(
                'UI 测试版 · 模拟数据',
                style: TextStyle(color: TalColors.amber),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 132,
                child: TalDropdown<UiTestScenario>(
                  value: session.scenario,
                  values: UiTestScenario.values,
                  label: (value) => value.label,
                  onChanged: session.reset,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 136,
                child: TalDropdown<String>(
                  value: inputMode?.name ?? 'auto',
                  values: const ['auto', 'mouseKeyboard', 'touch'],
                  label: (value) => switch (value) {
                    'touch' => '触屏预览',
                    'mouseKeyboard' => '键鼠预览',
                    _ => '自动输入模式',
                  },
                  onChanged: (value) => onInputMode(
                    value == 'auto' ? null : TalInputMode.values.byName(value),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TalButton(
                onPressed: busy ? null : () => session.reset(session.scenario),
                child: const Text('恢复场景'),
              ),
              const SizedBox(width: 8),
              TalButton(
                onPressed: busy ? null : () => session.simulateLoad(),
                child: const Text('加载进度'),
              ),
              const SizedBox(width: 8),
              TalButton(
                onPressed: busy ? null : () => session.simulateLoad(fail: true),
                child: const Text('加载失败'),
              ),
              const SizedBox(width: 8),
              TalButton(
                onPressed: busy ? null : session.injectDisconnect,
                child: const Text('连接中断'),
              ),
              const SizedBox(width: 8),
              TalButton(onPressed: onExport, child: const Text('导出诊断')),
            ],
          ),
        ),
      );
    },
  );
}
