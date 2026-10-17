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
        print(json.dumps({'v': 2, 'id': request['id'], 'error': {
            'code': 'write_failed', 'message': 'readback failed'}}), flush=True)
        continue
    if request['params'].get('defer'):
        pending = request
        continue
    print(json.dumps({'v': 2, 'id': request['id'], 'result': {
        'method': request['method'], 'params': request['params'], 'state': {}}}), flush=True)
    if pending is not None:
        print(json.dumps({'v': 2, 'id': pending['id'], 'result': {
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
