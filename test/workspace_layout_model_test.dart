import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/workspace/panel_types.dart';
import 'package:take_a_look_v2/src/workspace/workspace_geometry.dart';
import 'package:take_a_look_v2/src/workspace/workspace_layout.dart';
import 'package:take_a_look_v2/src/workspace/workspace_session.dart';

void main() {
  test('workspace layout repository round-trips a validated layout', () async {
    final directory = Directory.systemTemp.createTempSync('tal_layout_model_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final repository = WorkspaceLayoutRepository(
      File('${directory.path}/layout.json'),
    );
    final layout = WorkspaceLayoutSnapshot(
      uiScale: 1.25,
      groups: [
        WorkspaceGroup(
          id: 'main',
          panels: const [WorkspacePanelId.header, WorkspacePanelId.sampling],
          activePanel: WorkspacePanelId.sampling,
          rect: const Rect.fromLTWH(0, 0, 0.4, 0.5),
          z: 3,
        ),
      ],
    );

    await repository.save(layout);
    final restored = await repository.load();
    expect(restored, isNotNull);
    expect(restored!.uiScale, 1.25);
    expect(restored.groups.single.id, 'main');
    expect(restored.groups.single.panels, [
      WorkspacePanelId.header,
      WorkspacePanelId.sampling,
    ]);
    expect(restored.groups.single.activePanel, WorkspacePanelId.sampling);
    expect(restored.groups.single.rect, const Rect.fromLTWH(0, 0, 0.4, 0.5));
  });

  test('workspace group rejects an active panel outside its group', () {
    expect(
      () => WorkspaceGroup.fromJson({
        'id': 'invalid',
        'panels': [WorkspacePanelId.header.name],
        'activePanel': WorkspacePanelId.plot.name,
        'rect': [0, 0, 0.5, 0.5],
        'z': 1,
      }),
      throwsFormatException,
    );
  });

  test('new group IDs do not collide with restored groups', () {
    final session = WorkspaceSession();
    session.groups.addAll([
      for (var index = 100; index <= 101; index++)
        WorkspaceGroup(
          id: 'separated_$index',
          panels: const [WorkspacePanelId.analysis],
          activePanel: WorkspacePanelId.analysis,
          rect: const Rect.fromLTWH(0, 0, 0.5, 0.5),
          z: index,
        ),
    ]);

    expect(session.nextGroupId('separated'), 'separated_102');
    expect(session.nextGroupId('separated'), 'separated_103');
  });

  test('workspace geometry finds and moves a complete shared boundary', () {
    const geometry = WorkspaceGeometry();
    final header = WorkspaceGroup(
      id: 'header',
      panels: const [WorkspacePanelId.header],
      activePanel: WorkspacePanelId.header,
      rect: const Rect.fromLTWH(0, 0, 0.22, 0.18),
      z: 1,
    );
    final symbols = WorkspaceGroup(
      id: 'symbols',
      panels: const [WorkspacePanelId.symbols],
      activePanel: WorkspacePanelId.symbols,
      rect: const Rect.fromLTWH(0, 0.18, 0.22, 0.58),
      z: 2,
    );
    final plot = WorkspaceGroup(
      id: 'plot',
      panels: const [WorkspacePanelId.plot],
      activePanel: WorkspacePanelId.plot,
      rect: const Rect.fromLTWH(0.22, 0, 0.78, 0.76),
      z: 3,
    );
    final groups = [header, symbols, plot];

    final participants = geometry.resizeParticipants(
      groups,
      header,
      horizontal: true,
      movingEnd: true,
    );
    expect(participants.keys, containsAll(groups));
    expect(participants[header], isTrue);
    expect(participants[symbols], isTrue);
    expect(participants[plot], isFalse);

    final delta = geometry.constrainedBoundaryDelta(
      participants,
      0.1,
      horizontal: true,
    );
    for (final entry in participants.entries) {
      entry.key.rect = geometry.moveBoundary(
        entry.key.rect,
        delta,
        horizontal: true,
        movingEnd: entry.value,
      );
    }
    expect(header.rect.right, closeTo(0.32, 0.0001));
    expect(symbols.rect.right, closeTo(0.32, 0.0001));
    expect(plot.rect.left, closeTo(0.32, 0.0001));
  });
}
