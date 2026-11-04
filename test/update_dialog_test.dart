import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/app/title_bar.dart';
import 'package:take_a_look_v2/src/app/workbench_feedback.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';
import 'package:take_a_look_v2/src/updates/update_controller.dart';
import 'package:take_a_look_v2/src/updates/update_dialog.dart';
import 'package:take_a_look_v2/src/updates/update_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in {
      'MiSans': 'assets/fonts/MiSans-Regular.otf',
      'JetBrains Mono': 'assets/fonts/JetBrainsMono-Regular.ttf',
      'Ibrand': 'assets/fonts/Ibrand.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  for (final mode in TalInputMode.values) {
    testWidgets(
      '$mode brand opens update dialog with persistent toggle and explicit check',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final updates = _UiUpdates();
        addTearDown(updates.dispose);
        await tester.pumpWidget(_harness(updates, mode));
        await tester.tap(find.byKey(const ValueKey('app-update-entry')));
        await tester.pumpAndSettle();
        expect(find.text('关于与更新'), findsOneWidget);
        expect(find.text('当前版本：1.9.0+5'), findsOneWidget);
        expect(updates.requests, 0);
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('update-include-prereleases')),
              )
              .value,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('update-auto-check')));
        await tester.pumpAndSettle();
        expect(updates.autoCheck, isFalse);
        await tester.tap(find.text('立即检查'));
        await tester.pumpAndSettle();
        expect(updates.requests, 1);
        expect(find.text('发现新版本 v1.10.0'), findsOneWidget);
        expect(find.text('修复连接问题\n改进采样体验'), findsOneWidget);
        expect(find.text('下载更新'), findsOneWidget);
        expect(find.text('重启并更新'), findsNothing);
        expect(tester.takeException(), isNull);
        if (mode == TalInputMode.mouseKeyboard) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('update-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('build/update_dialog_preview.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('app-update-entry')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('update-auto-check')),
              )
              .value,
          isFalse,
        );
      },
    );
  }

  testWidgets(
    'preview switch rechecks the channel and remains selected after reopening',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final updates = _UiUpdates();
      addTearDown(updates.dispose);
      await tester.pumpWidget(_harness(updates, TalInputMode.mouseKeyboard));
      await tester.tap(find.byKey(const ValueKey('app-update-entry')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('update-include-prereleases')),
      );
      await tester.pumpAndSettle();
      expect(updates.includePrereleases, isTrue);
      expect(updates.requests, 1);
      expect(find.text('发现新版本 v1.11.0-beta.1（预览版）'), findsOneWidget);
      expect(find.text('下载更新'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-update-entry')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('update-include-prereleases')),
            )
            .value,
        isTrue,
      );
    },
  );

  testWidgets(
    'download button changes to verified restart action and dismissing confirmation does not install',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final updates = _UiUpdates();
      addTearDown(updates.dispose);
      await updates.check();
      var installs = 0;
      await tester.pumpWidget(
        _harness(
          updates,
          TalInputMode.mouseKeyboard,
          onInstall: () async {
            installs++;
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('app-update-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载更新'));
      await tester.pumpAndSettle();
      expect(find.text('下载完成，SHA-256 校验通过。'), findsOneWidget);
      await tester.tap(find.text('重启并更新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('停止采集并断开设备'), findsOneWidget);
      await tester.tap(find.text('继续使用'));
      await tester.pumpAndSettle();
      expect(installs, 0);
      expect(updates.transfer, UpdateTransfer.ready);
    },
  );

  testWidgets(
    'startup notification opens details once; ignored versions stay quiet',
    (tester) async {
      final updates = _UiUpdates();
      final controller = TakeALookController(backendCommand: (_, _) async {});
      addTearDown(updates.dispose);
      addTearDown(controller.dispose);
      await updates.check();
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTalTheme(),
          home: Scaffold(
            body: WorkbenchFeedback(
              controller: controller,
              updates: updates,
              onShowUpdates: () async {
                opens++;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 v1.10.0'), findsOneWidget);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(opens, 1);
      await updates.check();
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 v1.10.0'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Widget _harness(
  _UiUpdates updates,
  TalInputMode mode, {
  Future<void> Function()? onInstall,
}) => RepaintBoundary(
  key: const ValueKey('update-preview'),
  child: MaterialApp(
    theme: buildTalTheme(inputMode: mode),
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            TalWindowTitleBar(
              onShowUpdates: () => unawaited(
                showAppUpdateDialog(context, updates, onInstall: onInstall),
              ),
            ),
            const Expanded(child: Center(child: Text('工作区'))),
          ],
        ),
      ),
    ),
  ),
);

class _UiUpdates extends AppUpdateController {
  _UiUpdates() {
    initialized = true;
    currentVersion = '1.9.0+5';
    package = UpdatePackageManifest(
      kind: 'windows-portable',
      version: '1.9.0',
      architecture: 'x64',
      files: {'app'},
    );
  }
  int requests = 0;
  @override
  Future<void> initialize({bool automatic = false}) async {}
  @override
  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    notifyListeners();
  }

  @override
  Future<void> setIncludePrereleases(bool value) async {
    includePrereleases = value;
    await check();
  }

  @override
  Future<void> check({bool automatic = false}) async {
    requests++;
    checked = true;
    release = GitHubRelease(
      tag: includePrereleases ? 'v1.11.0-beta.1' : 'v1.10.0',
      name: '版本更新',
      notes: '修复连接问题\n改进采样体验',
      assets: [
        ReleaseAsset(
          name:
              'Take-A-Look-V2-${includePrereleases ? '1.11.0-beta.1' : '1.10.0'}+1-windows-x64-portable.zip',
          url: Uri.parse(
            'https://github.com/$updateRepository/releases/download/v1.10.0/package.zip',
          ),
          size: 1048576,
        ),
      ],
    );
    notifyListeners();
  }

  @override
  Future<void> download() async {
    transfer = UpdateTransfer.ready;
    receivedBytes = totalBytes = 1048576;
    notifyListeners();
  }
}
