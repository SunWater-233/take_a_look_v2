// Build with: flutter build windows --release --target
// tool/benchmarks/window_resize_benchmark.dart
// TAL_RESIZE_BENCH_DIR is required. TAL_RESIZE_BENCH_MODE=native waits for
// native.done in that directory, allowing an actual border drag to be measured.
// Otherwise the real native window is resized along three repeatable paths.
// TAL_RESIZE_BENCH_SCENE=empty isolates the embedder from application content.
// Optional Windows diagnostics: configure CMake with
// -DTAL_WINDOW_RESIZE_DIAGNOSTICS=ON. TAL_RESIZE_BENCH_SEPARATE_UI=0 then
// supplies a merged-thread control; native-keyboard starts Windows sizing mode.
// Restore the CMake option to OFF before building the normal lib/main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:take_a_look_v2/src/app/app.dart';
import 'package:take_a_look_v2/src/app/bootstrap.dart';
import 'package:take_a_look_v2/src/workspace/workspace.dart';

Future<void> main(List<String> args) async {
  final launch = detachedPanelLaunchFromEntrypointArguments(args);
  final output = Platform.environment['TAL_RESIZE_BENCH_DIR'];
  if (!kReleaseMode || output == null) {
    throw StateError('Use a release build with TAL_RESIZE_BENCH_DIR.');
  }
  final directory = Directory(output)..createSync(recursive: true);
  final recorder = launch == null ? _Recorder(directory) : null;
  WidgetsFlutterBinding.ensureInitialized();
  recorder?.attach();
  await launchWorkbench(
    args,
    title: 'Take A Look - Resize benchmark',
    appBuilder: (launch) =>
        Platform.environment['TAL_RESIZE_BENCH_SCENE'] == 'empty'
        ? const MaterialApp(home: ColoredBox(color: Color(0xff181c22)))
        : TakeALookApp(
            detachedPanel: launch?.panel,
            detachedPanels: launch?.groupPanels,
            secondaryWindowRole:
                launch?.role ?? SecondaryWindowRole.detachedPanel,
            enableBackend: launch == null,
            layoutFile: launch == null ? File('$output/layout.json') : null,
          ),
  );
  if (recorder != null) await recorder.run();
}

class _Recorder with WidgetsBindingObserver, WindowListener {
  _Recorder(this.directory);

