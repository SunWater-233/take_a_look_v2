part of 'controller.dart';

extension TakeALookControllerAnalysis on TakeALookController {
  /// Publishes mutations made to [analysisSession].
  ///
  /// Dataset changes include point data exactly once. Ordinary viewport and
  /// selection changes use the compact session representation.
  void commitAnalysisSession({bool includeData = false}) {
    if (_isDetachedRemote) {
      _emitState([signals.analysis], sync: false);
      _dispatchRemote(
        ControllerCommand.updateAnalysisSession,
        analysisSession.toJson(includeData: includeData),
      );
      return;
    }
    _emitState([signals.analysis]);
  }

  void applyAnalysisSession(Map<String, dynamic> values) {
    analysisSession.applyJson(values);
    _emitState([signals.analysis]);
  }
}
