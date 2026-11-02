import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  TakeALookController fixture() {
    final controller = TakeALookController(backendCommand: (_, _) async {})
      ..loadDemoSymbols();
    controller.selectSymbols(demoSymbols.take(3).map((s) => s.key));
    controller.addSelectedToWatch();
    controller.setAllWatchesPlotted(true);
    addTearDown(controller.dispose);
    return controller;
  }

  test('repeated isolation restores original visibility and read modes', () {
    final c = fixture();
    final keys = c.watches.map((w) => w.symbol.key).toList();
    c.toggleWatchPlot(keys[1], false);
    c.isolateWatchPlots([keys[1]]);
    expect(c.watchPlotsIsolated, isTrue);
    expect(c.watches.map((w) => w.plotted), [false, true, false]);
    final revisions = c.snapshotVersions();
    c.configurePlotView({'plotShowGrid': false});
    expect(
      c.stateDeltaSnapshot(revisions),
      isNot(contains('plotVisibilityBeforeIsolation')),
    );
    c.isolateWatchPlots([keys[2]]);
    expect(c.watches.map((w) => w.plotted), [false, false, true]);
    expect(c.watches.every((w) => w.readMode == WatchReadMode.capture), isTrue);
    c.exitWatchPlotIsolation();
    expect(c.watchPlotsIsolated, isFalse);
    expect(c.watches.map((w) => w.plotted), [true, false, true]);
    c.exitWatchPlotIsolation();
    expect(c.watches.map((w) => w.plotted), [true, false, true]);
  });

  test('exit restores retained deletions and newly added curves', () {
    final c = fixture();
    final keys = c.watches.map((w) => w.symbol.key).toList();
    c.isolateWatchPlots([keys[0]]);
    c.removeWatch(keys[1]);
    c.selectSymbols([demoSymbols[3].key]);
    c.addSelectedToWatch();
    expect(c.watches.last.plotted, isFalse);
    c.exitWatchPlotIsolation();
    c.undoWatchDeletion();
    expect(c.watches, hasLength(4));
    expect(c.watches.map((w) => w.plotted), [true, true, true, false]);
  });

  test('manual members cannot start isolation or become plotted on exit', () {
    final c = fixture();
    final keys = c.watches.map((w) => w.symbol.key).toList();
    c.setWatchReadMode(keys[1], WatchReadMode.manual);
    c.isolateWatchPlots([keys[1], 'missing']);
    expect(c.watchPlotsIsolated, isFalse);
    c.isolateWatchPlots([keys[0]]);
    c.setWatchReadMode(keys[2], WatchReadMode.manual);
    expect(
      (c.projectSettings()['watches'] as List).map((raw) => raw['plotted']),
      [true, false, false],
    );
    c.exitWatchPlotIsolation();
    expect(c.watches.map((w) => w.plotted), [true, false, false]);
    expect(c.watches[1].readMode, WatchReadMode.manual);
    expect(c.watches[2].readMode, WatchReadMode.manual);
  });

  test(
    'projects save the visibility from before temporary isolation',
    () async {
      final c = fixture();
      c.symbolFile = '';
      final keys = c.watches.map((w) => w.symbol.key).toList();
      c.toggleWatchPlot(keys[1], false);
      c.isolateWatchPlots([keys[1]]);
      final settings = c.projectSettings();
      expect((settings['watches'] as List).map((raw) => raw['plotted']), [
        true,
        false,
        true,
      ]);
      expect(c.watches.map((w) => w.plotted), [false, true, false]);
      await c.restoreProjectSettings(settings);
      expect(c.watchPlotsIsolated, isFalse);
      expect(c.watches.map((w) => w.plotted), [true, false, true]);
    },
  );

  test(
    'detached windows share isolation and can restore it with one command',
    () async {
      final main = fixture();
      final keys = main.watches.map((w) => w.symbol.key).toList();
      final commands = <ControllerCommand>[];
      late final TakeALookController detached;
      detached = TakeALookController(
        remoteCommand: (command, arguments) async {
          commands.add(command);
          detached.applySnapshot(await main.handleCommand(command, arguments));
        },
      );
      addTearDown(detached.dispose);
      detached.applySnapshot(main.stateSnapshot());
      final revisions = main.snapshotVersions();
      detached.isolateWatchPlots([keys[0]]);
      await Future<void>.delayed(Duration.zero);
      expect(main.watchPlotsIsolated, isTrue);
      expect(detached.watchPlotsIsolated, isTrue);
      expect(detached.watches.map((w) => w.plotted), [true, false, false]);
      expect(
        main.stateDeltaSnapshot(revisions),
        contains('plotVisibilityBeforeIsolation'),
      );
      // A newly opened window must also be able to exit an existing isolation.
      final other = TakeALookController()..applySnapshot(main.stateSnapshot());
      addTearDown(other.dispose);
      expect(other.watchPlotsIsolated, isTrue);
      detached.exitWatchPlotIsolation();
      await Future<void>.delayed(Duration.zero);
      expect(main.watchPlotsIsolated, isFalse);
      expect(detached.watchPlotsIsolated, isFalse);
      expect(detached.watches.every((w) => w.plotted), isTrue);
      expect(commands, [
        ControllerCommand.isolateWatchPlots,
        ControllerCommand.exitWatchPlotIsolation,
      ]);
    },
  );
}
