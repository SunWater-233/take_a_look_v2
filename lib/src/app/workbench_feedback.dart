import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/controller.dart';
import '../models/models.dart';
import '../telemetry/recording_storage.dart';
import '../theme/theme.dart';

/// Orders load progress and error feedback in both main and detached windows.
class WorkbenchFeedback extends StatefulWidget {
  const WorkbenchFeedback({
    required this.controller,
    required this.child,
    this.recordingStorage,
    super.key,
  });

  final TakeALookController controller;
  final Widget child;

  /// Supplied only by the main window, so detached engines never rescan or
  /// repeat the startup housekeeping notice.
  final RecordingStorage? recordingStorage;

  @override
  State<WorkbenchFeedback> createState() => _WorkbenchFeedbackState();
}

class _WorkbenchFeedbackState extends State<WorkbenchFeedback> {
  late final _feedback = TalFeedbackController(onNoticeDismissed: _changed);
  Map<String, dynamic>? _lastError;
  Map<String, dynamic>? _pendingError;
  SymbolLoadProgress? _pendingLoad;
  DialogRoute<void>? _loadRoute;
  ValueNotifier<SymbolLoadProgress>? _progress;
  String? _presentedLoadId;
  bool _scheduled = false;
  bool _showingError = false;
  bool _finishing = false;
  int? _pendingRecordingBytes;

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_checkRecordingStorage());
  }

  Future<void> _checkRecordingStorage() async {
    final storage = widget.recordingStorage;
    if (storage == null) return;
    try {
      final bytes = await storage.totalBytes();
      if (!mounted || bytes <= RecordingStorage.warningThresholdBytes) return;
      _pendingRecordingBytes = bytes;
      _changed();
    } catch (error) {
      if (!mounted) return;
      widget.controller.addLog('检查记录文件夹大小失败：$error', level: LogLevel.warning);
    }
  }

  void _showRecordingNotice() {
    final bytes = _pendingRecordingBytes;
    final storage = widget.recordingStorage;
    if (bytes == null ||
        storage == null ||
        _loadRoute != null ||
        widget.controller.isSymbolLoading ||
        _pendingError != null ||
        _feedback.isShowingNotice) {
      return;
    }
    _pendingRecordingBytes = null;
    final megabytes = (bytes / RecordingStorage.bytesPerMb).toStringAsFixed(1);
    _feedback.showActionNotice(
      context: context,
      title: '采样记录占用较多空间',
      message: '已保存的记录共 $megabytes MB，超过 500 MB。可打开记录文件夹，删除不再需要的历史记录。',
      actionLabel: '打开记录文件夹',
      onAction: () async {
        try {
          await storage.openDirectory();
        } catch (error) {
          if (!mounted) return;
          widget.controller.addLog('打开记录文件夹失败：$error', level: LogLevel.warning);
          await _feedback.showError(
            context: context,
            title: '无法打开记录文件夹',
            message: '请手动打开：${storage.directory.path}',
            details: error.toString(),
          );
        }
      },
    );
  }

  void _listen() {
    widget.controller.symbolLoadChanges.addListener(_changed);
    widget.controller.connectionChanges.addListener(_changed);
    _changed();
  }

  void _unlisten(TakeALookController controller) {
    controller.symbolLoadChanges.removeListener(_changed);
    controller.connectionChanges.removeListener(_changed);
  }

  @override
  void didUpdateWidget(covariant WorkbenchFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _unlisten(oldWidget.controller);
    _closeProgress();
    _pendingLoad = null;
    _presentedLoadId = null;
    _lastError = null;
    _pendingError = null;
    _listen();
  }

  void _changed() {
    final load = widget.controller.symbolLoadProgress;
    if (load?.isLoading == true) _pendingLoad = load;
    final error = widget.controller.lastBackendError;
    if (error == null) {
      _lastError = null;
    } else if (!identical(error, _lastError)) {
      _lastError = error;
      _pendingError = Map<String, dynamic>.from(error);
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _synchronize();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _synchronize() {
    final load = widget.controller.symbolLoadProgress;
    if (load != null) {
      if (_loadRoute == null &&
          _presentedLoadId != load.loadId &&
          (load.isLoading || _pendingLoad?.loadId == load.loadId)) {
        _feedback.dismiss();
        _showProgress(load);
      }
      if (_progress?.value.loadId == load.loadId && !_finishing) {
        _progress!.value = load;
        if (load.status == SymbolLoadStatus.failed) {
          _closeProgress();
        } else if (load.status == SymbolLoadStatus.complete) {
          unawaited(_finishProgress(_loadRoute!, load));
        }
      }
    }
    if (_loadRoute == null) unawaited(_showErrors());
  }

  void _showProgress(SymbolLoadProgress load) {
    _presentedLoadId = load.loadId;
    _pendingLoad = null;
    // Keep the mode chosen at opening, including on hybrid touch laptops.
    final loadTheme = Theme.of(context);
    final progress = ValueNotifier(load);
    _progress = progress;
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Theme(
        data: loadTheme,
        child: _SymbolLoadDialog(progress: progress),
      ),
    );
    _loadRoute = route;
    unawaited(route.completed.then((_) => progress.dispose()));
    unawaited(Navigator.of(context, rootNavigator: true).push(route));
  }

  Future<void> _finishProgress(
    DialogRoute<void> route,
    SymbolLoadProgress load,
  ) async {
    _finishing = true;
    // The controller already applied symbols and source lines. Let the symbol
    // panel build its tree before presenting 100% and removing the modal.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _loadRoute != route) return;
    final symbolCount = widget.controller.symbols.length;
    _progress!.value = load.copyWith(
      phase: 'done',
      current: symbolCount,
      total: symbolCount,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted || _loadRoute != route) return;
    _closeProgress();
    _synchronize();
  }

  void _closeProgress() {
    final route = _loadRoute;
    _loadRoute = null;
    _progress = null;
    _finishing = false;
    // Remove only our route; a newer error dialog must never be popped.
    if (route?.isActive == true) route!.navigator!.removeRoute(route);
  }

  Future<void> _showErrors() async {
    if (_showingError ||
        _loadRoute != null ||
        widget.controller.isSymbolLoading) {
      return;
    }
    _showingError = true;
    try {
      while (mounted && _loadRoute == null && _pendingError != null) {
        final error = _pendingError!;
        _pendingError = null;
        await _feedback.showError(
          context: context,
          title: _backendErrorTitle(error),
          message: error['message'] as String? ?? '后端操作失败。',
          details: error['details']?.toString(),
        );
      }
    } finally {
      _showingError = false;
      if (mounted) _showRecordingNotice();
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    final route = _loadRoute;
    // The parent navigator may itself be disposing in this frame.
    scheduleMicrotask(() {
      if (route?.isActive == true && route!.navigator?.mounted == true) {
        route.navigator!.removeRoute(route);
      }
    });
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SymbolLoadDialog extends StatefulWidget {
  const _SymbolLoadDialog({required this.progress});

  final ValueListenable<SymbolLoadProgress> progress;

  @override
  State<_SymbolLoadDialog> createState() => _SymbolLoadDialogState();
}

class _SymbolLoadDialogState extends State<_SymbolLoadDialog> {
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && widget.progress.value.isLoading) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SymbolLoadProgress>(
        valueListenable: widget.progress,
        builder: (context, progress, _) {
          final elapsed = (progress.finishedAt ?? DateTime.now()).difference(
            progress.startedAt,
          );
          return TalProgressDialog(
            key: const ValueKey('symbol-load-dialog'),
            title: progress.phase == 'done' ? '加载完成' : '正在加载 ELF',
            fileName: progress.path.replaceAll('\\', '/').split('/').last,
            phase: progress.label,
            step: progress.step,
            elapsed: elapsed.isNegative ? Duration.zero : elapsed,
            value: progress.fraction,
            current: progress.current,
            total: progress.total,
          );
        },
      );
}

String _backendErrorTitle(Map<String, dynamic> error) =>
    switch (error['code']) {
      'startup_failed' => '后端启动失败',
      'connect_failed' => 'pyOCD 连接失败',
      'file_not_found' ||
      'unsupported_symbol_file' ||
      'symbol_load_failed' ||
      'symbol_load_timeout' => '读取失败',
      'timeout' when error['operation'] == 'loadSymbols' => '读取失败',
      'write_failed' || 'readonly_symbol' || 'unknown_watch' => '写入失败',
      'reset_failed' => '目标复位失败',
      'no_samples' => '导出失败',
      _ => '操作失败',
    };