  final Directory directory;
  final clock = Stopwatch()..start();
  final frames = <Map<String, Object?>>[];
  final layouts = <Map<String, Object?>>[];
  final metrics = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];
  final nativeEvents = <Map<String, Object?>>[];
  final errors = <String>[];
  String phase = 'warmup';
  int lastMetricsUs = 0;
  bool active = true;
  Element? workspace;
  FlutterExceptionHandler? previousError;

  void attach() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    windowManager.addListener(this);
    binding.addTimingsCallback(_timings);
    binding.addPostFrameCallback(_layout);
    previousError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details.toString());
      previousError?.call(details);
    };
  }

  @override
  void onWindowResize() => nativeEvents.add({
    'us': clock.elapsedMicroseconds,
    'event': 'resize',
    'phase': phase,
  });

  @override
  void onWindowResized() => nativeEvents.add({
    'us': clock.elapsedMicroseconds,
    'event': 'resized',
    'phase': phase,
  });

  @override
  void didChangeMetrics() {
    lastMetricsUs = clock.elapsedMicroseconds;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    metrics.add({
      'us': lastMetricsUs,
      'phase': phase,
      'width': view.physicalSize.width / view.devicePixelRatio,
      'height': view.physicalSize.height / view.devicePixelRatio,
    });
  }

  void _timings(List<ui.FrameTiming> values) {
    for (final value in values) {
      frames.add({
        'phaseAtDelivery': phase,
        'vsyncUs': value.timestampInMicroseconds(ui.FramePhase.vsyncStart),
        'buildStartUs': value.timestampInMicroseconds(ui.FramePhase.buildStart),
        'buildMs': value.buildDuration.inMicroseconds / 1000,
        'rasterMs': value.rasterDuration.inMicroseconds / 1000,
        'totalMs': value.totalSpan.inMicroseconds / 1000,
        'vsyncOverheadMs': value.vsyncOverhead.inMicroseconds / 1000,
      });
    }
  }

  void _layout(Duration frameTimestamp) {
    if (!active) return;
    final now = clock.elapsedMicroseconds;
    if (workspace == null || !workspace!.mounted) {
      void find(Element element) {
        if (element.widget is DockingWorkspace) workspace = element;
        if (workspace == null) element.visitChildren(find);
      }

      final root = WidgetsBinding.instance.rootElement;
      if (root != null) find(root);
    }
    final workbox = workspace?.findRenderObject();
    {
      var maxError = 0.0;
      var count = 0;
      void inspect(Element element) {
        if (workbox is! RenderBox) return;
        final widget = element.widget;
        if (widget is AnimatedPositioned &&
            widget.key.toString().contains('workspace-group-')) {
          final box = element.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            final position = workbox.globalToLocal(
              box.localToGlobal(Offset.zero),
            );
            final expected = <double>[
              widget.left!,
              widget.top!,
              widget.width!,
              widget.height!,
            ];
            final actual = <double>[
              position.dx,
              position.dy,
              box.size.width,
              box.size.height,
            ];
            for (var i = 0; i < actual.length; i++) {
              maxError = math.max(maxError, (actual[i] - expected[i]).abs());
            }
            count++;
          }
        }
        element.visitChildren(inspect);
      }

      if (workbox is RenderBox && workbox.hasSize) {
        workspace!.visitChildren(inspect);
      }
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = workbox is RenderBox && workbox.hasSize
          ? workbox.size
          : view.physicalSize / view.devicePixelRatio;
      layouts.add({
        'us': now,
        'frameTimestampUs': frameTimestamp.inMicroseconds,
        'phase': phase,
        'metricsAgeMs': (now - lastMetricsUs) / 1000,
        'width': size.width,
        'height': size.height,
        'maxPanelErrorPx': maxError,
        'panels': count,
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(_layout);
  }

  Future<void> run() async {
    try {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (Platform.environment['TAL_RESIZE_BENCH_TITLEBAR'] == 'normal') {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
      await windowManager.unmaximize();
      await windowManager.setPosition(const Offset(80, 60));
      await windowManager.setSize(const Size(1200, 760));
      await Future<void>.delayed(const Duration(seconds: 1));
      phase = 'idle';
      await Future<void>.delayed(const Duration(seconds: 2));
      final mode = Platform.environment['TAL_RESIZE_BENCH_MODE'] ?? 'script';
      if (mode == 'native' || mode == 'native-keyboard') {
        phase = 'native-drag';
        if (mode == 'native-keyboard') {
          await const MethodChannel(
            'take_a_look/resize_diagnostics',
          ).invokeMethod<void>('beginKeyboardResize');
        }
        File('${directory.path}/ready.json').writeAsStringSync('{}');
        final done = File('${directory.path}/native.done');
        final deadline = clock.elapsed + const Duration(minutes: 2);
        while (!done.existsSync() && clock.elapsed < deadline) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!done.existsSync()) throw StateError('Native drag timed out.');
        if (nativeEvents.isEmpty) {
          throw StateError('No native sizing events were recorded.');
        }
      } else {
        for (var repeat = 1; repeat <= 2; repeat++) {
          for (final axis in ['horizontal', 'vertical', 'diagonal']) {
            phase = '$axis-$repeat';
            final start = clock.elapsedMicroseconds;
            // A round trip in 96 steps, paced against a monotonic clock.
            for (var step = 0; step <= 96; step++) {
              final fraction = step <= 48 ? step / 48 : (96 - step) / 48;
              final size = Size(
                1200 + (axis == 'vertical' ? 0 : 320 * fraction),
                760 + (axis == 'horizontal' ? 0 : 180 * fraction),
              );
              final before = clock.elapsedMicroseconds;
              await windowManager.setSize(size);
              requests.add({
                'phase': phase,
                'us': before,
                'callMs': (clock.elapsedMicroseconds - before) / 1000,
                'width': size.width,
                'height': size.height,
              });
              final remaining =
                  start + (step + 1) * 16667 - clock.elapsedMicroseconds;
              if (remaining > 0) {
                await Future<void>.delayed(Duration(microseconds: remaining));
              }
            }
            phase = 'settle-$axis-$repeat';
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }
      phase = 'final-settle';
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (error, stack) {
      errors.add('$error\n$stack');
    } finally {
      active = false;
      WidgetsBinding.instance.removeObserver(this);
      windowManager.removeListener(this);
      WidgetsBinding.instance.removeTimingsCallback(_timings);
      FlutterError.onError = previousError;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      File('${directory.path}/results.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'release': kReleaseMode,
          'mode': Platform.environment['TAL_RESIZE_BENCH_MODE'] ?? 'script',
          'scene':
              Platform.environment['TAL_RESIZE_BENCH_SCENE'] ?? 'production',
          'titlebar':
              Platform.environment['TAL_RESIZE_BENCH_TITLEBAR'] ?? 'hidden',
          'separateUiOverride':
              Platform.environment['TAL_RESIZE_BENCH_SEPARATE_UI'],
          'description':
              Platform.environment['TAL_RESIZE_BENCH_SCENE'] == 'empty'
              ? 'Empty scene, no backend or prewarmed engines; visible native window.'
              : 'Production app, backend enabled, no connected device; '
                    'visible native window; geometry errors are logical pixels.',
          'devicePixelRatio': view.devicePixelRatio,
          'displayRefreshRate': view.display.refreshRate,
          'frames': frames,
          'layouts': layouts,
          'metrics': metrics,
          'requests': requests,
          'nativeEvents': nativeEvents,
          'errors': errors,
        }),
      );
      await windowManager.close();
    }
  }
}
