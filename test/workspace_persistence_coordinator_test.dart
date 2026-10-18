import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/project_document.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';
import 'package:take_a_look_v2/src/workspace/workspace_persistence.dart';

WorkspaceLayoutSnapshot _layout(String id) => WorkspaceLayoutSnapshot(
  version: 4,
  uiScale: 1,
  groups: [
    WorkspaceGroup(
      id: id,
      panels: [WorkspacePanelId.plot],
      activePanel: WorkspacePanelId.plot,
      rect: const Rect.fromLTWH(0, 0, 1, 1),
      z: 1,
    ),
  ],
);

class _Repository extends WorkspaceLayoutRepository {
  _Repository({this.onSave, this.onLoad}) : super(File('unused-layout.json'));

  final Future<void> Function(WorkspaceLayoutSnapshot)? onSave;
  final Future<WorkspaceLayoutSnapshot?> Function()? onLoad;

  @override
  Future<void> save(WorkspaceLayoutSnapshot layout) async =>
      onSave?.call(layout);

  @override
  Future<WorkspaceLayoutSnapshot?> load() async => onLoad?.call();
}

void main() {
  test(
    'queued writes freeze snapshots and recover after an earlier failure',
    () async {
      final firstGate = Completer<void>();
      final written = <WorkspaceLayoutSnapshot>[];
      final repository = _Repository(
        onSave: (layout) async {
          written.add(layout);
          if (written.length == 1) await firstGate.future;
        },
      );
      final persistence = WorkspacePersistence(
        layoutRepository: () => repository,
      );
      addTearDown(persistence.dispose);
      final live = _layout('main');
      final first = persistence.saveLayout(live);
      final failed = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      live.groups.single.rect = const Rect.fromLTWH(0, 0, .5, .5);
      final second = persistence.saveLayout(live);
      live.groups.single.rect = const Rect.fromLTWH(0, 0, .3, .3);
      expect(written, hasLength(1));
      firstGate.completeError(StateError('disk unavailable'));
      await failed;
      await second;
      expect(written.map((s) => s.groups.single.rect), [
        const Rect.fromLTWH(0, 0, 1, 1),
        const Rect.fromLTWH(0, 0, .5, .5),
      ]);
    },
  );

  test(
    'newer restores supersede older reads and disposal suppresses completion',
    () async {
      final reads = <Completer<WorkspaceLayoutSnapshot?>>[];
      final repository = _Repository(
        onLoad: () {
          final read = Completer<WorkspaceLayoutSnapshot?>();
          reads.add(read);
          return read.future;
        },
      );
      final persistence = WorkspacePersistence(
        layoutRepository: () => repository,
      );
      final applied = <String>[];
      void apply(WorkspaceLayoutSnapshot? layout) =>
          applied.add(layout!.groups.single.id);
      final older = persistence.restoreLayout(apply);
      final newer = persistence.restoreLayout(apply);
      reads[1].complete(_layout('new'));
      await newer;
      reads[0].complete(_layout('old'));
      await older;
      expect(applied, ['new']);
      final closing = persistence.restoreLayout(apply);
      persistence.dispose();
      reads[2].complete(_layout('closed'));
      await closing;
      expect(applied, ['new']);
    },
  );

  test('opening a project invalidates a pending startup layout read', () async {
    final directory = Directory.systemTemp.createTempSync(
      'tal_project_restore_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final controller = TakeALookController(backendCommand: (_, _) async {});
    addTearDown(controller.dispose);
    final document = ProjectDocument(
      settings: controller.projectSettings(),
      layout: _layout('project'),
    );
    final file = File('${directory.path}/restored.talproj');
    await document.write(file);
    final startup = Completer<WorkspaceLayoutSnapshot?>();
    final repository = _Repository(onLoad: () => startup.future);
    final persistence = WorkspacePersistence(
      layoutRepository: () => repository,
    );
    addTearDown(persistence.dispose);
    final applied = <String>[];
    final pending = persistence.restoreLayout(
      (layout) => applied.add('startup'),
    );
    await persistence.openProject(
      pickPath: () async => file.path,
      isActive: () => true,
      apply: (loaded) async {
        applied.add(loaded.layout.groups.single.id);
        return true;
      },
    );
    startup.complete(_layout('startup'));
    await pending;
    expect(applied, ['project']);
    expect(persistence.projectPath, file.path);
  });

  test(
    'project pickers are serialized and a closing window cannot save',
    () async {
      final persistence = WorkspacePersistence(
        layoutRepository: () => _Repository(),
      );
      final picker = Completer<String?>();
      var pickerCalls = 0;
      Future<String?> pick() {
        pickerCalls++;
        return picker.future;
      }

      final first = persistence.saveProject(
        pickPath: pick,
        isActive: () => true,
        capture: () => throw StateError('capture after disposal'),
      );
      final second = await persistence.saveProject(
        pickPath: pick,
        isActive: () => true,
        capture: () => throw StateError('duplicate capture'),
      );
      expect(second, isNull);
      expect(pickerCalls, 1);
      persistence.dispose();
      picker.complete('closed-window.talproj');
      expect(await first, isNull);
      expect(persistence.projectPath, isNull);
    },
  );

  testWidgets('autosave debounce is cancelled when its owner is disposed', (
    tester,
  ) async {
    final persistence = WorkspacePersistence(
      layoutRepository: () => _Repository(),
    );
    var saves = 0;
    Future<void> save() async => saves++;
    persistence.scheduleLayoutSave(save);
    await tester.pump(const Duration(milliseconds: 400));
    persistence.scheduleLayoutSave(save);
    await tester.pump(const Duration(milliseconds: 499));
    expect(saves, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(saves, 1);
    persistence.scheduleLayoutSave(save);
    persistence.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(saves, 1);
  });
}
