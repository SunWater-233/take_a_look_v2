import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Append-only acquisition journal, independent of all plot buffers. Channel
/// IDs keep high-rate batches compact; every file contains its own schema.
/// Writes go to the OS in batches, with fsync at export/rotation/close. CSV
/// conversion streams a fixed file prefix on a worker isolate.
class RawSampleRecording {
  RawSampleRecording(this.directory);

  /// Portable recordings live beside the application, independent of its
  /// working directory or Python installation. System installers can select a
  /// writable per-user location through TAL_RECORDINGS_DIR.
  static Directory get defaultDirectory {
    final configured = Platform.environment['TAL_RECORDINGS_DIR'];
    if (configured != null && configured.isNotEmpty) {
      return Directory(configured);
    }
    return Directory(
      '${File(Platform.resolvedExecutable).parent.path}/recordings',
    );
  }

  final Directory directory;
  RandomAccessFile? _file;
  String? path;
  final Map<String, int> _ids = {};
  final List<Map<String, String>> _channels = [];
  int sampleCount = 0;
  int _committedBytes = 0;
  Object? failure;
  bool _closed = false;

  Map<String, Object?> get status => {
    'path': path,
    'sampleCount': sampleCount,
    'bytes': _committedBytes,
    if (failure != null) 'error': failure.toString(),
  };

  void append(List<Map<String, Object>> frames, Map<String, String> labels) {
    if (frames.isEmpty) return;
    if (_closed) throw StateError('Raw recording is closed.');
    if (failure != null) throw StateError('Raw recording stopped: $failure');
    try {
      final previousChannels = _channels.length;
      final rows = <List<Object>>[];
      for (final frame in frames) {
        final values = frame['values']! as Map<String, double>;
        final row = <Object>[frame['elapsed']!];
        for (final entry in values.entries) {
          final id = _ids.putIfAbsent(entry.key, () {
            _channels.add({
              'key': entry.key,
              'name': labels[entry.key] ?? entry.key,
            });
            return _channels.length - 1;
          });
          row.addAll([
            id,
            entry.value.isFinite ? entry.value : '${entry.value}',
          ]);
        }
        if (row.length > 1) rows.add(row);
      }
      if (rows.isEmpty) return;
      if (_file == null) {
        directory.createSync(recursive: true);
        final session = directory.createTempSync(
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-',
        );
        path = '${session.path}/samples.talraw';
        _file = File(path!).openSync(mode: FileMode.writeOnly);
      }
      final batch = StringBuffer();
      if (_committedBytes == 0) {
        batch.writeln(jsonEncode({'format': 'take-a-look-raw', 'version': 1}));
      }
      if (_channels.length != previousChannels) {
        batch.writeln(jsonEncode({'channels': _channels}));
      }
      batch.writeln(jsonEncode({'frames': rows}));
      _file!.writeStringSync(batch.toString());
      _committedBytes = _file!.positionSync();
      sampleCount += rows.length;
    } catch (error) {
      failure = error;
      rethrow;
    }
  }

  Future<int> exportCsv(String destination) {
    if (sampleCount == 0) throw StateError('没有原始采样可导出。');
    _file?.flushSync();
    final source = path!;
    final bytes = _committedBytes;
    // Freeze the committed boundary before any new channel or scenario.
    return Isolate.run(
      () => exportRawRecordingCsv(source, destination, byteLength: bytes),
    );
  }

  void rotate() {
    close();
    _closed = false;
    path = null;
    failure = null;
    sampleCount = 0;
    _committedBytes = 0;
    _ids.clear();
    _channels.clear();
  }

  void close() {
    _closed = true;
    final file = _file;
    if (file == null) return;
    _file = null;
    try {
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }
}

/// Public reader also permits exporting retained journals after the app exits.
Future<int> exportRawRecordingCsv(
  String source,
  String destination, {
  int? byteLength,
}) async {
  if (File(source).absolute.path.toLowerCase() ==
      File(destination).absolute.path.toLowerCase()) {
    throw ArgumentError('CSV destination cannot overwrite the raw recording.');
  }
  final target = File(destination);
  final boundary = byteLength ?? await File(source).length();
  var channels = <dynamic>[];
  await for (final line
      in File(source)
          .openRead(0, boundary)
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final record = jsonDecode(line) as Map<String, dynamic>;
    if (record['channels'] is List) channels = record['channels'] as List;
  }
  await target.parent.create(recursive: true);
  final temporary = File(
    '$destination.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  final output = temporary.openSync(mode: FileMode.writeOnly);
  var rows = 0;
  var buffer = StringBuffer(
    'elapsed_seconds,${channels.map((c) => _csv(c['name']!)).join(',')}\n',
  );
  try {
    await for (final line
        in File(source)
            .openRead(0, boundary)
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final record = jsonDecode(line) as Map<String, dynamic>;
      for (final raw in record['frames'] as List? ?? const []) {
        final frame = raw as List;
        final values = List<String>.filled(channels.length, '');
        for (var index = 1; index < frame.length; index += 2) {
          values[frame[index] as int] = _csv('${frame[index + 1]}');
        }
        buffer.writeln(
          '${(frame.first as num).toStringAsFixed(9)},${values.join(',')}',
        );
        rows++;
        if (buffer.length >= 65536) {
          output.writeStringSync(buffer.toString());
          buffer = StringBuffer();
        }
      }
    }
    output.writeStringSync(buffer.toString());
    output.flushSync();
  } catch (_) {
    output.closeSync();
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  }
  output.closeSync();
  await temporary.rename(destination);
  return rows;
}

String _csv(String value) => '"${value.replaceAll('"', '""')}"';
