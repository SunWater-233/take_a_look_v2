import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'package:take_a_look_v2/src/models/watch_tree.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;

  test(
    'real ELF array refresh reaches watches and detached windows',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tal_watch_refresh_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = File('${directory.path}/items.c');
      final elf = File('${directory.path}/items.elf');
      Future<bool> build(String declarations, int base) async {
        source.writeAsStringSync(
          '$declarations void _start(void) { for (;;) {} }',
        );
        ProcessResult result;
        try {
          result = await Process.run('arm-none-eabi-gcc', [
            '-g',
            '-gdwarf-4',
            '-O0',
            '-mcpu=cortex-m3',
            '-mthumb',
            '-nostdlib',
            '-Wl,--entry=_start',
            '-Wl,-Ttext=0x08000000',
            '-Wl,-Tbss=0x${base.toRadixString(16)}',
            source.path,
            '-o',
            elf.path,
          ]);
        } on ProcessException {
          markTestSkipped('ARM GCC is optional.');
          return false;
        }
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return true;
      }

      if (!await build(
        'struct Item { int old; float value; }; volatile struct Item items[1];',
        0x20000000,
      )) {
        return;
      }
      final backend = BackendClient(
        processStarter: () => Process.start(
          python.path,
          [
            '-u',
            File('test/fixtures/elf_watch_backend.py').absolute.path,
            directory.path,
          ],
          environment: {
            'PYTHONPATH': Directory('backend').absolute.path,
            'PYTHONUTF8': '1',
          },
        ),
      );
      final c = TakeALookController(backendCommand: backend.command);
      final detached = TakeALookController(remoteCommand: (_, _) async {});
      backend.eventHandler = c.applyBackendEvent;
      addTearDown(() async {
        backend.eventHandler = null;
        await backend.close(force: true);
        detached.dispose();
        c.dispose();
      });
      await backend.start();
      await c.loadFirmware(elf.path);
      expect(c.lastBackendError, isNull);
      final root = c.symbols.firstWhere((s) => s.name == 'items');
      c.selectSymbols([root.key]);
      c.addSelectedToWatch();
      await backend.command(ControllerCommand.setWatches, {
        'watches': [
          for (final w in c.watches)
            {'key': w.symbol.key, 'readMode': 'monitor'},
        ],
      });
      final oldKey = c.watches
          .firstWhere((w) => w.symbol.name == 'items[0].value')
          .symbol
          .key;
      c.setWatchPinned(oldKey, true);
      c.watchInputDrafts[oldKey] = '3.25';
      c.compactExpandedWatches.add(
        c.symbols.firstWhere((s) => s.name == 'items[0]').key,
      );
      await build(
        'struct Item { double value; int added[2]; }; volatile struct Item items[2];',
        0x20000100,
      );
      await c.loadFirmware(elf.path);
      expect(c.lastBackendError, isNull);
      expect(c.watches.map((w) => w.symbol.name).toSet(), {
        'items',
        'items[0]',
        'items[0].value',
        'items[0].added',
        'items[0].added[0]',
        'items[0].added[1]',
        'items[1]',
        'items[1].value',
        'items[1].added',
        'items[1].added[0]',
        'items[1].added[1]',
      });
      final value = c.watches.firstWhere(
        (w) => w.symbol.name == 'items[0].value',
      );
      expect(value.symbol.address, 0x20000100);
      expect(value.symbol.size, 8);
      expect(value.pinned, isTrue);
      expect(c.watchInputDrafts[value.symbol.key], '3.25');
      final tree = buildWatchTree(c.watches).single;
      expect(tree.children.map((n) => n.label), ['[0]', '[1]']);
      expect(
        c.compactExpandedWatches,
        containsAll([
          tree.watch.symbol.key,
          tree.children.first.watch.symbol.key,
        ]),
      );
      detached.applySnapshot(c.stateSnapshot());
      expect(
        detached.watches.map((w) => w.symbol.key),
        c.watches.map((w) => w.symbol.key),
      );
      expect(buildWatchTree(detached.watches).single.children, hasLength(2));
      expect(
        detached.watches
            .firstWhere((w) => w.symbol.name == 'items[0].value')
            .pinned,
        isTrue,
      );
      expect(
        c.watches.every((w) => w.readMode == WatchReadMode.monitor),
        isTrue,
      );
    },
    skip: !python.existsSync() ? 'Run tool/setup_backend first.' : false,
  );
}
