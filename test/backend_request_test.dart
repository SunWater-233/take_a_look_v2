import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend/backend_client.dart';
import 'package:take_a_look_v2/src/protocol/commands.dart';

void main() {
  final python = File(
    Platform.isWindows
        ? 'backend/.venv/Scripts/python.exe'
        : 'backend/.venv/bin/python',
  ).absolute;
  final skip = !python.existsSync() ? 'Run tool/setup_backend first.' : false;

  test('startup requests wait for one process and its handshake', () async {
    final launch = Completer<void>();
    final errors = <Object?>[];
    var starts = 0;
    final client = BackendClient(
      eventHandler: (event, params) {
        if (event.name == 'error') errors.add(params);
      },
      processStarter: () async {
        starts++;
        await launch.future;
        return Process.start(python.path, [
          '-u',
          '-c',
          '''
import json, sys, time
history = []
for line in sys.stdin:
    request = json.loads(line)
    history.append(request['method'])
    if request['method'] == 'handshake':
        time.sleep(0.1)
    print(json.dumps({'v': 3, 'id': request['id'], 'result': {
        'state': {}, 'history': history}}), flush=True)
    if request['method'] == 'shutdown':
        break
''',
        ]);
      },
    );
    addTearDown(() => client.close(force: true));
    final first = client.start();
    final second = client.start();
    final catalog = client.targetCatalogRequest('listTargets', {});
    final command = client.command(ControllerCommand.setSampleRate, 200);
    final project = client.projectCommand(ControllerCommand.configureProject, {
      'monitorRateHz': 5,
    });
    expect(starts, 1);
    launch.complete();
    await Future.wait([first, second, catalog, command, project]);
    final state = await client.request(BackendMethod.getState);
    expect(state['history'], [
      'handshake',
      'listTargets',
      'setConfig',
      'setConfig',
      'getState',
    ]);
    expect(errors, isEmpty);
    expect(starts, 1);
  }, skip: skip);

  Future<BackendClient> startClient() async {
    final client = BackendClient(
      processStarter: () => Process.start(python.path, [
        '-u',
        '-c',
        '''
import json, sys
pending = None
for line in sys.stdin:
    request = json.loads(line)
    if request['method'] == 'writeWatch':
        print(json.dumps({'v': 3, 'id': request['id'], 'error': {
            'code': 'write_failed', 'message': 'readback failed'}}), flush=True)
        continue
    if request['params'].get('defer'):
        pending = request
        continue
    print(json.dumps({'v': 3, 'id': request['id'], 'result': {
        'method': request['method'], 'params': request['params'], 'state': {}}}), flush=True)
    if pending is not None:
        print(json.dumps({'v': 3, 'id': pending['id'], 'result': {
            'method': pending['method'], 'params': pending['params']}}), flush=True)
        pending = None
    if request['method'] == 'shutdown':
        break
''',
      ]),
    );
    addTearDown(() => client.close(force: true));
    await client.start();
    expect(client.isRunning, isTrue);
    return client;
  }

  Future<BackendClient> startBatchClient() async {
    final client = BackendClient(
      processStarter: () => Process.start(python.path, [
        '-u',
        '-c',
        '''
import json, sys
history = []
for line in sys.stdin:
    request = json.loads(line)
    method, params = request['method'], request['params']
    history.append({'method': method, 'params': params})
    entries = params.get('writes', [params]) if method in ('writeWatch', 'writeWatches') else []
    if any(entry.get('value') == 'fail' for entry in entries):
        reply = {'error': {'code': 'write_failed', 'message': 'readback failed'}}
    else:
        reply = {'result': {'capabilities': ['memoryWriteBatch'], 'state': {}, 'history': history}}
    print(json.dumps({'v': 3, 'id': request['id'], **reply}), flush=True)
    if method == 'shutdown':
        break
''',
      ]),
    );
    addTearDown(() => client.close(force: true));
    await client.start();
    return client;
  }

  test(
    'concurrent explicit writes use one batch and retain each value',
    () async {
      final client = await startBatchClient();
      await Future.wait([
        client.command(ControllerCommand.writeWatch, {
          'key': 'a',
          'value': '1',
        }),
        client.command(ControllerCommand.writeWatch, {
          'key': 'b',
          'value': '2',
        }),
      ]);
      final result = await client.request(BackendMethod.getState);
      final history = result['history'] as List;
      expect(history.map((item) => item['method']), [
        'handshake',
        'writeWatches',
        'getState',
      ]);
      expect(history[1]['params']['writes'], [
        {'key': 'a', 'value': '1'},
        {'key': 'b', 'value': '2'},
      ]);
    },
    skip: skip,
  );

  test(
    'repeated explicit writes are never discarded and controls cannot overtake them',
    () async {
      final client = await startBatchClient();
      final first = client.command(ControllerCommand.writeWatch, {
        'key': 'a',
        'value': '1',
      });
      final second = client.command(ControllerCommand.writeWatch, {
        'key': 'a',
        'value': '1',
      });
      final state = client.request(BackendMethod.getState);
      await Future.wait([first, second]);
      final history = (await state)['history'] as List;
      expect(history.map((item) => item['method']), [
        'handshake',
        'writeWatch',
        'writeWatch',
        'getState',
      ]);
    },
    skip: skip,
  );

  test(
    'a rejected batch fails every caller and later explicit writes still work',
    () async {
      final client = await startBatchClient();
      await expectLater(
        Future.wait([
          client.command(ControllerCommand.writeWatch, {
            'key': 'a',
            'value': '1',
          }),
          client.command(ControllerCommand.writeWatch, {
            'key': 'b',
            'value': 'fail',
          }),
        ]),
        throwsA(isA<BackendException>()),
      );
      await client.command(ControllerCommand.writeWatch, {
        'key': 'c',
        'value': '3',
      });
      final result = await client.request(BackendMethod.getState);
      expect((result['history'] as List).map((item) => item['method']), [
        'handshake',
        'writeWatches',
        'writeWatch',
        'getState',
      ]);
    },
    skip: skip,
  );

  test('large bursts are bounded to 64 writes per batch', () async {
    final client = await startBatchClient();
    await Future.wait([
      for (var i = 0; i < 65; i++)
        client.command(ControllerCommand.writeWatch, {
          'key': 'v$i',
          'value': '$i',
        }),
    ]);
    final result = await client.request(BackendMethod.getState);
    final history = result['history'] as List;
    expect(history.map((item) => item['method']), [
      'handshake',
      'writeWatches',
      'writeWatch',
      'getState',
    ]);
    expect(history[1]['params']['writes'], hasLength(64));
    expect(history[2]['params'], {'key': 'v64', 'value': '64'});
  }, skip: skip);

  test(
    'concurrent requests all reach stdin and receive their own response',
    () async {
      final client = await startClient();
      final responses = await Future.wait([
        for (var i = 0; i < 12; i++)
          client.request(BackendMethod.listTargets, {'token': i}),
      ]).timeout(const Duration(seconds: 3));
      expect(
        responses.map((response) => (response['params'] as Map)['token']),
        List.generate(12, (i) => i),
      );
    },
    skip: skip,
  );

  test(
    'waiting for a slow response does not block sending other commands',
    () async {
      final client = await startClient();
      final completed = <String>[];
      final slow = client
          .request(BackendMethod.listTargets, {'defer': true})
          .then((_) => completed.add('slow'));
      final fast = client
          .request(BackendMethod.getState)
          .then((_) => completed.add('fast'));
      await Future.wait([slow, fast]).timeout(const Duration(seconds: 3));
      expect(completed, ['fast', 'slow']);
    },
    skip: skip,
  );

  test(
    'a failed write completes immediately and does not poison later writes',
    () async {
      final client = await startClient();
      await expectLater(
        client
            .request(BackendMethod.listTargets, {'invalid': Object()})
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      final response = await client
          .request(BackendMethod.getState)
          .timeout(const Duration(seconds: 1));
      expect(response['method'], 'getState');
    },
    skip: skip,
  );
  test(
    'writeWatch command propagates backend rejection to its caller',
    () async {
      final client = await startClient();
      await expectLater(
        client.command(ControllerCommand.writeWatch, {
          'key': 'watch',
          'value': '1',
        }),
        throwsA(isA<BackendException>()),
      );
    },
    skip: skip,
  );
}
