part of 'cartesian_renderer.dart';

const useWaveformMesh = bool.fromEnvironment(
  'TAL_WAVEFORM_MESH',
  defaultValue: true,
);

/// Screen-space geometry shared by the waveform and its inspection overlay.
class WaveformGeometry {
  Float32List _positions = Float32List(0);
  final _runEnds = <int>[];
  List<Offset>? _source;
  CartesianPlotViewport? _viewport;
  Float32List _meshPositions = Float32List(0);
  Int32List _meshColors = Int32List(0);
  Uint16List _meshIndices = Uint16List(0);
  final _meshCache = <(Color, double, double), List<Vertices>>{};
  int? _bufferColor;

  void _prepare(List<Offset> source, CartesianPlotViewport viewport) {
    final previous = _viewport;
    if (previous != null &&
        identical(_source, source) &&
        previous.plot == viewport.plot &&
        previous.xMin == viewport.xMin &&
        previous.xMax == viewport.xMax &&
        previous.yMin == viewport.yMin &&
        previous.yMax == viewport.yMax &&
        previous.invertX == viewport.invertX &&
        previous.invertY == viewport.invertY) {
      return;
    }
    _source = source;
    _viewport = viewport;
    _meshCache.clear();
    if (_positions.length < source.length * 2) {
      _positions = Float32List(
        math.max(_positions.length * 2, source.length * 2),
      );
    }
    _runEnds.clear();
    var length = 0;
    for (final point in source) {
      if (!point.isFinite) {
        if (length > (_runEnds.lastOrNull ?? 0)) _runEnds.add(length);
        continue;
      }
      if (point.dx < viewport.xMin || point.dx > viewport.xMax) continue;
      _positions[length++] = viewport.mapX(point.dx);
      _positions[length++] = viewport.mapY(point.dy);
    }
    if (length > (_runEnds.lastOrNull ?? 0)) _runEnds.add(length);
  }

  void _draw(Canvas canvas, Color color, double strokeWidth) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    var start = 0;
    for (final end in _runEnds) {
      if (end - start >= 4) {
        canvas.drawRawPoints(
          PointMode.polygon,
          Float32List.sublistView(_positions, start, end),
          paint,
        );
      }
      start = end;
    }
  }

  void _drawMesh(
    Canvas canvas,
    Color color,
    double strokeWidth,
    double feather,
  ) {
    final style = (color, strokeWidth, feather);
    var meshes = _meshCache[style];
    if (meshes == null) {
      if (_meshCache.length == 2) _meshCache.remove(_meshCache.keys.first);
      meshes = _meshCache[style] = _buildMesh(color, strokeWidth, feather);
    }
    final paint = Paint()..isAntiAlias = false;
    for (final mesh in meshes) {
      canvas.drawVertices(mesh, BlendMode.dst, paint);
    }
  }

  List<Vertices> _buildMesh(Color color, double strokeWidth, double feather) {
    const verticesPerSegment = 8;
    const indicesPerSegment = 18;
    const maxSegments = 65536 ~/ verticesPerSegment;
    final length = math.min((_runEnds.lastOrNull ?? 0) ~/ 2, maxSegments);
    if (length == 0) return const [];
    final meshes = <Vertices>[];
    var capacity = _meshColors.length ~/ verticesPerSegment;
    if (capacity < length) {
      capacity = math.min(maxSegments, math.max(length, capacity * 2));
      _meshPositions = Float32List(capacity * verticesPerSegment * 2);
      _meshColors = Int32List(capacity * verticesPerSegment);
      _meshIndices = Uint16List(capacity * indicesPerSegment);
      _bufferColor = null;
      var index = 0;
      for (var segment = 0; segment < capacity; segment++) {
        final base = segment * verticesPerSegment;
        for (var edge = 0; edge < 3; edge++) {
          final a = base + edge;
          final b = a + 4;
          _meshIndices[index++] = a;
          _meshIndices[index++] = b;
          _meshIndices[index++] = a + 1;
          _meshIndices[index++] = a + 1;
          _meshIndices[index++] = b;
          _meshIndices[index++] = b + 1;
        }
      }
    }
    final solid = color.toARGB32();
    if (_bufferColor != solid) {
      final clear = solid & 0xffffff;
      for (var i = 0; i < _meshColors.length; i += 4) {
        _meshColors[i] = clear;
        _meshColors[i + 1] = solid;
        _meshColors[i + 2] = solid;
        _meshColors[i + 3] = clear;
      }
      _bufferColor = solid;
    }
    // Fade across one physical pixel at each side of the stroke.
    final outer = (strokeWidth + feather) / 2;
    final inner = math.max(0.0, (strokeWidth - feather) / 2);
    var segments = 0;
    void flush() {
      if (segments == 0) return;
      final vertices = segments * verticesPerSegment;
      meshes.add(
        Vertices.raw(
          VertexMode.triangles,
          Float32List.sublistView(_meshPositions, 0, vertices * 2),
          colors: Int32List.sublistView(_meshColors, 0, vertices),
          indices: Uint16List.sublistView(
            _meshIndices,
            0,
            segments * indicesPerSegment,
          ),
        ),
      );
      segments = 0;
    }

    void endpoint(int vertex, double x, double y, double nx, double ny) {
      final base = vertex * 2;
      _meshPositions[base] = x - nx * outer;
      _meshPositions[base + 1] = y - ny * outer;
      _meshPositions[base + 2] = x - nx * inner;
      _meshPositions[base + 3] = y - ny * inner;
      _meshPositions[base + 4] = x + nx * inner;
      _meshPositions[base + 5] = y + ny * inner;
      _meshPositions[base + 6] = x + nx * outer;
      _meshPositions[base + 7] = y + ny * outer;
    }

    var start = 0;
    for (final end in _runEnds) {
      for (var i = start + 2; i < end; i += 2) {
        final x = _positions[i], y = _positions[i + 1];
        final previousX = _positions[i - 2], previousY = _positions[i - 1];
        final dx = x - previousX, dy = y - previousY;
        final distance = math.sqrt(dx * dx + dy * dy);
        if (distance == 0) continue;
        final vertex = segments * verticesPerSegment;
        final nx = dy / distance, ny = -dx / distance;
        endpoint(vertex, previousX, previousY, nx, ny);
        endpoint(vertex + 4, x, y, nx, ny);
        if (++segments == capacity) flush();
      }
      start = end;
    }
    flush();
    return meshes;
  }
}
