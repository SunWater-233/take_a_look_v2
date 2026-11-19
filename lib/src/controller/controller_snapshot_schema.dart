/// State domains that revise the main/detached-window snapshot contract.
enum SnapshotDomain {
  freeRtos,
  connection,
  sampling,
  targetCatalog,
  symbols,
  watches,
  plot,
  logs,
  analysis,
  debug,
  debugIndex,
  sourceWorkspace,
  sourceProject,
  sourceTools,
}

/// A field's wire name, revision ownership describes the window synchronization contract.
enum SnapshotField {
  freeRtos({SnapshotDomain.freeRtos}),
  freeRtosSettings({SnapshotDomain.freeRtos}),
  connectionStatus({SnapshotDomain.connection}),
  probeType({SnapshotDomain.connection}),
  targetName({SnapshotDomain.connection}),
  targetPackId({SnapshotDomain.connection}),
  targetPartNumber({SnapshotDomain.connection}),
  targetPackLabel({SnapshotDomain.connection}),
  targetPackMissing({SnapshotDomain.connection}),
  targetCatalogRevision({SnapshotDomain.targetCatalog}),
  swdClock({SnapshotDomain.connection}),
  serialNumber({SnapshotDomain.connection}),
  connectionKind({SnapshotDomain.connection}),
  connectionCapabilities({SnapshotDomain.connection}),
  gatewayProtocolVersion({SnapshotDomain.connection}),
  remoteConfig({SnapshotDomain.connection}),
  firmware({SnapshotDomain.symbols, SnapshotDomain.debug}),
  symbolLoad({}),
  sampleRateHz({SnapshotDomain.sampling}),
  memoryOverclock({SnapshotDomain.sampling}),
  memoryPipelineDepth({SnapshotDomain.sampling}),
  monitorRateHz({SnapshotDomain.sampling}),
  rttSampleRateHz({SnapshotDomain.sampling}),
  displayRefreshMode({SnapshotDomain.plot}),
  samplingElapsedSeconds({}, alwaysRevised: true),
  samplingClockRunning({SnapshotDomain.sampling}),
  samplingEpoch({SnapshotDomain.sampling}),
  preserveMissingHistory({SnapshotDomain.sampling}),
  elapsedSeconds({}, alwaysRevised: true),
  samplingPaused({SnapshotDomain.sampling}),
  rawRecording({SnapshotDomain.sampling}),
  plottingPaused({SnapshotDomain.plot}),
  plotVisibilityBeforeIsolation({SnapshotDomain.watches}),
  plotHighlightedWatchKey({SnapshotDomain.plot}),
  plotWatchSelectionRevision({SnapshotDomain.plot}),
  rttEnabled({SnapshotDomain.sampling}),
  rttProtocol({SnapshotDomain.sampling}),
  followLatest({SnapshotDomain.plot}),
  plotVisibleWindowSeconds({SnapshotDomain.plot}),
  plotRetentionSeconds({SnapshotDomain.plot}),
  plotAutoY({SnapshotDomain.plot}),
  plotYMin({SnapshotDomain.plot}),
  plotYMax({SnapshotDomain.plot}),
  plotShowGrid({SnapshotDomain.plot}),
  plotShowLegend({SnapshotDomain.plot}),
  plotMouseXEnabled({SnapshotDomain.plot}),
  plotMouseYEnabled({SnapshotDomain.plot}),
  plotInvertX({SnapshotDomain.plot}),
  plotInvertY({SnapshotDomain.plot}),
  plotWindowEndSeconds({SnapshotDomain.plot}),
  plotTimeOverscroll({SnapshotDomain.plot}),
  uiScale({}, alwaysRevised: true),
  lastBackendError({SnapshotDomain.connection}),
  selectedSymbols({SnapshotDomain.symbols}),
  symbols({}),
  watches({SnapshotDomain.watches}),
  canUndoWatchDeletion({SnapshotDomain.watches}),
  canRedoWatchDeletion({SnapshotDomain.watches}),
  logs({SnapshotDomain.logs}),
  analysisSession({SnapshotDomain.analysis}),
  sourceWorkspace({SnapshotDomain.sourceWorkspace}),
  sourceProject({SnapshotDomain.sourceProject}),
  sourceTask({SnapshotDomain.sourceTools}),
  debugIndex({SnapshotDomain.debugIndex}),
  debug({SnapshotDomain.debug});

  const SnapshotField(this.revisedBy, {this.alwaysRevised = false});

  final Set<SnapshotDomain> revisedBy;
  final bool alwaysRevised;

  static final Map<String, SnapshotField> byWireName = Map.unmodifiable({
    for (final field in values) field.name: field,
  });
}

class ControllerSnapshotSchema {
  static final Set<String> fields = Set.unmodifiable({
    for (final field in SnapshotField.values) field.name,
  });

  static bool containsDomain(
    Map<String, Object?> data,
    SnapshotDomain domain, {
    Set<SnapshotField> except = const {},
    Set<SnapshotField> include = const {},
  }) => SnapshotField.values.any(
    (field) =>
        !except.contains(field) &&
        (field.revisedBy.contains(domain) || include.contains(field)) &&
        data.containsKey(field.name),
  );
}

/// Revision bookkeeping has no dependency on a controller or UI notifier.
class SnapshotRevisions {
  final Map<SnapshotField, int> _fields = {};
  int _revision = 0;

  int revisionOf(SnapshotField field) => _fields[field] ?? 0;

  void touch(Iterable<String> fields) {
    final revision = ++_revision;
    for (final name in fields) {
      final field = SnapshotField.byWireName[name];
      if (field != null) _fields[field] = revision;
    }
  }

  void record(Set<SnapshotDomain> domains) => touch([
    for (final field in SnapshotField.values)
      if (field.alwaysRevised || field.revisedBy.any(domains.contains))
        field.name,
  ]);

  Map<String, int> versions({required int symbolRevision}) => {
    for (final field in SnapshotField.values)
      field.name: field == SnapshotField.symbols
          ? symbolRevision
          : revisionOf(field),
  };
}
