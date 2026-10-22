import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart' show ConnectionStatus;
import 'package:take_a_look_v2/src/models/target_catalog.dart';
import 'package:take_a_look_v2/src/panels/panels.dart';
import 'package:take_a_look_v2/src/panels/target_chip_dialog.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';

JsonObject chip(
  String name, {
  String pack = '',
  String vendor = 'STMicroelectronics',
  String version = '1.0.0',
}) => {
  'id': '${pack.isEmpty ? 'builtin' : pack}:${name.toLowerCase()}',
  'name': name.toLowerCase(),
  'partNumber': name,
  'vendor': vendor,
  'families': name.startsWith('STM32H7') ? ['STM32H7', 'STM32H723'] : [],
  'cores': ['Cortex-M7'],
  'memories': [
    {'name': 'Flash', 'start': 0x08000000, 'size': 1024 * 1024, 'kind': 'rom'},
    {'name': 'RAM', 'start': 0x24000000, 'size': 320 * 1024, 'kind': 'ram'},
  ],
  'packId': pack,
  'packLabel': pack.isEmpty ? '内置' : 'Keil.STM32H7xx_DFP $version',
  'available': true,
};

class CatalogHarness {
  final calls = <(String, JsonObject)>[];
  final targets = <JsonObject>[
    chip('auto', vendor: ''),
    chip('STM32F407VG', vendor: 'STMicroelectronics'),
    chip('nRF52840', vendor: 'Nordic Semiconductor'),
  ];
  final packs = <JsonObject>[];
  final recent = <String>[];
  int revision = 0;
  bool failInspect = false;
  bool failList = false;
  bool denyStorage = false;
  Completer<JsonObject>? inspection;

  Future<JsonObject> request(String operation, JsonObject arguments) async {
    calls.add((operation, arguments));
    if (denyStorage &&
        const {'selectTarget', 'removeTargetPack'}.contains(operation)) {
      throw const BackendException(
        'target_catalog_access_denied',
        '无法修改芯片库：当前启动环境没有写入权限。',
      );
    }
    switch (operation) {
      case 'listTargets':
        if (failList) {
          throw const BackendException('catalog_failed', '芯片库加载失败。');
        }
        return {
          'targets': targets,
          'packs': packs,
          'recent': recent,
          'revision': revision,
        };
      case 'inspectTargetPack':
        if (failInspect) {
          throw const BackendException('invalid_pack', '无法解析芯片包。');
        }
        if (inspection != null) return inspection!.future;
        return {
          'previewId': 'preview',
          'id': 'user-pack',
          'name': 'STM32H7xx_DFP',
          'vendor': 'Keil',
          'version': '4.1.0',
          'targetCount': 1,
          'size': 1024 * 1024,
          'sampleTargets': ['STM32H723VGTx'],
          'alreadyInstalled': packs.isNotEmpty,
        };
      case 'importTargetPack':
        if (packs.isEmpty) {
          packs.add({
            'id': 'user-pack',
            'name': 'STM32H7xx_DFP',
            'vendor': 'Keil',
            'version': '4.1.0',
            'targetCount': 1,
            'size': 1024 * 1024,
            'importedAt': '2026-10-17T02:00:00Z',
            'available': true,
          });
          targets.add(
            chip('STM32H723VGTx', pack: 'user-pack', version: '4.1.0'),
          );
        }
        return {
          'packId': 'user-pack',
          'state': {'targetCatalogRevision': ++revision},
        };
      case 'selectTarget':
        final target = targets.firstWhere(
          (target) =>
              target['name'] == arguments['name'] &&
              target['packId'] == arguments['packId'],
        );
        recent.insert(0, target['id'] as String);
        return {
          'state': {
            'targetName': target['name'],
            'targetPartNumber': target['partNumber'],
            'targetPackId': target['packId'],
            'targetPackLabel': target['packLabel'],
            'targetPackMissing': false,
            'targetCatalogRevision': ++revision,
          },
        };
      case 'removeTargetPack':
        packs.removeWhere((pack) => pack['id'] == arguments['packId']);
        targets.removeWhere(
          (target) => target['packId'] == arguments['packId'],
        );
        return {
          'state': {
            'targetPackMissing': true,
            'targetCatalogRevision': ++revision,
          },
        };
      case 'discardTargetPackPreview':
        return {};
      default:
        throw StateError(operation);
    }
  }

  TakeALookController controller() => TakeALookController(
    backendCommand: (_, _) async {},
    targetCatalogRequest: request,
    targetPackPicker: () async => 'D:/User/Keil.STM32H7xx_DFP.pack',
  );
}

