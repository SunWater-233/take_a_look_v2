import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/workbench_chrome.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

void main() {
  testWidgets('capture settings show the overclock help and send the toggle', (
    tester,
  ) async {
    final requests = <BackendCall>[];
    late final TakeALookController controller;
    controller = TakeALookController(
      backendCommand: (command, arguments) async {
        if (command == ControllerCommand.setMemoryOverclock) {
          final call = BackendCommandMapper.translate(command, arguments, {})!;
          requests.add(call);
          controller.applySnapshot(call.params);
        }
      },
    );
    addTearDown(controller.dispose);
    controller.setPresentationActive(false);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showWorkbenchSamplingSettings(context, controller),
              child: const Text('打开采集设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开采集设置'));
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('memory-overclock'));
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    expect(find.textContaining('HID 或 Bulk'), findsOneWidget);
    expect(find.textContaining('同时排队最多 4 个读包'), findsOneWidget);
    expect(find.textContaining('设定采样率'), findsOneWidget);
    expect(find.textContaining('间隔可能不均匀'), findsOneWidget);
    expect(find.textContaining('读取超时'), findsOneWidget);

    await tester.tap(find.text('超频模式'));
    await tester.pumpAndSettle();
    expect(requests.single.method, BackendMethod.setConfig);
    expect(requests.single.params, {'memoryOverclock': true});
    expect(tester.widget<CheckboxListTile>(tile).value, isTrue);

    controller.applySnapshot({
      'connectionStatus': 'connected',
      'memoryPipelineDepth': 1,
    });
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull);

    controller.applySnapshot({'memoryPipelineDepth': 0});
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(tile).onChanged, isNull);
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    expect(find.text('超频模式仅适用于本地 CMSIS-DAP。'), findsOneWidget);
    await tester.tap(find.text('超频模式'));
    expect(requests, hasLength(1));

    controller.applySnapshot({'memoryPipelineDepth': 4});
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(tile).value, isTrue);
    await tester.tap(find.text('超频模式'));
    await tester.pumpAndSettle();
    expect(requests.last.params, {'memoryOverclock': false});
    expect(tester.takeException(), isNull);
  });

  testWidgets('toolbar capture dropdown edits custom rates and keeps presets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rates = <double>[];
    late final TakeALookController controller;
    controller = TakeALookController(
      backendCommand: (command, arguments) async {
        if (command == ControllerCommand.setSampleRate) {
          rates.add(arguments as double);
          controller.applySnapshot({'sampleRateHz': arguments});
        }
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(body: WorkbenchToolbar(controller: controller)),
      ),
    );

    Finder rate(String label) =>
        find.byKey(ValueKey('compact-dropdown-$label'));
    Finder arrow(Finder dropdown) => find.descendant(
      of: dropdown,
      matching: find.byIcon(Icons.arrow_drop_down),
    );
    Finder rateText(String label) =>
        find.descendant(of: rate(label), matching: find.text(label));
    Future<void> click(Offset target) =>
        tester.tapAt(target, kind: PointerDeviceKind.mouse);

    Future<void> submit(Finder field, String text) async {
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    final initial = rate('50 Hz');
    final initialBounds = tester.getRect(initial);
    final preset = find.byKey(const ValueKey('dropdown-item-100 Hz'));
    await click(Offset(initialBounds.right - 3, initialBounds.center.dy));
    await tester.pump();
    expect(preset, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('dropdown-menu-animation')))
          .height,
      greaterThan(0),
    );

    await click(tester.getCenter(rateText('50 Hz')));
    await tester.pump();
    expect(preset, findsNothing);
    final editor = find.byType(TextField);
    expect(editor, findsOneWidget);
    expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
    final editableText = find.descendant(
      of: editor,
      matching: find.byType(EditableText),
    );
    final outline = InputDecorator.containerOf(tester.element(editableText))!;
    expect(outline.localToGlobal(Offset.zero) & outline.size, initialBounds);
    expect(
      tester.getCenter(editableText).dy,
      closeTo(initialBounds.center.dy, 1),
    );
    expect(tester.widget<TextField>(editor).controller!.selection.end, 5);

    await submit(editor, '0 Hz');
    expect(editor, findsOneWidget);
    expect(find.text(captureRateEditor.errorMessage), findsOneWidget);
    expect(rates, isEmpty);

    await submit(editor, '1.001 kHz');
    expect(editor, findsNothing);
    expect(controller.sampleRateHz, 1001);
    expect(rates, [1001]);

    final custom = rate('1.001 kHz');
    await click(tester.getCenter(rateText('1.001 kHz')));
    await tester.pump();
    expect(editor, findsOneWidget);
    expect(preset, findsNothing);
    await tester.enterText(editor, '250');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(rates, [1001]);

    await click(tester.getCenter(rateText('1.001 kHz')));
    await tester.pump();
    await tester.enterText(editor, '250');
    await click(tester.getCenter(arrow(editor)));
    await tester.pump();
    expect(editor, findsNothing);
    expect(preset, findsOneWidget);
    expect(rates, [1001]);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('dropdown-selected-1.001 kHz')),
      findsOneWidget,
    );
    await click(tester.getCenter(arrow(custom)));
    await tester.pumpAndSettle();
    expect(preset, findsNothing);
    expect(editor, findsNothing);
    await click(tester.getCenter(arrow(custom)));
    await tester.pumpAndSettle();
    await tester.tap(preset);
    await tester.pumpAndSettle();
    expect(controller.sampleRateHz, 100);
    expect(rates, [1001, 100]);
  });

  for (final mode in TalInputMode.values) {
    testWidgets('$mode warns once when a probe cannot use enabled overclock', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TakeALookController();
      addTearDown(controller.dispose);
      controller.setPresentationActive(false);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: WorkbenchFeedback(
            controller: controller,
            child: const Scaffold(),
          ),
        ),
      );

      final popup = find.byKey(const ValueKey('tal-warning-popup'));
      void applyState(Map<String, dynamic> state) {
        controller.applyBackendEvent(BackendEventType.state, state);
      }

      applyState({'connectionStatus': 'connected', 'memoryPipelineDepth': 0});
      await tester.pumpAndSettle();
      expect(popup, findsNothing);

      applyState({'connectionStatus': 'disconnected', 'memoryOverclock': true});
      applyState({'connectionStatus': 'connecting'});
      await tester.pumpAndSettle();
      expect(popup, findsNothing);

      applyState({'connectionStatus': 'connected', 'memoryPipelineDepth': 0});
      await tester.pumpAndSettle();
      expect(find.text('超频模式不可用'), findsOneWidget);
      expect(popup, findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: popup,
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
      );
      expect(icon.color, TalColors.amber);
      final corner = tester.getBottomRight(popup);
      expect(corner.dx, inInclusiveRange(900, 1000));
      expect(corner.dy, inInclusiveRange(500, 600));

      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      applyState({'connectionStatus': 'connected', 'sampleRateHz': 5000});
      await tester.pumpAndSettle();
      expect(popup, findsNothing);

      applyState({'connectionStatus': 'disconnected'});
      applyState({'connectionStatus': 'connected', 'memoryPipelineDepth': 1});
      await tester.pumpAndSettle();
      expect(popup, findsNothing);

      applyState({
        'connectionStatus': 'disconnected',
        'memoryPipelineDepth': 0,
      });
      applyState({'connectionStatus': 'connected'});
      await tester.pumpAndSettle();
      expect(popup, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$mode probe loss stops capture and updates connection feedback',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final commands = <ControllerCommand>[];
        final controller = TakeALookController(
          backendCommand: (command, _) async => commands.add(command),
        );
        addTearDown(controller.dispose);
        controller.applySnapshot({
          'connectionStatus': 'connected',
          'samplingPaused': false,
          'rttEnabled': true,
          'debug': {'executionState': 'running'},
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: Scaffold(
              body: WorkbenchFeedback(
                controller: controller,
                child: WorkbenchToolbar(controller: controller),
              ),
            ),
          ),
        );
        // Finish the initial monitor-visibility sync before observing loss.
        await tester.pumpAndSettle();
        commands.clear();
        controller.applyBackendEvent(BackendEventType.state, {
          'connectionStatus': 'disconnected',
          'samplingPaused': true,
          'rttEnabled': false,
          'debug': {'executionState': 'unavailable'},
        });
        controller.applyBackendEvent(BackendEventType.error, {
          'code': 'probe_disconnected',
          'message': '本地调试探针连接已中断，已停止采样；请重新连接探针。',
        });
        await tester.pumpAndSettle();
        expect(controller.connectionStatus, ConnectionStatus.disconnected);
        expect(controller.samplingPaused, isTrue);
        expect(controller.rttEnabled, isFalse);
        expect(
          controller.logs.where(
            (entry) => entry.message.contains('本地调试探针连接已中断'),
          ),
          hasLength(1),
        );
        expect(find.text('探针连接已中断'), findsOneWidget);
        expect(
          tester
              .widget<TalButton>(
                find.byKey(const ValueKey('workbench-disconnect')),
              )
              .onPressed,
          isNull,
        );
        expect(commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('$mode toolbar disconnect follows connection state', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final commands = <ControllerCommand>[];
      late TakeALookController controller;
      controller = TakeALookController(
        backendCommand: (command, _) async {
          commands.add(command);
          if (command == ControllerCommand.toggleConnection) {
            controller.applySnapshot({'connectionStatus': 'disconnected'});
          }
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(inputMode: mode),
          home: Scaffold(body: WorkbenchToolbar(controller: controller)),
        ),
      );

      final disconnect = find.byKey(const ValueKey('workbench-disconnect'));
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      controller.applySnapshot({'connectionStatus': 'connecting'});
      await tester.pump();
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      expect(commands, isEmpty);

      controller.applySnapshot({'connectionStatus': 'connected'});
      await tester.pump();
      expect(tester.widget<TalButton>(disconnect).onPressed, isNotNull);
      expect(
        tester.getRect(disconnect).left,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('workbench-target'))).right,
        ),
      );
      expect(
        tester.getRect(disconnect).right,
        lessThan(tester.getRect(find.text('复位')).left),
      );

      await tester.tap(disconnect);
      await tester.pumpAndSettle();
      expect(commands, [ControllerCommand.toggleConnection]);
      expect(controller.connectionStatus, ConnectionStatus.disconnected);
      expect(tester.widget<TalButton>(disconnect).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$mode connection dialog fits content and scrolls remote fields',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = TakeALookController(backendCommand: (_, _) async {});
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTalTheme(inputMode: mode),
            home: Scaffold(body: WorkbenchToolbar(controller: controller)),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('workbench-connection')));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final surface = find
            .descendant(of: dialog, matching: find.byType(Material))
            .first;
        final localHeight = tester.getSize(surface).height;
        expect(localHeight, lessThan(500));
        expect(find.text('序列号').hitTestable(), findsOneWidget);
        expect(find.text('连接探针').hitTestable(), findsOneWidget);

        controller.applySnapshot({'connectionKind': 'emberGdb'});
        await tester.pumpAndSettle();
        expect(tester.getSize(surface).height, greaterThan(localHeight));

        await tester.binding.setSurfaceSize(const Size(1280, 400));
        await tester.pumpAndSettle();
        expect(find.text('关闭').hitTestable(), findsOneWidget);
        final scroll = find.descendant(
          of: dialog,
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(scroll, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('remote-gdbPath')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
      },
    );
  }
}
