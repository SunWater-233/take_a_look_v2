import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';

void main() {
  testWidgets(
    'source debugger highlights C code and toggles gutter breakpoints',
    (tester) async {
      final sourcePath =
          '${Directory.current.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}fixtures${Platform.pathSeparator}debug_source.c';
      final controller = TakeALookController();
      controller.applyDebugState({
        'executionState': 'halted',
        'sourceFiles': [sourcePath],
        'executableLines': {
          sourcePath: [3, 4, 5],
        },
        'breakpoints': <Object?>[],
        'registers': {'pc': 0x08000100, 'sp': 0x20001000},
        'stoppedLocation': {
          'path': sourcePath,
          'line': 4,
          'address': 0x08000100,
        },
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: buildWorkspacePanel(
                WorkspacePanelId.sourceDebug,
                controller,
              ),
            ),
          ),
        ),
      );
      final sourceView = find.byKey(ValueKey('source-view-$sourcePath'));
      for (
        var attempt = 0;
        attempt < 10 && sourceView.evaluate().isEmpty;
        attempt += 1
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('已暂停'), findsOneWidget);
      expect(sourceView, findsOneWidget);
      final highlighted = tester
          .widgetList<Text>(find.byType(Text))
          .where(
            (widget) =>
                widget.textSpan?.toPlainText().contains('const char') ?? false,
          );
      expect(highlighted, isNotEmpty);
      final colors = <Color?>[];
      void collect(InlineSpan span) {
        if (span is TextSpan) {
          colors.add(span.style?.color);
          for (final child in span.children ?? const <InlineSpan>[]) {
            collect(child);
          }
        }
      }

      collect(highlighted.first.textSpan!);
      expect(colors.toSet().length, greaterThan(2));

      final executableLine = tester.widget<Container>(
        find.byKey(const ValueKey('executable-line-5')),
      );
      final nonExecutableLine = tester.widget<Container>(
        find.byKey(const ValueKey('executable-line-2')),
      );
      expect(executableLine.color, const Color(0xFF353236));
      expect(nonExecutableLine.color, Colors.transparent);

      await tester.tap(find.byKey(const ValueKey('breakpoint-2')));
      await tester.pump();
      expect(controller.debugState.requestedBreakpoints[sourcePath], isNull);

      await tester.tap(find.byKey(const ValueKey('breakpoint-5')));
      await tester.pump();
      expect(controller.debugState.requestedBreakpoints[sourcePath], {5});

      const backendPath = 'Z:/build/fixtures/debug_source.c';
      controller.applyDebugState({
        'breakpoints': [
          {
            'path': backendPath,
            'requestedLine': 5,
            'actualLine': 5,
            'verified': false,
            'message': '连接调试探针后设置断点。',
          },
        ],
      });
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('breakpoint-5')),
          matching: find.byIcon(Icons.circle),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('breakpoint-5')));
      await tester.pump();
      expect(controller.debugState.requestedBreakpoints, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('configured source root resolves build-machine source paths', (
    tester,
  ) async {
    late final Directory sourceRoot;
    await tester.runAsync(() async {
      sourceRoot = await Directory.systemTemp.createTemp(
        'take_a_look_source_root_',
      );
      final nested = Directory(
        '${sourceRoot.path}${Platform.pathSeparator}firmware'
        '${Platform.pathSeparator}src',
      );
      await nested.create(recursive: true);
      final localSource = File(
        '${nested.path}${Platform.pathSeparator}mapped_source.c',
      );
      await localSource.writeAsString(
        'int mapped_source(void) { return 7; }\n',
      );
    });
    addTearDown(() => sourceRoot.delete(recursive: true));

    const debugPath = 'C:/build/firmware/src/mapped_source.c';
    final controller = TakeALookController()..setSourceRoot(sourceRoot.path);
    controller.applyDebugState({
      'executionState': 'halted',
      'sourceFiles': [debugPath],
      'executableLines': {
        debugPath: [1],
      },
      'breakpoints': <Object?>[],
      'registers': <String, int>{},
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: buildWorkspacePanel(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ),
      ),
    );
    final sourceView = find.byKey(const ValueKey('source-view-$debugPath'));
    for (
      var attempt = 0;
      attempt < 20 && sourceView.evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(sourceView, findsOneWidget);
    expect(find.textContaining('mapped_source'), findsWidgets);
    expect(controller.debugState.sourceRoot, sourceRoot.path);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('source files open as closable scrollable tabs', (tester) async {
    const sourcePaths = <String>[
      'C:/firmware/src/alpha_communication_transport_source.c',
      'C:/firmware/src/bravo_motor_controller_source.c',
      'C:/firmware/src/charlie_attitude_estimator_source.c',
      'C:/firmware/src/delta_navigation_planner_source.c',
      'C:/firmware/src/echo_diagnostic_service_source.c',
    ];

    final controller = TakeALookController();
    controller.applyDebugState({
      'sourceFiles': sourcePaths,
      'executableLines': {
        for (final path in sourcePaths) path: [1],
      },
      'stoppedLocation': {
        'path': sourcePaths.first,
        'line': 1,
        'address': 0x08000100,
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 500,
            child: buildWorkspacePanel(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    Future<void> openFromMenu(String path) async {
      final menu = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('source-file-menu')),
      );
      menu.onSelected!(path);
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(find.byKey(ValueKey('source-tab-${sourcePaths.first}')), findsOne);
    for (final path in sourcePaths.skip(1)) {
      await openFromMenu(path);
    }
    for (final path in sourcePaths) {
      expect(find.byKey(ValueKey('source-tab-$path')), findsOneWidget);
    }

    // Breakpoint refreshes at the same stopped location must not steal focus
    // from a source tab the user selected manually.
    await openFromMenu(sourcePaths[1]);
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[1]}')),
      findsOneWidget,
    );
    controller.applyDebugState({
      'breakpoints': <Object?>[],
      'stoppedLocation': {
        'path': sourcePaths.first,
        'line': 1,
        'address': 0x08000100,
      },
    });
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[1]}')),
      findsOneWidget,
    );

    // Reopening an existing file activates its existing tab instead of adding
    // a duplicate, and brings the beginning of the overflowing strip back.
    await openFromMenu(sourcePaths.first);
    expect(find.byKey(ValueKey('source-tab-${sourcePaths.first}')), findsOne);
    final fade = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('source-tabs-right-fade')),
    );
    expect(fade.opacity, 1);

    final scrollArea = find.byKey(const ValueKey('source-tabs-scroll-area'));
    final scrollPosition = tester.getCenter(scrollArea);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: scrollPosition,
        scrollDelta: const Offset(0, 2000),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('source-tabs-right-fade')),
          )
          .opacity,
      0,
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: scrollPosition,
        scrollDelta: const Offset(0, -2000),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('source-tabs-right-fade')),
          )
          .opacity,
      1,
    );

    final closeButton = tester.widget<IconButton>(
      find.byKey(ValueKey('source-tab-close-${sourcePaths.first}')),
    );
    closeButton.onPressed!();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(ValueKey('source-tab-${sourcePaths.first}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('source-tab-${sourcePaths[1]}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[1]}')),
      findsOneWidget,
    );

    await openFromMenu(sourcePaths.first);
    expect(find.byKey(ValueKey('source-tab-${sourcePaths.first}')), findsOne);

    // Closing must still work when a descendant such as the search field owns
    // the primary focus. This matches the focus arrangement in the docked
    // editor more closely than the panel's initial autofocus state does.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-search-field')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    // IMEs can rewrite the logical key while retaining the physical W key.
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyQ,
      physicalKey: PhysicalKeyboardKey.keyW,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyQ,
      physicalKey: PhysicalKeyboardKey.keyW,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-${sourcePaths.first}')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('opening a file from the menu restores editor shortcut focus', (
    tester,
  ) async {
    const sourcePaths = <String>[
      'C:/firmware/src/alpha_source.c',
      'C:/firmware/src/bravo_source.c',
    ];
    final controller = TakeALookController();
    controller.applyDebugState({
      'sourceFiles': sourcePaths,
      'executableLines': {
        for (final path in sourcePaths) path: [1],
      },
      'stoppedLocation': {
        'path': sourcePaths.first,
        'line': 1,
        'address': 0x08000100,
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 500,
            child: buildWorkspacePanel(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const ValueKey('source-file-menu')));
    await tester.pump(const Duration(milliseconds: 500));
    final menu = tester.widget<PopupMenuButton<String>>(
      find.byKey(const ValueKey('source-file-menu')),
    );
    menu.onSelected!(sourcePaths[1]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[1]}')),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(ValueKey('source-tab-${sourcePaths[1]}')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('dropped files join tabs and Ctrl+F searches across files', (
    tester,
  ) async {
    final readmePath =
        '${Directory.current.path}${Platform.pathSeparator}README.md';
    final pubspecPath =
        '${Directory.current.path}${Platform.pathSeparator}pubspec.yaml';
    final controller = TakeALookController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: buildWorkspacePanel(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final dropTarget = tester.widget<DropTarget>(
      find.byKey(const ValueKey('source-file-drop-target')),
    );
    dropTarget.onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-file-drop-overlay')),
      findsOneWidget,
    );
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(readmePath), DropItemFile(pubspecPath)],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    for (
      var attempt = 0;
      attempt < 20 &&
          find.byKey(ValueKey('source-tab-$pubspecPath')).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byKey(ValueKey('source-tab-$readmePath')), findsOneWidget);
    expect(find.byKey(ValueKey('source-tab-$pubspecPath')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-file-drop-overlay')),
      findsNothing,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-search-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('source-search-field')),
      "publish_to: 'none'",
    );
    await tester.pump(const Duration(milliseconds: 200));
    for (
      var attempt = 0;
      attempt < 20 &&
          find
              .byKey(const ValueKey('source-search-result-0'))
              .evaluate()
              .isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.textContaining('pubspec.yaml:'), findsOneWidget);
    expect(find.textContaining("publish_to: 'none'"), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('source-search-result-0')));
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-$pubspecPath')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Ctrl+W closes a tab selected through an equivalent debug path', (
    tester,
  ) async {
    final localPath =
        '${Directory.current.path}${Platform.pathSeparator}'
        'test${Platform.pathSeparator}fixtures${Platform.pathSeparator}debug_source.c';
    const debugPath = 'Z:/build/firmware/debug_source.c';
    final controller = TakeALookController();
    controller.applyDebugState({
      'sourceFiles': [debugPath],
      'executableLines': {
        debugPath: [1, 2],
      },
      'stoppedLocation': {'path': debugPath, 'line': 1, 'address': 0x08000100},
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 500,
            child: buildWorkspacePanel(
              WorkspacePanelId.sourceDebug,
              controller,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final debugCloseButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('source-tab-close-$debugPath')),
    );
    debugCloseButton.onPressed!();
    await tester.pump();

    final dropTarget = tester.widget<DropTarget>(
      find.byKey(const ValueKey('source-file-drop-target')),
    );
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(localPath)],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    for (
      var attempt = 0;
      attempt < 20 &&
          find.byKey(ValueKey('source-tab-$localPath')).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    // A later backend location update selects the build-machine path while
    // retaining the equivalent local file as the actual open tab.
    controller.applyDebugState({
      'stoppedLocation': {'path': debugPath, 'line': 2, 'address': 0x08000104},
    });
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-$localPath')),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(ValueKey('source-tab-$localPath')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
