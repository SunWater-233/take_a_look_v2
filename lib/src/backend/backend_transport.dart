import 'dart:convert';
import 'dart:typed_data';

final _backendStderrLevelPattern = RegExp(
  r'^\[(DEBUG|INFO|WARNING|ERROR|CRITICAL)\]\s*',
  caseSensitive: false,
);

({String level, String message})? decodeBackendStderrLine(String line) {
  final text = line.trim();
  if (text.isEmpty) return null;
  final match = _backendStderrLevelPattern.firstMatch(text);
  final message = text.substring(match?.end ?? 0);
  if (message.isEmpty) return null;
  return (level: match?.group(1)?.toLowerCase() ?? 'error', message: message);
}

class BackendSampleBatch {
  const BackendSampleBatch({
    required this.schemaId,
    required this.sequence,
    required this.keys,
    required this.elapsedSeconds,
    required this.values,
    required this.validity,
    required this.validityBytesPerFrame,
  });

  final int schemaId;
  final int sequence;
  final List<String> keys;
  final Float64List elapsedSeconds;
  final Float64List values;
  final Uint8List validity;
  final int validityBytesPerFrame;

  int get frameCount => elapsedSeconds.length;
  int get variableCount => keys.length;

  bool hasValue(int frameIndex, int variableIndex) {
    final byte =
        validity[frameIndex * validityBytesPerFrame + variableIndex ~/ 8];
    return byte & (1 << (variableIndex % 8)) != 0;
  }

  double valueAt(int frameIndex, int variableIndex) {
    return values[frameIndex * variableCount + variableIndex];
  }
}

int backendSampleSchemaId(Uint8List payload) {
  if (payload.length < 15) {
    throw const FormatException('Backend sample payload is truncated');
  }
  return ByteData.sublistView(payload).getUint32(1, Endian.little);
}

BackendSampleBatch decodeBackendSamplePayload(
  Uint8List payload,
  List<String> keys,
) {
  if (payload.length < 15) {
    throw const FormatException('Backend sample payload is truncated');
  }
  final data = ByteData.sublistView(payload);
  if (data.getUint8(0) != 1) {
    throw FormatException(
      'Unsupported sample payload version ${data.getUint8(0)}',
    );
  }
  final schemaId = data.getUint32(1, Endian.little);
  final sequence = data.getUint32(5, Endian.little);
  final frameCount = data.getUint32(9, Endian.little);
  final variableCount = data.getUint16(13, Endian.little);
  if (variableCount != keys.length) {
    throw FormatException(
      'Sample schema $schemaId expected ${keys.length} values, got $variableCount',
    );
  }

  final validityBytes = (variableCount + 7) ~/ 8;
  final minimumFrameBytes = 8 + validityBytes;
  if (frameCount > (payload.length - 15) ~/ minimumFrameBytes) {
    throw const FormatException('Backend sample frame count is invalid');
  }
  if (frameCount * variableCount > 16 * 1024 * 1024) {
    throw const FormatException('Backend sample matrix is too large');
  }
  final elapsed = Float64List(frameCount);
  final values = Float64List(frameCount * variableCount);
  final validity = Uint8List(frameCount * validityBytes);
  var offset = 15;
  void requireBytes(int count) {
    if (offset + count > payload.length) {
      throw const FormatException('Backend sample payload is truncated');
    }
  }

  for (var frame = 0; frame < frameCount; frame += 1) {
    requireBytes(8 + validityBytes);
    elapsed[frame] = data.getFloat64(offset, Endian.little);
    offset += 8;
    final frameValidityOffset = frame * validityBytes;
    validity.setRange(
      frameValidityOffset,
      frameValidityOffset + validityBytes,
      payload,
      offset,
    );
    offset += validityBytes;
    for (var variable = 0; variable < variableCount; variable += 1) {
      final present =
          validity[frameValidityOffset + variable ~/ 8] &
              (1 << (variable % 8)) !=
          0;
      if (!present) continue;
      requireBytes(8);
      values[frame * variableCount + variable] = data.getFloat64(
        offset,
        Endian.little,
      );
      offset += 8;
    }
  }
  if (offset != payload.length) {
    throw const FormatException('Backend sample payload has trailing bytes');
  }
  return BackendSampleBatch(
    schemaId: schemaId,
    sequence: sequence,
    keys: List<String>.unmodifiable(keys),
    elapsedSeconds: elapsed,
    values: values,
    validity: validity,
    validityBytesPerFrame: validityBytes,
  );
}

class BackendStreamDecoder {
  BackendStreamDecoder({
    required this.onJsonLine,
    required this.onSamplePayload,
  });

  static const _maxPayloadLength = 64 * 1024 * 1024;

  final void Function(String line) onJsonLine;
  final void Function(Uint8List payload) onSamplePayload;
  Uint8List _buffer = Uint8List(4096);
  int _start = 0;
  int _end = 0;
  int _jsonScan = 0;

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _ensureCapacity(bytes.length);
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;

    while (_start < _end) {
      if (_buffer[_start] == 0) {
        if (_end - _start < 5) break;
        final length = _uint32At(_start + 1);
        if (length > _maxPayloadLength) {
          throw FormatException('Backend frame is too large: $length bytes');
        }
        if (_end - _start < 5 + length) break;
        // sublist already owns its bytes; consumers may retain the payload.
        final payload = _buffer.sublist(_start + 5, _start + 5 + length);
        _start += 5 + length;
        _jsonScan = _start;
        onSamplePayload(payload);
        continue;
      }

      var newline = _jsonScan < _start ? _start : _jsonScan;
      while (newline < _end && _buffer[newline] != 0x0A) {
        newline += 1;
      }
      if (newline == _end) {
        _jsonScan = newline;
        break;
      }
      var lineEnd = newline;
      if (lineEnd > _start && _buffer[lineEnd - 1] == 0x0D) {
        lineEnd -= 1;
      }
      final line = utf8.decode(Uint8List.sublistView(_buffer, _start, lineEnd));
      _start = newline + 1;
      _jsonScan = _start;
      if (line.trim().isNotEmpty) onJsonLine(line);
    }
    _compactIfNeeded();
  }

  void reset() {
    _start = 0;
    _end = 0;
    _jsonScan = 0;
  }

  int _uint32At(int offset) {
    return _buffer[offset] |
        (_buffer[offset + 1] << 8) |
        (_buffer[offset + 2] << 16) |
        (_buffer[offset + 3] << 24);
  }

  void _ensureCapacity(int additionalBytes) {
    final required = _end + additionalBytes;
    if (required <= _buffer.length) return;
    if (_start > 0) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _jsonScan -= _start;
      _start = 0;
    }
    if (_end + additionalBytes <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < _end + additionalBytes) {
      capacity *= 2;
    }
    final expanded = Uint8List(capacity)..setRange(0, _end, _buffer);
    _buffer = expanded;
  }

  void _compactIfNeeded() {
    if (_start == _end) {
      reset();
    } else if (_start > _buffer.length ~/ 2) {
      _buffer.setRange(0, _end - _start, _buffer, _start);
      _end -= _start;
      _jsonScan -= _start;
      _start = 0;
    }
  }
}
