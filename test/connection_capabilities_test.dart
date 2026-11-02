import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';

void main() {
  test(
    'backend capabilities override configuration and reach detached windows',
    () {
      final main = TakeALookController();
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      addTearDown(main.dispose);
      addTearDown(detached.dispose);
      final versions = main.snapshotVersions();
      main.applySnapshot({
        'connectionKind': 'local',
        'connectionCapabilities': {
          'memorySampling': true,
          'memoryWrite': false,
          'rtt': false,
          'firmwareDownload': false,
          'targetControl': false,
        },
      });
      expect(main.supportsMemoryWrite, isFalse);
      expect(main.supportsTargetControl, isFalse);
      expect(main.supportsFirmwareDownload, isFalse);
      final delta = main.stateDeltaSnapshot(versions);
      expect(delta, contains('connectionCapabilities'));
      detached.applySnapshot(delta);
      expect(detached.supportsMemoryWrite, isFalse);
      expect(detached.supportsTargetControl, isFalse);
      expect(detached.supportsFirmwareDownload, isFalse);
      expect(main.projectSettings(), isNot(contains('connectionCapabilities')));
    },
  );

  test(
    'old backend and changed configurations use offline capability defaults',
    () {
      final controller = TakeALookController();
      addTearDown(controller.dispose);
      controller.applySnapshot({
        'connectionKind': 'gdb', 'remoteConfig': {'gdbMode': 'memory'},
        // Older backends advertise no targetControl field.
        'connectionCapabilities': {'memoryWrite': false},
      });
      expect(controller.supportsMemoryWrite, isFalse);
      expect(controller.supportsTargetControl, isFalse);
      controller.applySnapshot({
        'remoteConfig': {'gdbMode': 'debug'},
      });
      expect(controller.supportsMemoryWrite, isTrue);
      expect(controller.supportsTargetControl, isTrue);
      controller.setConnectionKind('ember');
      expect(controller.supportsMemoryWrite, isFalse);
      expect(controller.supportsFirmwareDownload, isTrue);
    },
  );
}
