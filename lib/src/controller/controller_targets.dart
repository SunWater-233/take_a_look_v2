part of 'controller.dart';

extension TakeALookControllerTargets on TakeALookController {
  String get targetPackId => state.connection.targetPackId;
  String get targetPartNumber => state.connection.targetPartNumber;
  String get targetPackLabel => state.connection.targetPackLabel;
  bool get targetPackMissing => state.connection.targetPackMissing;
  int get targetCatalogRevision => state.connection.targetCatalogRevision;
  Listenable get targetCatalogChanges => signals.targetCatalog;

  Future<JsonObject> requestTargetCatalog(
    String operation, [
    JsonObject arguments = const {},
  ]) async {
    final request = targetCatalogRequest;
    if (request == null) {
      throw const BackendException('backend_unavailable', '请启动本机硬件后端后再管理芯片。');
    }
    final result = await request(operation, arguments);
    if (!_disposed) {
      if (result['state'] case final Map patch) {
        applySnapshot(Map<String, Object?>.from(patch));
        signals.stateSync.emit();
      }
    }
    return result;
  }
}
