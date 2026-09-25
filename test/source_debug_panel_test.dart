import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/theme.dart';

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
    expect(find.byKey(const ValueKey('source-search-field')), findsNothing);
    expect(
      find.byKey(ValueKey('source-tab-active-$pubspecPath')),
      findsOneWidget,
    );

    await _searchSources(tester, 'README.MD');
    expect(find.text('1 / 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-0')),
        matching: find.text('README.md'),
      ),
      findsOneWidget,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-search-field')), findsNothing);
    expect(
      find.byKey(ValueKey('source-tab-active-$readmePath')),
      findsOneWidget,
    );

    await _searchSources(tester, 'no_such_source_file_or_text');
    expect(find.text('无结果'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-search-results')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('source-search-field')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Ctrl+F finds project files and ranks build artifacts last', (
    tester,
  ) async {
    late final Directory root;
    late final String sourcePath;
    late final String headerPath;
    late final String notesPath;
    late final String objectPath;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('take_a_look_file_search_');
      Future<String> writeFile(String path, List<int> bytes) async {
        final file = File(
          '${root.path}${Platform.pathSeparator}'
          '${path.replaceAll('/', Platform.pathSeparator)}',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return file.path;
      }

      sourcePath = await writeFile('src/motor.c', 'int ready = 1;\n'.codeUnits);
      headerPath = await writeFile(
        'include/motor.h',
        'void run(void);\n'.codeUnits,
      );
      notesPath = await writeFile(
        'src/notes.c',
        '// motor control\n'.codeUnits,
      );
      objectPath = await writeFile('build/motor.o', [0xff, 0xfe, 0, 1]);
      await writeFile('build/motor.OBJ', [0xff, 0xfe, 0, 2]);
      await writeFile('build/motor.elf', [0x7f, 0x45, 0x4c, 0x46, 0xff]);
      await writeFile('docs/motor.txt', 'Overview\n'.codeUnits);
    });
    addTearDown(() => root.delete(recursive: true));

    const debugPath = 'Z:/build/firmware/src/motor.c';
    final controller = TakeALookController()..setSourceRoot(root.path);
    controller.applyDebugState({
      'sourceFiles': [debugPath, notesPath, objectPath],
      'executableLines': {
        debugPath: [1],
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.sourceDebug, controller),
        ),
      ),
    );
    await _searchSources(tester, 'MoToR');

    // The local source and its build-machine alias yield one filename match.
    // Root-only headers are included, followed by content, then build outputs.
    expect(find.text('1 / 7'), findsOneWidget);
    final labels = [
      'motor.c',
      'motor.h',
      'notes.c:1:4',
      'motor.txt',
      'motor.elf',
      'motor.o',
      'motor.OBJ',
    ];
    final resultScrollable = find.descendant(
      of: find.byKey(const ValueKey('source-search-results')),
      matching: find.byType(Scrollable),
    );
    for (var index = 0; index < labels.length; index += 1) {
      final row = find.byKey(ValueKey('source-search-result-$index'));
      await tester.scrollUntilVisible(row, 30, scrollable: resultScrollable);
      expect(
        find.descendant(of: row, matching: find.text(labels[index])),
        findsOneWidget,
      );
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-search-result-0')),
      -30,
      scrollable: resultScrollable,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-0')),
        matching: find.text(sourcePath),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('source-search-result-0')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('source-tab-active-$debugPath')),
      findsOneWidget,
    );

    // Filename search does not need to decode binary object files as text.
    await _searchSources(tester, 'MOTOR.O');
    expect(find.text('1 / 2'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-0')),
        matching: find.text('motor.o'),
      ),
      findsOneWidget,
    );

    await _searchSources(tester, r'INCLUDE\MOTOR.H');
    expect(find.text('1 / 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('source-search-result-0')));
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-$headerPath')),
      findsOneWidget,
    );
    controller.selectSymbols(const []);
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-$headerPath')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'fuzzy filename results appear before contents and cancel on new input',
    (tester) async {
      const sourcePath = 'Z:/unavailable/firmware/motor_controller.c';
      final controller = TakeALookController();
      controller.applyDebugState({
        'sourceFiles': [
          sourcePath,
          'Z:/unavailable/firmware/motor_controller.txt',
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: buildWorkspacePanel(WorkspacePanelId.sourceDebug, controller),
          ),
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final field = find.byKey(const ValueKey('source-search-field'));
      await tester.enterText(field, 'mtrctrl');
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.text('搜索中…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('source-search-result-0')),
          matching: find.text('motor_controller.c'),
        ),
        findsOneWidget,
      );
      await _searchSources(tester, 'zzzzzz');
      expect(find.text('无结果'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('source-search-result-0')),
        findsNothing,
      );

      await _searchSources(tester, 'mtrctrl');
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('source-tab-active-$sourcePath')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('search keyboard selects, scrolls, confirms and cancels results', (
    tester,
  ) async {
    final sourcePaths = List.generate(
      10,
      (index) =>
          'Z:/unavailable/firmware/keyboard_${index.toString().padLeft(2, '0')}.c',
    );
    final controller = TakeALookController();
    controller.applyDebugState({'sourceFiles': sourcePaths});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.sourceDebug, controller),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('source-search-field'));
    await _searchSources(tester, 'keyboard');
    expect(find.text('1 / 10'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('10 / 10'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-search-result-9')).hitTestable(),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('1 / 10'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-search-result-0')).hitTestable(),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('3 / 10'), findsOneWidget);
    for (var index = 0; index < 6; index += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('9 / 10'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-search-result-8')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(field).controller!.text, 'keyboard');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths.first}')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('source-tab-${sourcePaths[8]}')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(field, findsNothing);
    expect(find.byKey(const ValueKey('source-search-results')), findsNothing);
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[8]}')),
      findsOneWidget,
    );

    await _searchSources(tester, 'keyboard_02');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(field, findsNothing);
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[2]}')),
      findsOneWidget,
    );

    await _searchSources(tester, 'keyboard');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(field, findsNothing);
    expect(
      find.byKey(ValueKey('source-tab-active-${sourcePaths[2]}')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('source-tab-${sourcePaths[1]}')), findsNothing);

    await _searchSources(tester, 'zzzzzz');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(field, findsOneWidget);
    expect(find.text('无结果'), findsOneWidget);

    // Escape also cancels a query whose debounce has not fired yet.
    await tester.enterText(field, 'keyboard_03');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
    expect(field, findsNothing);
    expect(find.byKey(ValueKey('source-tab-${sourcePaths[3]}')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(ValueKey('source-tab-${sourcePaths[2]}')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('source matches keep priority when search reaches its limit', (
    tester,
  ) async {
    late final Directory root;
    late final String sourcePath;
    late final String artifactPath;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('take_a_look_search_limit_');
      final source = File('${root.path}/src/needle.c');
      final artifact = File('${root.path}/build/needle.map');
      await source.parent.create(recursive: true);
      await artifact.parent.create(recursive: true);
      final text = List.filled(1001, '// needle').join('\n');
      await source.writeAsString(text);
      await artifact.writeAsString(text);
      sourcePath = source.path;
      artifactPath = artifact.path;
    });
    addTearDown(() => root.delete(recursive: true));

    final controller = TakeALookController()..setSourceRoot(root.path);
    controller.applyDebugState({
      'sourceFiles': [artifactPath, sourcePath],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.sourceDebug, controller),
        ),
      ),
    );
    await _searchSources(tester, 'needle');
    expect(find.text('1 / 1000'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-0')),
        matching: find.text('needle.c'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-1')),
        matching: find.text('needle.c:1:4'),
      ),
      findsOneWidget,
    );
    final results = find.byKey(const ValueKey('source-search-results'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('source-search-result-999')),
      30000,
      scrollable: find.descendant(
        of: results,
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      find.descendant(of: results, matching: find.text('needle.c:999:4')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('changing the source root refreshes the active filename search', (
    tester,
  ) async {
    late final Directory root;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('take_a_look_search_roots_');
      await Directory('${root.path}/first').create();
      final newFile = File('${root.path}/second/new_header.h');
      await newFile.parent.create();
      await newFile.writeAsString('#define READY 1\n');
    });
    addTearDown(() => root.delete(recursive: true));
    final controller = TakeALookController()
      ..setSourceRoot('${root.path}/first');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildWorkspacePanel(WorkspacePanelId.sourceDebug, controller),
        ),
      ),
    );
    await _searchSources(tester, 'new_header.h');
    expect(find.text('无结果'), findsOneWidget);

    controller.setSourceRoot('${root.path}/second');
    await _waitForSourceSearch(tester);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('source-search-result-0')),
        matching: find.text('new_header.h'),
      ),
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

  testWidgets('source context menu adds a variable and opens an include', (
    tester,
  ) async {
    late final Directory root;
    late final String sourcePath;
    late final String headerPath;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('take_a_look_source_menu_');
      sourcePath =
          '${root.path}${Platform.pathSeparator}src${Platform.pathSeparator}main.c';
      headerPath =
          '${root.path}${Platform.pathSeparator}vendor${Platform.pathSeparator}include'
          '${Platform.pathSeparator}included.h';
      await File(sourcePath).parent.create(recursive: true);
      await File(headerPath).parent.create(recursive: true);
      await File(headerPath).writeAsString('#define READY 1\n');
      await File(sourcePath).writeAsString('#include "included.h"\nmessage\n');
    });
    addTearDown(() => root.delete(recursive: true));

    final controller = TakeALookController()..setSourceRoot(root.path);
    controller.applySnapshot({
      'symbols': [
        {
          'source': sourcePath,
          'name': 'message',
          'address': 0x20000010,
          'type': 'int',
          'size': 4,
          'section': '.bss',
          'key': 'message-key',
        },
      ],
      'watches': <Object?>[],
    });
    controller.applyDebugState({
      'sourceFiles': [sourcePath],
      'executableLines': {
        sourcePath: [1, 2],
      },
      'breakpoints': <Object?>[],
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
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
    for (
      var attempt = 0;
      attempt < 20 && find.byKey(ValueKey('source-line-2')).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    final variableLine = find.byKey(const ValueKey('source-line-2'));
    final variableTopLeft = tester.getTopLeft(variableLine);
    await tester.tapAt(variableTopLeft + const Offset(28, 11));
    await tester.tapAt(variableTopLeft + const Offset(28, 11));
    await tester.pump();
    expect(controller.watches, isEmpty);
    await tester.tapAt(
      variableTopLeft + const Offset(28, 11),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('加入实时调试  message'), findsOneWidget);
    await tester.tap(find.text('加入实时调试  message'));
    await tester.pumpAndSettle();
    expect(controller.watches.single.symbol.key, 'message-key');

    final includeLine = find.byKey(const ValueKey('source-line-1'));
    final includeTopLeft = tester.getTopLeft(includeLine);
    await tester.tapAt(
      includeTopLeft + const Offset(20, 11),
      buttons: kSecondaryMouseButton,
    );
    for (
      var attempt = 0;
      attempt < 20 && find.text('打开头文件  included.h').evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('打开头文件  included.h'), findsOneWidget);
    await tester.tap(find.text('打开头文件  included.h'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(ValueKey('source-tab-$headerPath')), findsOneWidget);
    expect(
      find.byKey(ValueKey('source-tab-active-$headerPath')),
      findsOneWidget,
    );
    controller.selectSymbols(const []);
    await tester.pump();
    expect(
      find.byKey(ValueKey('source-tab-active-$headerPath')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

Future<void> _searchSources(WidgetTester tester, String query) async {
  final field = find.byKey(const ValueKey('source-search-field'));
  if (field.evaluate().isEmpty) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }
  await tester.enterText(field, query);
  await tester.pump(const Duration(milliseconds: 200));
  await _waitForSourceSearch(tester);
}

Future<void> _waitForSourceSearch(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
  for (
    var attempt = 0;
    attempt < 100 && find.text('搜索中…').evaluate().isNotEmpty;
    attempt += 1
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(find.text('搜索中…'), findsNothing);
}
