import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'workspace_layout.dart';

class WorkspaceGeometry {
  const WorkspaceGeometry({
    this.minWidth = 0.14,
    this.minHeight = 0.10,
    this.gridCellSize = 32,
    this.adjacencyTolerance = 0.012,
    this.overlapTolerance = 0.001,
  });

  final double minWidth;
  final double minHeight;
  final double gridCellSize;
  final double adjacencyTolerance;
  final double overlapTolerance;

  Rect clampRect(Rect rect) {
    final width = rect.width.clamp(minWidth, 1.0);
    final height = rect.height.clamp(minHeight, 1.0);
    final left = rect.left.clamp(0.0, 1.0 - width);
    final top = rect.top.clamp(0.0, 1.0 - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  Rect toPixelRect(Rect rect, Size size) {
    return Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
  }

  Rect snapRectToGrid(Rect rect, Size workspaceSize) {
    if (workspaceSize.isEmpty) return clampRect(rect);
    final minWidthPixels =
        (minWidth * workspaceSize.width / gridCellSize).ceil() * gridCellSize;
    final minHeightPixels =
        (minHeight * workspaceSize.height / gridCellSize).ceil() * gridCellSize;
    var left = _snapPixel(rect.left * workspaceSize.width, workspaceSize.width);
    var right = _snapPixel(
      rect.right * workspaceSize.width,
      workspaceSize.width,
    );
    var top = _snapPixel(rect.top * workspaceSize.height, workspaceSize.height);
    var bottom = _snapPixel(
      rect.bottom * workspaceSize.height,
      workspaceSize.height,
    );

    if (right - left < minWidthPixels) right = left + minWidthPixels;
    if (right > workspaceSize.width) {
      right = workspaceSize.width;
      left = math.max(0, right - minWidthPixels);
    }
    if (bottom - top < minHeightPixels) bottom = top + minHeightPixels;
    if (bottom > workspaceSize.height) {
      bottom = workspaceSize.height;
      top = math.max(0, bottom - minHeightPixels);
    }

    return Rect.fromLTRB(
      left / workspaceSize.width,
      top / workspaceSize.height,
      right / workspaceSize.width,
      bottom / workspaceSize.height,
    );
  }

  double wholeGridDelta(double value, double unit) {
    return (value / unit).truncate() * unit;
  }

  Map<WorkspaceGroup, bool> resizeParticipants(
    List<WorkspaceGroup> groups,
    WorkspaceGroup source, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    final boundary = edge(source.rect, horizontal: horizontal, end: movingEnd);
    final participants = <WorkspaceGroup, bool>{source: movingEnd};
    var changed = true;
    while (changed) {
      changed = false;
      final current = participants.entries.toList();
      for (final entry in current) {
        final group = entry.key;
        final role = entry.value;
        for (final candidate in groups) {
          if (candidate == group || participants.containsKey(candidate)) {
            continue;
          }
          final candidateEdge = edge(
            candidate.rect,
            horizontal: horizontal,
            end: role,
          );
          if (!near(candidateEdge, boundary) ||
              !touchesPerpendicular(group.rect, candidate.rect, horizontal)) {
            continue;
          }
          participants[candidate] = role;
          changed = true;
        }

        final oppositeRole = !role;
        for (final candidate in groups) {
          if (candidate == group || participants.containsKey(candidate)) {
            continue;
          }
          final candidateEdge = edge(
            candidate.rect,
            horizontal: horizontal,
            end: oppositeRole,
          );
          final overlap = perpendicularOverlap(
            group.rect,
            candidate.rect,
            horizontal,
          );
          if (near(candidateEdge, boundary) && overlap > overlapTolerance) {
            participants[candidate] = oppositeRole;
            changed = true;
          }
        }
      }
    }
    return participants;
  }

  double constrainedBoundaryDelta(
    Map<WorkspaceGroup, bool> participants,
    double requestedDelta, {
    required bool horizontal,
  }) {
    final minSize = horizontal ? minWidth : minHeight;
    var lower = -double.infinity;
    var upper = double.infinity;

    for (final entry in participants.entries) {
      final rect = entry.key.rect;
      final movingEnd = entry.value;
      final start = horizontal ? rect.left : rect.top;
      final end = horizontal ? rect.right : rect.bottom;
      final size = end - start;
      if (movingEnd) {
        lower = math.max(lower, minSize - size);
        upper = math.min(upper, 1.0 - end);
      } else {
        lower = math.max(lower, -start);
        upper = math.min(upper, size - minSize);
      }
    }
    return requestedDelta.clamp(lower, upper).toDouble();
  }

  double edge(Rect rect, {required bool horizontal, required bool end}) {
    if (horizontal) return end ? rect.right : rect.left;
    return end ? rect.bottom : rect.top;
  }

  bool near(double first, double second) {
    return (first - second).abs() <= adjacencyTolerance;
  }

  double perpendicularOverlap(Rect first, Rect second, bool horizontal) {
    return horizontal
        ? math.min(first.bottom, second.bottom) -
              math.max(first.top, second.top)
        : math.min(first.right, second.right) -
              math.max(first.left, second.left);
  }

  bool touchesPerpendicular(Rect first, Rect second, bool horizontal) {
    final overlap = perpendicularOverlap(first, second, horizontal);
    if (overlap > overlapTolerance) return true;
    return -overlap <= adjacencyTolerance;
  }

  Rect moveBoundary(
    Rect rect,
    double delta, {
    required bool horizontal,
    required bool movingEnd,
  }) {
    if (horizontal) {
      return movingEnd
          ? Rect.fromLTRB(rect.left, rect.top, rect.right + delta, rect.bottom)
          : Rect.fromLTRB(rect.left + delta, rect.top, rect.right, rect.bottom);
    }
    return movingEnd
        ? Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom + delta)
        : Rect.fromLTRB(rect.left, rect.top + delta, rect.right, rect.bottom);
  }

  double _snapPixel(double value, double maximum) {
    return ((value / gridCellSize).round() * gridCellSize)
        .clamp(0, maximum)
        .toDouble();
  }
}
