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
  sourceWorkspace,
  sourceTools,
}

/// A field's wire name, revision ownership, and project inclusion live together.
enum SnapshotField {
  freeRtos({SnapshotDomain.freeRtos}),
  freeRtosSettings({SnapshotDomain.freeRtos}, persistInProject: true),
  connectionStatus({SnapshotDomain.connection}),
  probeType({SnapshotDomain.connection}, persistInProject: true),
  targetName({SnapshotDomain.connection}, persistInProject: true),
  targetPackId({SnapshotDomain.connection}, persistInProject: true),
  targetPartNumber({SnapshotDomain.connection}),
  targetPackLabel({SnapshotDomain.connection}),
  targetPackMissing({SnapshotDomain.connection}),
  targetCatalogRevision({SnapshotDomain.targetCatalog}),
  swdClock({SnapshotDomain.connection}, persistInProject: true),
  serialNumber({SnapshotDomain.connection}, persistInProject: true),
  connectionKind({SnapshotDomain.connection}, persistInProject: true),
  connectionCapabilities({SnapshotDomain.connection}),
  gatewayProtocolVersion({SnapshotDomain.connection}),
  remoteConfig({SnapshotDomain.connection}, persistInProject: true),
  firmware({SnapshotDomain.symbols, SnapshotDomain.debug}),
  symbolLoad({}),
  sampleRateHz({SnapshotDomain.sampling}, persistInProject: true),
  monitorRateHz({SnapshotDomain.sampling}, persistInProject: true),
  rttSampleRateHz({SnapshotDomain.sampling}, persistInProject: true),
  displayRefreshMode({SnapshotDomain.plot}, persistInProject: true),
  samplingElapsedSeconds({}, alwaysRevised: true),
  samplingClockRunning({SnapshotDomain.sampling}),
  samplingEpoch({SnapshotDomain.sampling}),
  elapsedSeconds({}, alwaysRevised: true),
  samplingPaused({SnapshotDomain.sampling}, persistInProject: true),
  rawRecording({SnapshotDomain.sampling}),
  plottingPaused({SnapshotDomain.plot}, persistInProject: true),
  plotVisibilityBeforeIsolation({SnapshotDomain.watches}),
  plotHighlightedWatchKey({SnapshotDomain.plot}),
  plotWatchSelectionRevision({SnapshotDomain.plot}),
  rttEnabled({SnapshotDomain.sampling}, persistInProject: true),
  rttProtocol({SnapshotDomain.sampling}, persistInProject: true),
  followLatest({SnapshotDomain.plot}, persistInProject: true),
  plotVisibleWindowSeconds({SnapshotDomain.plot}, persistInProject: true),
  plotRetentionSeconds({SnapshotDomain.plot}, persistInProject: true),
  plotAutoY({SnapshotDomain.plot}, persistInProject: true),
  plotYMin({SnapshotDomain.plot}, persistInProject: true),
  plotYMax({SnapshotDomain.plot}, persistInProject: true),
  plotShowGrid({SnapshotDomain.plot}, persistInProject: true),
  plotShowLegend({SnapshotDomain.plot}, persistInProject: true),
  plotMouseXEnabled({SnapshotDomain.plot}, persistInProject: true),
  plotMouseYEnabled({SnapshotDomain.plot}, persistInProject: true),
  plotInvertX({SnapshotDomain.plot}, persistInProject: true),
  plotInvertY({SnapshotDomain.plot}, persistInProject: true),
  plotWindowEndSeconds({SnapshotDomain.plot}),
  uiScale({}, persistInProject: true, alwaysRevised: true),
  lastBackendError({SnapshotDomain.connection}),
  selectedSymbols({SnapshotDomain.symbols}, persistInProject: true),
  symbols({}, persistInProject: true),
  watches({SnapshotDomain.watches}, persistInProject: true),
  canUndoWatchDeletion({SnapshotDomain.watches}),
  canRedoWatchDeletion({SnapshotDomain.watches}),
  logs({SnapshotDomain.logs}),
  analysisSession({SnapshotDomain.analysis}, persistInProject: true),
  sourceWorkspace({SnapshotDomain.sourceWorkspace}, persistInProject: true),
  sourceProject({
    SnapshotDomain.sourceTools,
    SnapshotDomain.symbols,
    SnapshotDomain.debug,
  }, persistInProject: true),
  sourceTask({SnapshotDomain.sourceTools}),
  debug({SnapshotDomain.debug});

  const SnapshotField(
    this.revisedBy, {
    this.persistInProject = false,
    this.alwaysRevised = false,
  });

  final Set<SnapshotDomain> revisedBy;
  final bool persistInProject;
  final bool alwaysRevised;

  static final Map<String, SnapshotField> byWireName = Map.unmodifiable({
    for (final field in values) field.name: field,
  });
}

class ControllerSnapshotSchema {
  static final Set<String> fields = Set.unmodifiable({
    for (final field in SnapshotField.values) field.name,
  });
  static final Set<String> projectFields = Set.unmodifiable({
    for (final field in SnapshotField.values)
      if (field.persistInProject) field.name,
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
