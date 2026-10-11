import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:take_a_look_v2/src/analysis/analysis.dart';
import 'package:take_a_look_v2/src/backend/backend_transport.dart';
import 'package:take_a_look_v2/src/chart/painter.dart';
import 'package:take_a_look_v2/src/controller/controller.dart';
import 'package:take_a_look_v2/src/models/models.dart';
import 'audit_protocol_adapter.dart';

typedef AuditMeasure =
    Future<void> Function(
      String name,
      double Function() action, {
      required Map<String, Object?> details,
      required int blocks,
    });
Future<void> runPerformanceAudit(
  AuditMeasure measure,
  void Function(Map<String, Object?>) record,
) => _PerformanceAudit(measure, record).run();

class _PerformanceAudit {
  _PerformanceAudit(this.measure, this._record);
  final AuditMeasure measure;
  final void Function(Map<String, Object?>) _record;
  Future<void> _measure(
    String name,
    double Function() action, {
    Map<String, Object?> details = const {},
    int blocks = 15,
  }) => measure(name, action, details: details, blocks: blocks);

  TakeALookController _auditController(int channels, int points, double rate) {
    final input = [
      for (var channel = 0; channel < channels; channel++)
        WatchItem(
          symbol: SymbolItem(
            source: 'benchmark.c',
            name: 'channel_$channel',
            address: 0x20000000 + channel * 4,
            type: 'float',
            size: 4,
            backendKey: 'channel_$channel',
          ),
          color: Color(0xFF0080FF + channel * 1000),
        ),
    ];
    final c = TakeALookController(backendCommand: (_, _) async {});
    c.applySnapshot({
      'sampleRateHz': rate,
      'plotRetentionSeconds': 60.0,
      'plotVisibleWindowSeconds': 12.0,
      'elapsedSeconds': points / rate,
      'symbols': [for (final w in input) w.symbol.toJson()],
      'watches': [
        for (final w in input)
          {
            'key': w.symbol.key,
            'plotted': true,
            'sampling': true,
            'color': w.color.toARGB32(),
          },
      ],
    });
    for (final w in c.watches) {
      for (var i = 0; i < points; i++) {
        w.samples.addXY(i / rate, math.sin(i / 20) + w.symbol.address % 32);
      }
      w.totalSampleCount = points;
    }
    if (c.watches.any((w) => w.samples.length != points)) {
      throw StateError('Invalid fixture');
    }
    return c;
  }

  double _auditPaint(TelemetryPainter painter) {
    final r = ui.PictureRecorder();
    painter.paint(ui.Canvas(r), const ui.Size(1200, 600));
    final p = r.endRecording();
    final b = p.approximateBytesUsed;
    p.dispose();
    return b.toDouble();
  }

