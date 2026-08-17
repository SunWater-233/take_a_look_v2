import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:take_a_look_v2/src/backend_client.dart';

void main() {
  test(
    'stream decoder handles interleaved JSON and fragmented binary frames',
    () {
      final jsonLines = <String>[];
      final payloads = <Uint8List>[];
      final decoder = BackendStreamDecoder(
        onJsonLine: jsonLines.add,
        onSamplePayload: payloads.add,
      );
      final payload = _samplePayload();
      final frameHeader = ByteData(5)
        ..setUint8(0, 0)
        ..setUint32(1, payload.length, Endian.little);
      final wire = <int>[
      ...utf8.encode('{"v":2,"event":"sampleSchema"}\n'),
        ...frameHeader.buffer.asUint8List(),
        ...payload,
      ...utf8.encode('{"v":2,"id":4,"result":{}}\n'),
      ];

      var offset = 0;
      for (final size in [1, 2, 7, 3, 19, 5, 64]) {
        if (offset >= wire.length) break;
        final end = (offset + size).clamp(0, wire.length);
        decoder.add(wire.sublist(offset, end));
        offset = end;
      }
      if (offset < wire.length) decoder.add(wire.sublist(offset));

      expect(jsonLines, hasLength(2));
      expect(payloads, hasLength(1));
      final batch = decodeBackendSamplePayload(payloads.single, [
        'speed',
        'enabled',
      ]);
      expect(batch.schemaId, 7);
      expect(batch.sequence, 11);
      expect(batch.elapsedSeconds, [0.25, 0.5]);
      expect(batch.hasValue(0, 0), isTrue);
      expect(batch.hasValue(0, 1), isTrue);
      expect(batch.valueAt(0, 0), 12.5);
      expect(batch.valueAt(0, 1), 1.0);
      expect(batch.hasValue(1, 0), isFalse);
      expect(batch.hasValue(1, 1), isTrue);
      expect(batch.valueAt(1, 1), 0.0);
    },
  );

  test('sample decoder rejects a schema mismatch and truncated payload', () {
    final payload = _samplePayload();
    expect(
      () => decodeBackendSamplePayload(payload, ['speed']),
      throwsFormatException,
    );
    expect(
      () => decodeBackendSamplePayload(payload.sublist(0, payload.length - 1), [
        'speed',
        'enabled',
      ]),
      throwsFormatException,
    );
  });
}

Uint8List _samplePayload() {
  final bytes = BytesBuilder(copy: false);
  final header = ByteData(15)
    ..setUint8(0, 1)
    ..setUint32(1, 7, Endian.little)
    ..setUint32(5, 11, Endian.little)
    ..setUint32(9, 2, Endian.little)
    ..setUint16(13, 2, Endian.little);
  bytes.add(header.buffer.asUint8List());
  bytes.add(_frame(0.25, 0x03, [12.5, 1.0]));
  bytes.add(_frame(0.5, 0x02, [0.0]));
  return bytes.takeBytes();
}

Uint8List _frame(double elapsed, int validity, List<double> values) {
  final data = ByteData(9 + values.length * 8)
    ..setFloat64(0, elapsed, Endian.little)
    ..setUint8(8, validity);
  for (var index = 0; index < values.length; index += 1) {
    data.setFloat64(9 + index * 8, values[index], Endian.little);
  }
  return data.buffer.asUint8List();
}
