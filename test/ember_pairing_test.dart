import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/panels/ember_pairing_dialog.dart';
import 'package:take_a_look_v2/src/theme/theme.dart';

const phone = <String, Object?>{
  'id': 'phone-identity',
  'name': '我的 Ember 手机',
  'host': '192.168.1.49',
  'port': '4242',
  'online': true,
  'paired': false,
};

Future<void> mount(WidgetTester tester, TakeALookController controller) async {
  tester.view.physicalSize = const Size(900, 950);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTalTheme(),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('review'),
          child: EmberPairingDialog(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    for (final font in [
      ('JetBrains Mono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
      ('MiSans', 'assets/fonts/MiSans-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
  });
  testWidgets(
    'discover, compare phone code, remember without exposing credentials',
    (tester) async {
      final calls = <String>[];
      var paired = false;
      final controller = TakeALookController(
        emberRequest: (operation, args) async {
          calls.add(operation);
          return switch (operation) {
            'devices' => {
              'devices': paired
                  ? [
                      {...phone, 'paired': true},
                    ]
                  : [],
            },
            'discover' => {
              'devices': [phone],
            },
            'pair' => {
              'status': 'waiting',
              'code': '12345678',
              'expiresAt': DateTime.now().millisecondsSinceEpoch + 120000,
            },
            'status' =>
              paired
                  ? {
                      'status': 'paired',
                      'device': {...phone, 'paired': true},
                    }
                  : {'status': 'idle'},
            _ => {},
          };
        },
      );
      controller.setConnectionKind('ember');
      controller.setRemoteConfig({'token': 'old-temporary-token'});
      await mount(tester, controller);
      expect(find.textContaining('尚无手机'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ember-discover')));
      await tester.pumpAndSettle();
      expect(find.text('我的 Ember 手机'), findsOneWidget);
      await tester.tap(find.text('配对').last);
      await tester.pump();
      expect(find.text('1234 5678'), findsOneWidget);
      expect(find.textContaining('同意配对'), findsOneWidget);
      expect(controller.remoteConfig['token'], 'old-temporary-token');
      if (Platform.environment['TAL_PAIRING_REVIEW'] case final String path) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('review')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      paired = true;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.textContaining('配对成功'), findsOneWidget);
      expect(controller.remoteConfig['deviceId'], 'phone-identity');
      expect(controller.remoteConfig['token'], '');
      expect(controller.remoteConfig['host'], '192.168.1.49');
      expect(
        controller.projectSettings()['remoteConfig'],
        containsPair('deviceId', 'phone-identity'),
      );
      expect(
        calls,
        containsAllInOrder([
          'devices',
          'discover',
          'pair',
          'status',
          'devices',
        ]),
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'manual pairing cancellation, rejection and offline forget show actionable state',
    (tester) async {
      var state = <String, Object?>{'status': 'idle'};
      var forgotten = false;
      final controller = TakeALookController(
        emberRequest: (operation, args) async {
          switch (operation) {
            case 'devices':
              return {
                'devices': [
                  {...phone, 'paired': true},
                ],
              };
            case 'status':
              return state;
            case 'pair':
              expect(args['host'], '192.168.1.88');
              state = {'status': 'waiting', 'code': '00001234'};
              return state;
            case 'cancel':
              state = {'status': 'cancelled'};
              return state;
            case 'forget':
              forgotten = true;
              return {'devices': [], 'warning': '请在手机中忘记本电脑。'};
            default:
              return {};
          }
        },
      );
      await mount(tester, controller);
      await tester.enterText(
        find.byKey(const ValueKey('ember-manual-host')),
        '192.168.1.88',
      );
      await tester.tap(find.byKey(const ValueKey('ember-manual-pair')));
      await tester.pump();
      expect(find.text('0000 1234'), findsOneWidget);
      await tester.tap(find.text('取消配对'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.text('已取消配对，可重新发起。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ember-manual-pair')));
      await tester.pump();
      state = {'status': 'failed', 'message': '手机已拒绝配对，请重试。'};
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.text('手机已拒绝配对，请重试。'), findsOneWidget);
      await tester.tap(find.byTooltip('忘记 我的 Ember 手机'));
      await tester.pump();
      expect(forgotten, true);
      expect(find.text('请在手机中忘记本电脑。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('closing waiting dialog cancels the pending phone request', (
    tester,
  ) async {
    var cancelled = false;
    final controller = TakeALookController(
      emberRequest: (operation, _) async {
        if (operation == 'cancel') cancelled = true;
        return operation == 'status'
            ? {'status': 'waiting', 'code': '12345678'}
            : {};
      },
    );
    await mount(tester, controller);
    await tester.pumpWidget(const SizedBox());
    expect(cancelled, true);
    controller.dispose();
  });

  test('missing backend reports a useful failure', () async {
    final controller = TakeALookController();
    addTearDown(controller.dispose);
    await expectLater(
      controller.requestEmber('devices'),
      throwsA(predicate((e) => e.toString().contains('本机硬件后端'))),
    );
  });
}
