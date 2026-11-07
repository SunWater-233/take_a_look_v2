import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';
import 'package:take_a_look_v2/src/protocol/events.dart';
import 'package:take_a_look_v2/src/telemetry/sampling_display_clock.dart';
import 'package:take_a_look_v2/src/workspace/window_sync_target.dart';

void main() {
  test(
    'display clock interpolates anchors and freezes without timer ticks',
    () {
      var now = 100.0;
      final clock = SamplingDisplayClock(now: () => now);
      now += 600;
      expect(clock.elapsedSeconds, 0);
      clock.synchronize(2, running: true);
      now += 0.02;
      expect(clock.elapsedSeconds, closeTo(2.02, 1e-9));
      clock.setRunning(false);
      now += 600;
      expect(clock.elapsedSeconds, closeTo(2.02, 1e-9));
      clock.reset();
      now += 600;
      expect(clock.elapsedSeconds, 0);
      clock.synchronize(0, running: true);
      now += 1;
      expect(clock.elapsedSeconds, 1);
    },
  );

  test(
    'backend anchors govern pause, clear, resume and sample time separately',
    () {
      var now = 100.0;
      final commands = <ControllerCommand>[];
      final controller = TakeALookController(
        monotonicSeconds: () => now,
        backendCommand: (command, _) async => commands.add(command),
      );
      addTearDown(controller.dispose);
      controller.applyBackendEvent(BackendEventType.state, {
        'connectionStatus': 'connected',
        'samplingPaused': true,
        'samplingClockRunning': false,
        'samplingElapsedSeconds': 0,
        'elapsedSeconds': 0,
      });
      now += 600;
      controller.toggleSampling();
      expect(commands.last, ControllerCommand.setSamplingPaused);
      expect(controller.samplingElapsedSeconds, 0);
      controller.applyBackendEvent(BackendEventType.state, {
        'samplingPaused': false,
        'samplingClockRunning': true,
        'samplingElapsedSeconds': 0,
      });
      now += 2;
      controller.applyBackendSamples({
        'frames': [
          {'elapsed': 1.98, 'values': <String, Object?>{}},
        ],
      });
      expect(controller.samplingElapsedSeconds, 2);
      expect(controller.elapsedSeconds, 1.98);
      controller.applyBackendEvent(BackendEventType.state, {
        'samplingPaused': true,
        'samplingClockRunning': false,
        'samplingElapsedSeconds': 2,
        'elapsedSeconds': 1.98,
      });
      now += 600;
      expect(controller.samplingElapsedSeconds, 2);
      controller.applyBackendSamplesCleared();
      now += 600;
      expect(controller.samplingElapsedSeconds, 0);
      expect(controller.elapsedSeconds, 0);
      controller.applyBackendEvent(BackendEventType.state, {
        'samplingPaused': false,
        'samplingClockRunning': true,
        'samplingElapsedSeconds': 0,
      });
      now += 0.02;
      expect(controller.samplingElapsedSeconds, closeTo(0.02, 1e-9));
      controller.applyBackendSamples({
        'frames': [
          {'elapsed': 0.02, 'values': <String, Object?>{}},
        ],
      });
      expect(controller.elapsedSeconds, 0.02);
    },
  );

  test(
    'hidden presentations and telemetry deltas keep the same clock anchor',
    () async {
      var now = 100.0;
      final main = TakeALookController(
        monotonicSeconds: () => now,
        backendCommand: (_, _) async {},
      );
      final replica = TakeALookController(
        monotonicSeconds: () => now + 1000,
        remoteCommand: (_, _) async {},
      );
      final target = WindowSyncTarget(main, (method, data) async {
        if (method == 'state') {
          replica.applySnapshot(data);
        } else {
          replica.applyTelemetryDelta(data);
        }
      });
      addTearDown(main.dispose);
      addTearDown(replica.dispose);
      addTearDown(target.dispose);
      main.applySnapshot({
        'connectionStatus': 'connected',
        'samplingClockRunning': true,
        'samplingElapsedSeconds': 2,
      });
      await target.initialize(includeHistory: true, includeAnalysis: false);
      replica.setPresentationActive(false);
      now += 10;
      expect(main.samplingElapsedSeconds, 12);
      expect(replica.samplingElapsedSeconds, 12);
      target.requestTelemetry();
      await target.settled;
      replica.setPresentationActive(true);
      expect(replica.samplingElapsedSeconds, 12);
      main.applySnapshot({
        'samplingPaused': true,
        'samplingClockRunning': false,
        'samplingElapsedSeconds': 12,
      });
      await target.flushState();
      now += 600;
      expect(replica.samplingElapsedSeconds, 12);
      main.applyBackendSamplesCleared();
      await target.flushState();
      expect(replica.samplingElapsedSeconds, 0);
    },
  );
}