Future<void> openDialog(
  WidgetTester tester,
  TakeALookController controller, {
  Size size = const Size(1200, 850),
  GlobalKey? repaintKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: repaintKey,
      child: MaterialApp(
        theme: buildTalTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 350,
              child: buildWorkspacePanelBody(
                WorkspacePanelId.connection,
                controller,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('target-chip-selector')));
  await tester.pumpAndSettle();
  expect(find.byType(TargetChipDialog), findsOneWidget);
}

void main() {
  test(
    'catalog search matches vendor, family, full name and exact version source',
    () {
      final catalog = TargetCatalogData.fromJson({
        'targets': [
          chip('STM32H723VGTx', pack: 'v1'),
          chip('STM32H723VGTx', pack: 'v2', version: '2.0.0'),
          chip('STM32H723VGTxx', pack: 'v1'),
          chip('STM32F407VG'),
        ],
        'recent': ['v2:stm32h723vgtx'],
      });
      expect(
        catalog.search(query: 'stm32h723vgtx').first.partNumber,
        'STM32H723VGTx',
      );
      expect(
        catalog.search(query: 'stmic H723', packId: 'v2').single.packId,
        'v2',
      );
      expect(
        catalog.search(query: 'H723', source: 'recent').single.packId,
        'v2',
      );
      expect(
        catalog.search(source: 'builtin').single.partNumber,
        'STM32F407VG',
      );
      expect(catalog.search(query: 'missing'), isEmpty);
    },
  );

  test(
    'pack identity and catalog revision synchronize through window deltas',
    () async {
      final harness = CatalogHarness();
      await harness.request('importTargetPack', {});
      final main = harness.controller();
      final replica = TakeALookController(
        remoteCommand: (_, _) async {},
        targetCatalogRequest: main.requestTargetCatalog,
      );
      addTearDown(main.dispose);
      addTearDown(replica.dispose);
      final before = main.snapshotVersions();
      var syncs = 0;
      main.stateSyncChanges.addListener(() => syncs++);
      await replica.requestTargetCatalog('selectTarget', {
        'name': 'stm32h723vgtx',
        'packId': 'user-pack',
      });
      replica.applySnapshot(main.stateDeltaSnapshot(before));
      expect(syncs, greaterThan(0));
      expect(main.targetPackId, 'user-pack');
      expect(replica.targetPackId, 'user-pack');
      expect(replica.targetPartNumber, 'STM32H723VGTx');
      expect(replica.targetCatalogRevision, main.targetCatalogRevision);
      main.connectionStatus = ConnectionStatus.connected;
      await main.requestTargetCatalog('selectTarget', {
        'name': 'auto',
        'packId': '',
      });
      expect(main.targetName, 'auto');
      expect(main.connectionStatus, ConnectionStatus.connected);
    },
  );

  testWidgets('selection is searchable and cancel keeps the current target', (
    tester,
  ) async {
    final harness = CatalogHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    await tester.enterText(
      find.byKey(const ValueKey('target-search')),
      'Nordic',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('target-chip-builtin:nrf52840')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('target-chip-builtin:stm32f407vg')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('target-chip-builtin:nrf52840')),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.targetName, 'auto');
    expect(harness.calls.where((call) => call.$1 == 'selectTarget'), isEmpty);
  });

  testWidgets('retrying the catalog clears the previous load error', (
    tester,
  ) async {
    final harness = CatalogHarness()..failList = true;
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    expect(find.text('芯片库加载失败。'), findsOneWidget);
    harness.failList = false;
    await tester.tap(find.text('重新加载芯片库'));
    await tester.pumpAndSettle();
    expect(find.text('芯片库加载失败。'), findsNothing);
    expect(
      find.byKey(const ValueKey('target-chip-builtin:nrf52840')),
      findsOneWidget,
    );
  });

  testWidgets('import retains search and Enter saves the exact pack identity', (
    tester,
  ) async {
    final harness = CatalogHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    await tester.enterText(find.byKey(const ValueKey('target-search')), 'H723');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有匹配的芯片'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-target-pack')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('confirm-target-pack-import')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-target-pack-import')));
    await tester.pumpAndSettle();
    expect(
      harness.calls.where((call) => call.$1 == 'listTargets'),
      hasLength(2), // Initial catalog plus one refresh after import.
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('target-search')))
          .controller!
          .text,
      'H723',
    );
    expect(
      find.byKey(const ValueKey('target-chip-user-pack:stm32h723vgtx')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('target-search')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(TargetChipDialog), findsNothing);
    expect(controller.targetName, 'stm32h723vgtx');
    expect(controller.targetPackId, 'user-pack');
    expect(find.text('STM32H723VGTx'), findsOneWidget);
  });

  testWidgets(
    'connected targets can switch chips but cannot delete the active pack',
    (tester) async {
      final harness = CatalogHarness();
      await harness.request('importTargetPack', {});
      final controller = harness.controller();
      addTearDown(controller.dispose);
      await controller.requestTargetCatalog('selectTarget', {
        'name': 'stm32h723vgtx',
        'packId': 'user-pack',
      });
      controller.connectionStatus = ConnectionStatus.connected;
      await openDialog(tester, controller);
      expect(
        tester
            .widget<TalButton>(find.byKey(const ValueKey('use-target-chip')))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('更换芯片后将自动重新连接'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('manage-target-packs')));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在使用'), findsOneWidget);
      expect(
        tester
            .widget<TalButton>(
              find.byKey(const ValueKey('remove-target-pack-user-pack')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('manage-target-packs')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('target-search')),
        'Nordic',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-target-chip')));
      await tester.pumpAndSettle();
      expect(find.byType(TargetChipDialog), findsNothing);
      expect(controller.targetName, 'nrf52840');
      expect(controller.connectionStatus, ConnectionStatus.connected);
    },
  );

  testWidgets(
    'parse errors stay in the dialog and cancel preview discards staged data',
    (tester) async {
      final harness = CatalogHarness()..failInspect = true;
      final controller = harness.controller();
      addTearDown(controller.dispose);
      await openDialog(tester, controller);
      await tester.tap(find.byKey(const ValueKey('add-target-pack')));
      await tester.pumpAndSettle();
      expect(find.text('无法解析芯片包。'), findsOneWidget);
      harness.failInspect = false;
      await tester.tap(find.byKey(const ValueKey('add-target-pack')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消导入'));
      await tester.pumpAndSettle();
      expect(harness.calls.last.$1, 'discardTargetPackPreview');
      expect(harness.packs, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('denied selection clears busy state and allows another attempt', (
    tester,
  ) async {
    final harness = CatalogHarness()..denyStorage = true;
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    await tester.enterText(find.byKey(const ValueKey('target-search')), 'nRF');
    await tester.pumpAndSettle();
    final use = find.byKey(const ValueKey('use-target-chip'));
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有写入权限'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<TalButton>(use).onPressed, isNotNull);
    harness.denyStorage = false;
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(find.byType(TargetChipDialog), findsNothing);
    expect(controller.targetName, 'nrf52840');
  });

  testWidgets('denied removal keeps the pack visible and permits retry', (
    tester,
  ) async {
    final harness = CatalogHarness();
    await harness.request('importTargetPack', {});
    harness.denyStorage = true;
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    await tester.tap(find.byKey(const ValueKey('manage-target-packs')));
    await tester.pumpAndSettle();
    final remove = find.byKey(const ValueKey('remove-target-pack-user-pack'));
    Future<void> confirmRemoval() async {
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TalButton, '删除').last);
      await tester.pumpAndSettle();
    }

    await confirmRemoval();
    expect(find.textContaining('没有写入权限'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<TalButton>(remove).onPressed, isNotNull);
    expect(harness.packs, hasLength(1));
    harness.denyStorage = false;
    await confirmRemoval();
    expect(harness.packs, isEmpty);
    expect(remove, findsNothing);
  });

  testWidgets('catalog revision refreshes an already open dialog', (
    tester,
  ) async {
    final harness = CatalogHarness();
    final controller = harness.controller();
    addTearDown(controller.dispose);
    await openDialog(tester, controller);
    await tester.enterText(find.byKey(const ValueKey('target-search')), 'H723');
    await controller.requestTargetCatalog('importTargetPack', {
      'previewId': 'external-window',
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('target-chip-user-pack:stm32h723vgtx')),
      findsOneWidget,
    );
  });

  for (final size in const [Size(360, 720), Size(540, 460)]) {
    testWidgets('search, preview and management fit $size', (tester) async {
      final harness = CatalogHarness();
      final controller = harness.controller();
      addTearDown(controller.dispose);
      await openDialog(tester, controller, size: size);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('add-target-pack')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('manage-target-packs')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('render the populated desktop chip selector', (tester) async {
    await tester.runAsync(() async {
      for (final entry in {
        'JetBrains Mono': 'assets/fonts/JetBrainsMono-Regular.ttf',
        'MiSans': 'assets/fonts/MiSans-Regular.otf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
    });
    final harness = CatalogHarness();
    await harness.request('importTargetPack', {});
    final controller = harness.controller();
    addTearDown(controller.dispose);
    final boundaryKey = GlobalKey();
    await openDialog(tester, controller, repaintKey: boundaryKey);
    await tester.enterText(find.byKey(const ValueKey('target-search')), 'H723');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui_test/target_chip_dialog.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