  Future<void> run() async {
    for (final channels in [8, 32]) {
      final c = _auditController(channels, 600000, 10000);
      final painter = TelemetryPainter(c);
      for (final span in [0.2, 12.0, 60.0]) {
        c.plotVisibleWindowSeconds = span;
        await _measure(
          'audit_paint_${channels}_${span}s',
          () => _auditPaint(painter),
          blocks: 9,
          details: {
            'channels': channels,
            'retainedPointsPerChannel': 600000,
            'visibleSeconds': span,
            'includes':
                'Production painter CPU recording, automatic Y bounds; excludes raster',
          },
        );
      }
      c.plotVisibleWindowSeconds = 0.2;
      c.setPlotHighlightedWatch(c.watches.first.symbol.key);
      await _measure(
        'audit_selected_paint_${channels}_0.2s',
        () => _auditPaint(painter),
        blocks: 9,
      );
      c.setPlotHighlightedWatch(null);
      final pause = Stopwatch()..start();
      c.togglePlotting();
      pause.stop();
      _record({
        'name': 'audit_pause_$channels',
        'elapsedMs': pause.elapsedMicroseconds / 1000,
        'retainedPointsPerChannel': 600000,
        'channels': channels,
        'rssBytes': ProcessInfo.currentRss,
      });
      await _measure(
        'audit_paused_paint_${channels}_0.2s',
        () => _auditPaint(painter),
        blocks: 5,
      );
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    const codec = StandardMessageCodec();
    final symbols = List.generate(
      10000,
      (i) => SymbolItem(
        source: 'source_${i ~/ 100}.c',
        name: 'var_$i',
        address: 0x20000000 + i * 4,
        type: 'float',
        size: 4,
        backendKey: 'var_$i',
      ).toJson(),
    );
    final c = TakeALookController(backendCommand: (_, _) async {});
    c.applySnapshot({'symbols': symbols});
    await _measure(
      'audit_state_snapshot_10000_symbols',
      () => codec.encodeMessage(c.stateSnapshot())!.lengthInBytes.toDouble(),
      blocks: 9,
    );
    final state = c.stateSnapshot();
    _record({
      'name': 'audit_state_snapshot_size',
      'symbols': 10000,
      'bytes': codec.encodeMessage(state)!.lengthInBytes,
    });
    final receiver = TakeALookController(remoteCommand: (_, _) async {});
    await _measure('audit_state_apply_10000_symbols', () {
      receiver.applySnapshot(state);
      return receiver.symbolRevision.toDouble();
    }, blocks: 9);
    receiver.dispose();
    c.dispose();
    final delta = _auditController(32, 800, 10000);
    await _measure(
      'audit_delta_snapshot_encode_32x800',
      () => codec
          .encodeMessage(auditTelemetryDelta(delta, {}))!
          .lengthInBytes
          .toDouble(),
      blocks: 9,
    );
    _record({
      'name': 'audit_delta_snapshot_size',
      'channels': 32,
      'frames': 800,
      'bytes': codec
          .encodeMessage(auditTelemetryDelta(delta, {}))!
          .lengthInBytes,
    });
    delta.dispose();
    final full = _auditController(8, 60000, 1000);
    await _measure(
      'audit_full_snapshot_encode_8x60000',
      () => codec
          .encodeMessage(auditFullSnapshot(full))!
          .lengthInBytes
          .toDouble(),
      blocks: 5,
    );
    full.dispose();
    for (final size in [1024 * 1024, 4 * 1024 * 1024]) {
      final bytes = Uint8List.fromList(
        utf8.encode('${jsonEncode({'payload': 'x' * size})}\n'),
      );
      for (final chunkSize in [4096, 65536]) {
        await _measure(
          'audit_json_framing_${size}_$chunkSize',
          () {
            var found = 0;
            final d = BackendStreamDecoder(
              onJsonLine: (line) {
                found = line.length;
              },
              onSamplePayload: (_) {},
            );
            for (var offset = 0; offset < bytes.length; offset += chunkSize) {
              d.add(
                Uint8List.sublistView(
                  bytes,
                  offset,
                  math.min(bytes.length, offset + chunkSize),
                ),
              );
            }
            if (found != bytes.length - 1) throw StateError('Incomplete line');
            return found.toDouble();
          },
          blocks: 5,
          details: {
            'bytes': bytes.length,
            'chunkBytes': chunkSize,
            'includes': 'Framing and UTF-8 decode only',
          },
        );
      }
    }
    final input = [
      for (var ch = 0; ch < 8; ch++)
        AnalysisSeries(
          name: 'column_$ch',
          color: Colors.cyan,
          points: [
            for (var i = 0; i < 100000; i++)
              AnalysisPoint(i / 10000, math.sin(i / 20 + ch)),
          ],
        ),
    ];
    final session = AnalysisSession();
    await _measure('audit_analysis_replace_sorted_8x100000', () {
      session.replaceData(input, 'CSV');
      return session.series.length.toDouble();
    }, blocks: 9);
    await _measure('audit_analysis_replace_and_bounds_8x100000', () {
      session.replaceData(input, 'CSV');
      return session.dataBounds.$4;
    }, blocks: 9);
    session.selectionStart = 0;
    session.selectionEnd = 10;
    await _measure('audit_analysis_selection_stats_8x100000', () {
      session.updateSelectionStats();
      return session.selectionStats.first!.average;
    }, blocks: 9);
    final csv = StringBuffer('time,a,b,c,d,e,f,g,h\n');
    for (var i = 0; i < 100000; i++) {
      csv.writeln('${i / 10000},1,2,3,4,5,6,7,8');
    }
    final text = csv.toString();
    final timer = Stopwatch()..start();
    final parsed = await parseAnalysisCsvInBackground(
      text,
      colors: seriesColors,
    );
    timer.stop();
    if (parsed.length != 8 || parsed.first.points.length != 100000) {
      throw StateError('Bad CSV fixture');
    }
    _record({
      'name': 'audit_background_csv_100000x8',
      'elapsedMs': timer.elapsedMicroseconds / 1000,
      'textBytes': text.length,
    });
    final moving = _auditController(32, 600000, 10000);
    final movingPainter = TelemetryPainter(moving);
    var nextFrame = 600000;
    for (final span in [12.0, 60.0]) {
      moving.plotVisibleWindowSeconds = span;
      await _measure(
        'audit_moving_paint_32_${span}s',
        () {
          for (final watch in moving.watches) {
            for (var i = 0; i < 64; i++) {
              watch.samples.addXY(
                (nextFrame + i) / 10000,
                math.sin((nextFrame + i) / 20),
              );
            }
            watch.totalSampleCount += 64;
          }
          nextFrame += 64;
          moving.elapsedSeconds = nextFrame / 10000;
          return _auditPaint(movingPainter);
        },
        blocks: 9,
        details: {
          'channels': 32,
          'newFramesPerPaint': 64,
          'visibleSeconds': span,
          'includes':
              'Fresh samples, changing viewport, exact extrema and CPU painting; excludes GPU',
        },
      );
    }
    moving.dispose();
    final changes = TakeALookController(backendCommand: (_, _) async {});
    changes.applySnapshot({'symbols': symbols});
    var versions = auditStateVersions(changes);
    await _measure('audit_state_sync_plot_change_10000_symbols', () {
      changes.configurePlotView({'plotInvertX': !changes.plotInvertX});
      final data = auditStateDelta(changes, versions);
      versions = auditStateVersions(changes);
      return codec.encodeMessage(data)!.lengthInBytes.toDouble();
    }, blocks: 9);
    changes.dispose();
  }
}
