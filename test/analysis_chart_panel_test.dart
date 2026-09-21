import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller.dart';
import 'package:take_a_look_v2/src/panels.dart';
import 'package:take_a_look_v2/src/panel_types.dart';
import 'package:take_a_look_v2/src/theme.dart';

void main() {
  testWidgets('FFT button splits the chart and selects a CSV signal', (
    tester,
  ) async {
    final controller = TakeALookController(
      csvImportContentsPicker: () async =>
          'index,elapsed_s,alpha,beta\n'
          '0,0.00,0,1\n'
          '1,0.01,1,0\n'
          '2,0.02,0,-1\n'
          '3,0.03,-1,0\n'
          '4,0.04,0,1\n'
          '5,0.05,1,0\n'
          '6,0.06,0,-1\n'
          '7,0.07,-1,0\n',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();

    expect(controller.analysisSession.fftTimeSeriesIndex, 0);
    expect(controller.analysisSession.fftSeriesIndex, 1);
    await tester.tap(find.byKey(const ValueKey('analysis-fft-toggle')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('analysis-fft-split-view')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('analysis-fft-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('analysis-fft-chart')), findsOneWidget);
    expect(find.textContaining('Fs 100'), findsOneWidget);
    expect(find.text('Y轴'), findsOneWidget);
    expect(find.text('信号'), findsNothing);
    final fftPanelRect = tester.getRect(
      find.byKey(const ValueKey('analysis-fft-panel')),
    );
    final fftSelectorRect = tester.getRect(
      find.byKey(const ValueKey('analysis-fft-signal-select')),
    );
    final fftTimeSelectorRect = tester.getRect(
      find.byKey(const ValueKey('analysis-fft-time-select')),
    );
    final timeChartRect = tester.getRect(
      find.byKey(const ValueKey('analysis-chart-interaction')),
    );
    expect(fftSelectorRect.bottom, lessThanOrEqualTo(fftPanelRect.top));
    expect(fftPanelRect.top, closeTo(timeChartRect.top, 1));
    expect(fftSelectorRect.width, closeTo(192, 0.1));
    expect(fftTimeSelectorRect.width, closeTo(132, 0.1));
    expect(
      find.byKey(const ValueKey('analysis-fft-Y轴-touch-dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('analysis-fft-时间-touch-dropdown')),
      findsOneWidget,
    );

    final toolbarMouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await toolbarMouse.addPointer(location: Offset.zero);
    await toolbarMouse.moveTo(fftSelectorRect.center);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis-fft-Y轴-mouse-dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('analysis-fft-时间-mouse-dropdown')),
      findsOneWidget,
    );

    final toolbarTouch = await tester.startGesture(
      fftSelectorRect.center,
      kind: PointerDeviceKind.touch,
    );
    await toolbarTouch.up();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis-fft-Y轴-touch-dropdown')),
      findsOneWidget,
    );
    await toolbarMouse.removePointer();
    await tester.tapAt(fftPanelRect.center);
    await tester.pumpAndSettle();

    final fftInteraction = find.byKey(
      const ValueKey('analysis-fft-interaction'),
    );
    final fftChart = find.byKey(const ValueKey('analysis-fft-chart'));
    dynamic fftPainter = tester.widget<CustomPaint>(fftChart).painter!;
    final initialSpan =
        (fftPainter.xMax as double) - (fftPainter.xMin as double);
    final fftCenter = tester.getCenter(fftInteraction);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: fftCenter,
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.pump();
    fftPainter = tester.widget<CustomPaint>(fftChart).painter!;
    final zoomedSpan =
        (fftPainter.xMax as double) - (fftPainter.xMin as double);
    expect(zoomedSpan, lessThan(initialSpan));

    final beforePanMinimum = fftPainter.xMin as double;
    final pan = await tester.startGesture(
      fftCenter,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await pan.moveBy(const Offset(-35, 0));
    await pan.up();
    await tester.pump();
    fftPainter = tester.widget<CustomPaint>(fftChart).painter!;
    expect(fftPainter.xMin as double, greaterThan(beforePanMinimum));

    final selection = await tester.startGesture(
      fftCenter - const Offset(45, 0),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await selection.moveTo(fftCenter + const Offset(45, 0));
    await selection.up();
    await tester.pump();
    expect(controller.analysisSession.fftSelectionStart, isNotNull);
    expect(controller.analysisSession.fftSelectionEnd, isNotNull);

    final rightClick = await tester.startGesture(
      fftCenter,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(find.text('View All'), findsOneWidget);
    expect(find.text('X Axis'), findsOneWidget);
    expect(find.text('Y Axis'), findsOneWidget);
    expect(find.text('Mouse Mode'), findsOneWidget);
    await tester.tap(find.text('View All'));
    await tester.pumpAndSettle();
    fftPainter = tester.widget<CustomPaint>(fftChart).painter!;
    expect(
      (fftPainter.xMax as double) - (fftPainter.xMin as double),
      closeTo(initialSpan, 1e-9),
    );

    await tester.tap(find.byKey(const ValueKey('analysis-fft-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('analysis-fft-panel')), findsNothing);
    controller.dispose();
  });

  testWidgets(
    'analysis panel imports realtime samples and reports selection statistics',
    (tester) async {
      final controller = TakeALookController()..loadDemoSymbols();
      controller.selectSymbols([demoSymbols.first.key]);
      controller.addSelectedToWatch();
      final key = controller.watches.single.symbol.key;
      controller.applyTelemetrySnapshot({
        'elapsedSeconds': 4,
        'watches': [
          {
            'key': key,
            'value': 4,
            'samples': [
              [0, 0],
              [1, 1],
              [2, 2],
              [3, 3],
              [4, 4],
            ],
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 700,
              child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
            ),
          ),
        ),
      );

      expect(find.text('导入数据'), findsNWidgets(2));
      await tester.tap(find.text('导入数据').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前实时数据'));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前实时数据'), findsOneWidget);
      final chart = find.byType(CustomPaint).last;
      final chartRect = tester.getRect(chart);
      final drag = await tester.startGesture(
        chartRect.centerLeft + const Offset(70, 0),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await drag.moveTo(chartRect.centerRight - const Offset(70, 0));
      await drag.up();
      await tester.pump();

      expect(find.text('样本数'), findsOneWidget);
      expect(find.text('是否绘制'), findsOneWidget);
      expect(find.text('平均值'), findsOneWidget);
      expect(find.text('峰峰值'), findsOneWidget);

      final statsContent = find.byKey(
        const ValueKey('analysis-stats-table-content'),
      );
      final heightResizeHandle = find.byKey(
        const ValueKey('analysis-stats-height-resize'),
      );
      final beforeHeightResize = tester.getSize(statsContent).height;
      await tester.drag(heightResizeHandle, const Offset(0, -40));
      await tester.pump();
      expect(
        tester.getSize(statsContent).height,
        closeTo(beforeHeightResize + 40, 1),
      );

      expect(
        find.byKey(const ValueKey('analysis-stats-column-resize-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('analysis-stats-column-resize-6')),
        findsOneWidget,
      );

      final firstResizeHandle = find.byKey(
        const ValueKey('analysis-stats-column-resize-0'),
      );
      final beforeResize = tester.getCenter(firstResizeHandle).dx;
      final resizeColumn = await tester.startGesture(
        tester.getCenter(firstResizeHandle),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await resizeColumn.moveBy(const Offset(45, 0));
      await resizeColumn.up();
      await tester.pump();
      expect(
        tester.getCenter(firstResizeHandle).dx,
        closeTo(beforeResize + 45, 1),
      );

      final statsResizeRegion = find.byKey(
        const ValueKey('analysis-stats-table-resize-region'),
      );
      final statsRow = find.byKey(
        ValueKey('analysis-stats-row-${controller.watches.single.symbol.name}'),
      );
      final beforeRightResizeX = tester.getCenter(firstResizeHandle).dx;
      final beforeRightResizeRowHeight = tester.getSize(statsRow).height;
      final resizeAll = await tester.startGesture(
        tester.getCenter(statsResizeRegion),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await resizeAll.moveBy(const Offset(30, 20));
      await resizeAll.up();
      await tester.pump();
      expect(
        tester.getCenter(firstResizeHandle).dx,
        closeTo(beforeRightResizeX + 25.5, 1),
      );
      expect(
        tester.getSize(statsRow).height,
        closeTo(beforeRightResizeRowHeight + 17, 1),
      );
      controller.dispose();
    },
  );

  testWidgets(
    'analysis chart supports wheel/right-button zoom and middle-button pan',
    (tester) async {
      final controller = TakeALookController(
        csvImportContentsPicker: () async =>
            'time,signal\n0,0\n1,1\n2,2\n3,3\n4,4\n',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 700,
              child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
            ),
          ),
        ),
      );
      await tester.tap(find.text('导入数据').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地 CSV'));
      await tester.pumpAndSettle();

      final interaction = find.byKey(
        const ValueKey('analysis-chart-interaction'),
      );
      final chart = find.byKey(const ValueKey('analysis-chart-series-layer'));
      dynamic painter = tester.widget<CustomPaint>(chart).painter!;
      final initialSpan = (painter.xMax as double) - (painter.xMin as double);
      final center = tester.getCenter(interaction);
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -20)),
      );
      await tester.pump();

      painter = tester.widget<CustomPaint>(chart).painter!;
      final zoomedSpan = (painter.xMax as double) - (painter.xMin as double);
      expect(zoomedSpan, lessThan(initialSpan));

      final beforeRightXSpan = zoomedSpan;
      final beforeRightYSpan =
          (painter.yMax as double) - (painter.yMin as double);
      final rightZoom = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await rightZoom.moveBy(const Offset(50, 0));
      await rightZoom.up();
      await tester.pump();

      expect(find.text('View All'), findsNothing);

      painter = tester.widget<CustomPaint>(chart).painter!;
      final afterRightXSpan =
          (painter.xMax as double) - (painter.xMin as double);
      final afterRightYSpan =
          (painter.yMax as double) - (painter.yMin as double);
      expect(afterRightXSpan, lessThan(beforeRightXSpan));
      expect(afterRightYSpan, closeTo(beforeRightYSpan, 1e-9));

      final beforePanMin = painter.xMin as double;
      final pan = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await pan.moveBy(const Offset(-80, 0));
      await pan.up();
      await tester.pump();

      painter = tester.widget<CustomPaint>(chart).painter!;
      expect(painter.xMin as double, greaterThan(beforePanMin));
      expect(find.text('样本数'), findsNothing);
      controller.dispose();
    },
  );

  testWidgets('analysis plot provides the realtime chart context menu', (
    tester,
  ) async {
    final controller = TakeALookController(
      csvImportContentsPicker: () async =>
          'time,signal\n0,0\n1,1\n2,2\n3,3\n4,4\n',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();

    final interaction = find.byKey(
      const ValueKey('analysis-chart-interaction'),
    );
    final chart = find.byKey(const ValueKey('analysis-chart-series-layer'));
    dynamic painter = tester.widget<CustomPaint>(chart).painter!;
    final initialXSpan = (painter.xMax as double) - (painter.xMin as double);
    final center = tester.getCenter(interaction);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -20)),
    );
    await tester.pump();

    final rightClick = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightClick.up();
    await tester.pumpAndSettle();
    expect(find.text('View All'), findsOneWidget);
    expect(find.text('X Axis'), findsOneWidget);
    expect(find.text('Y Axis'), findsOneWidget);
    expect(find.text('Mouse Mode'), findsOneWidget);
    final menuAnchor = tester.widget<MenuAnchor>(
      find.byKey(const ValueKey('analysis-plot-menu-anchor')),
    );
    expect(menuAnchor.animated, isTrue);
    expect(menuAnchor.style, same(talContextMenuStyle));

    await tester.tap(find.text('View All'));
    await tester.pumpAndSettle();
    painter = tester.widget<CustomPaint>(chart).painter!;
    expect(
      (painter.xMax as double) - (painter.xMin as double),
      closeTo(initialXSpan, 1e-9),
    );

    final modeMenu = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await modeMenu.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 Button'));
    await tester.pumpAndSettle();

    final rectangle = await tester.startGesture(
      center - const Offset(100, 70),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await rectangle.moveTo(center + const Offset(100, 70));
    await rectangle.up();
    await tester.pump();
    painter = tester.widget<CustomPaint>(chart).painter!;
    expect(
      (painter.xMax as double) - (painter.xMin as double),
      lessThan(initialXSpan),
    );

    final touch = await tester.startGesture(
      center,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('显示全部'), findsOneWidget);
    expect(find.text('X 轴详细设置…'), findsOneWidget);
    expect(find.text('Y 轴详细设置…'), findsOneWidget);
    await touch.up();
    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();

    controller.dispose();
  });

  testWidgets('analysis panel parses a local CSV through the injected picker', (
    tester,
  ) async {
    final controller = TakeALookController(
      csvImportContentsPicker: () async => 'time,signal\n0,1\n1,3\n2,2\n',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本地 CSV'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('analysis cells and headers provide realtime-style menus', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final controller = TakeALookController(
      csvImportContentsPicker: () async =>
          'time,alpha,beta\n0,1,10\n1,2,20\n2,3,30\n3,4,40\n',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: buildWorkspacePanel(WorkspacePanelId.analysis, controller),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();

    final chartRect = tester.getRect(
      find.byKey(const ValueKey('analysis-chart-interaction')),
    );
    final selection = await tester.startGesture(
      chartRect.centerLeft + const Offset(70, 0),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await selection.moveTo(chartRect.centerRight - const Offset(70, 0));
    await selection.up();
    await tester.pump();

    final firstNameCell = find.byKey(const ValueKey('analysis-stats-cell-0-0'));
    await tester.tap(firstNameCell, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('仅绘制该栏'), findsOneWidget);
    final desktopCopyItem = find.byKey(
      const ValueKey('analysis-cell-menu-copy'),
    );
    final desktopButton = tester.widget<MenuItemButton>(desktopCopyItem);
    expect(desktopButton.style, same(talContextMenuButtonStyle));
    expect(
      find.descendant(of: desktopCopyItem, matching: find.byType(Icon)),
      findsNothing,
    );
    final cellMenuAnchor = tester.widget<MenuAnchor>(
      find.descendant(of: firstNameCell, matching: find.byType(MenuAnchor)),
    );
    expect(cellMenuAnchor.animated, isTrue);
    expect(cellMenuAnchor.style, same(talContextMenuStyle));
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copiedText, 'alpha');

    final secondValueCell = find.byKey(
      const ValueKey('analysis-stats-cell-1-2'),
    );
    await tester.tap(secondValueCell, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅绘制该栏'));
    await tester.pumpAndSettle();
    final painter = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('analysis-chart-series-layer')),
        )
        .painter!;
    expect((painter as dynamic).seriesVisibility, <bool>[false, true]);

    await tester.tap(find.text('最小值'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('隐藏该列'), findsOneWidget);
    expect(find.text('显示全列'), findsOneWidget);
    final desktopHideItem = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('analysis-header-menu-hide')),
    );
    expect(desktopHideItem.style, same(talContextMenuButtonStyle));
    final headerMenuAnchor = tester.widget<MenuAnchor>(
      find.descendant(
        of: find.byKey(const ValueKey('analysis-stats-header-2')),
        matching: find.byType(MenuAnchor),
      ),
    );
    expect(headerMenuAnchor.animated, isTrue);
    expect(headerMenuAnchor.style, same(talContextMenuStyle));
    await tester.tap(find.text('隐藏该列'));
    await tester.pumpAndSettle();
    expect(find.text('最小值'), findsNothing);

    await tester.tap(find.text('曲线'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示全列'));
    await tester.pumpAndSettle();
    expect(find.text('最小值'), findsOneWidget);

    final headerTouch = await tester.startGesture(
      tester.getCenter(find.text('最小值')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    final touchHideItem = find.ancestor(
      of: find.text('隐藏该列'),
      matching: find.byType(PopupMenuItem<String>),
    );
    expect(tester.widget<PopupMenuItem<String>>(touchHideItem).height, 48);
    await headerTouch.up();
    await tester.tap(find.text('显示全列'));
    await tester.pumpAndSettle();

    final touch = await tester.startGesture(
      tester.getCenter(firstNameCell),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    final touchCopyItem = find.ancestor(
      of: find.text('复制'),
      matching: find.byType(PopupMenuItem<String>),
    );
    expect(tester.widget<PopupMenuItem<String>>(touchCopyItem).height, 48);
    expect(
      find.descendant(of: touchCopyItem, matching: find.byType(Icon)),
      findsNothing,
    );
    await touch.up();
    await tester.tapAt(const Offset(980, 20));
    await tester.pumpAndSettle();

    controller.dispose();
  });

  testWidgets('analysis session survives switching to another panel and back', (
    tester,
  ) async {
    final controller = TakeALookController(
      csvImportContentsPicker: () async =>
          'time,signal\n0,0\n1,1\n2,2\n3,3\n4,4\n',
    );
    final activePanel = ValueNotifier(WorkspacePanelId.analysis);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: ValueListenableBuilder<WorkspacePanelId>(
              valueListenable: activePanel,
              builder: (context, panel, _) =>
                  buildWorkspacePanel(panel, controller),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('导入数据').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地 CSV'));
    await tester.pumpAndSettle();

    final interaction = find.byKey(
      const ValueKey('analysis-chart-interaction'),
    );
    final chart = find.byKey(const ValueKey('analysis-chart-series-layer'));
    final center = tester.getCenter(interaction);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -20)),
    );
    await tester.pump();
    final painterBeforeSwitch = tester.widget<CustomPaint>(chart).painter!;
    final xMinBeforeSwitch = (painterBeforeSwitch as dynamic).xMin as double;
    final xMaxBeforeSwitch = (painterBeforeSwitch as dynamic).xMax as double;

    final chartRect = tester.getRect(interaction);
    final selection = await tester.startGesture(
      chartRect.centerLeft + const Offset(90, 0),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await selection.moveTo(chartRect.centerRight - const Offset(90, 0));
    await selection.up();
    await tester.pump();
    expect(find.text('样本数'), findsOneWidget);

    final visibilityToggle = find.byKey(
      const ValueKey('analysis-series-visible-0'),
    );
    expect(visibilityToggle, findsOneWidget);
    expect(
      (tester.widget<CustomPaint>(chart).painter! as dynamic)
          .visibleSeriesCount,
      1,
    );
    await tester.tap(visibilityToggle);
    await tester.pump();
    expect(
      (tester.widget<CustomPaint>(chart).painter! as dynamic)
          .visibleSeriesCount,
      0,
    );

    activePanel.value = WorkspacePanelId.watch;
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis-chart-interaction')),
      findsNothing,
    );

    activePanel.value = WorkspacePanelId.analysis;
    await tester.pump();

    expect(find.textContaining('本地 CSV'), findsOneWidget);
    expect(find.text('样本数'), findsOneWidget);
    final restoredChart = find.byKey(
      const ValueKey('analysis-chart-series-layer'),
    );
    final restoredPainter = tester.widget<CustomPaint>(restoredChart).painter!;
    expect((restoredPainter as dynamic).xMin, xMinBeforeSwitch);
    expect((restoredPainter as dynamic).xMax, xMaxBeforeSwitch);
    expect((restoredPainter as dynamic).visibleSeriesCount, 0);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('analysis-series-visible-0')),
          )
          .value,
      isFalse,
    );

    activePanel.dispose();
    controller.dispose();
  });
}
