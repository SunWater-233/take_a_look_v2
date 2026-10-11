import 'package:take_a_look_v2/src/controller/controller.dart';

// The baseline runner substitutes legacy encodings for the same operations.
Map<String, dynamic> auditFullSnapshot(TakeALookController controller) =>
    controller.snapshot(packedSamples: true);
Map<String, dynamic> auditTelemetryDelta(
  TakeALookController controller,
  Map<String, int> cursors,
) => controller.telemetryDeltaSnapshot(cursors, packedSamples: true);
Map<String, int> auditStateVersions(TakeALookController controller) =>
    controller.snapshotVersions();
Map<String, dynamic> auditStateDelta(
  TakeALookController controller,
  Map<String, int> versions,
) => controller.stateDeltaSnapshot(versions);
