import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';

void main() {
  test('live zoom retains a window extending before the first sample', () {
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    controller.applyTelemetrySnapshot({'elapsedSeconds': 1});
    controller.setPlotViewport(xMin: -11, xMax: 1, preserveFollowLatest: true);
    expect(controller.followLatest, isTrue);
    expect(controller.plotVisibleWindowSeconds, 12);
    expect(controller.plotWindowEndSeconds, 1);
    controller.applyTelemetrySnapshot({'elapsedSeconds': 30});
    expect(controller.plotWindowEndSeconds, 30);
    expect(controller.plotVisibleWindowSeconds, 12);
  });

  test(
    'detached zoom preserves live or manual follow state across command routing',
    () async {
      final main = TakeALookController(backendCommand: (_, _) async {});
      final preserveFlags = <Object?>[];
      late final TakeALookController detached;
      detached = TakeALookController(
        remoteCommand: (command, arguments) async {
          preserveFlags.add((arguments! as Map)['preserveFollowLatest']);
          detached.applySnapshot(await main.handleCommand(command, arguments));
        },
      );
      addTearDown(main.dispose);
      addTearDown(detached.dispose);
      main.applyTelemetrySnapshot({'elapsedSeconds': 20});
      detached.applySnapshot(main.snapshot());

      detached.setPlotViewport(xMin: 16, xMax: 20, preserveFollowLatest: true);
      await Future<void>.delayed(Duration.zero);
      expect(main.followLatest, isTrue);
      expect(detached.followLatest, isTrue);
      expect(detached.plotVisibleWindowSeconds, 4);
      main.applyTelemetrySnapshot({'elapsedSeconds': 22});
      detached.applySnapshot(main.stateSnapshot());
      expect(detached.plotWindowEndSeconds, 22);

      // Ordinary panning still moves into a fixed historical window.
      detached.setPlotViewport(xMin: 2, xMax: 6);
      await Future<void>.delayed(Duration.zero);
      expect(main.followLatest, isFalse);
      expect(detached.plotWindowEndSeconds, 6);
      detached.setPlotViewport(xMin: 3, xMax: 5, preserveFollowLatest: true);
      await Future<void>.delayed(Duration.zero);
      expect(main.followLatest, isFalse);
      expect(detached.followLatest, isFalse);
      expect(detached.plotWindowEndSeconds, 5);
      expect(detached.plotVisibleWindowSeconds, 2);
      expect(preserveFlags, [true, null, true]);
    },
  );
}
