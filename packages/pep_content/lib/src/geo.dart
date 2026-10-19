import 'dart:math' as math;

import 'errors.dart';

/// Mean Earth radius (metres), as used by the haversine formula.
const earthRadius = 6371008.8;

/// A WGS84 position in degrees.
class GeoPoint {
  GeoPoint(this.lat, this.lon) {
    if (!(lat >= -90 && lat <= 90) || !(lon >= -180 && lon <= 180)) {
      throw ContentFormatException('coordinates out of range: $lat, $lon');
    }
  }

  final double lat, lon;

  /// Great-circle distance in metres.
  double distanceTo(GeoPoint o) => distanceMeters(lat, lon, o.lat, o.lon);

  @override
  String toString() => '($lat, $lon)';
}

/// A position at a point in time (a recorded or live fix).
class TimedPoint extends GeoPoint {
  TimedPoint(super.lat, super.lon, this.time);

  final DateTime time;
}

/// Great-circle (haversine) distance in metres.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  final a =
      math.pow(math.sin(dLat / 2), 2) + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

/// Where a position projects onto a [TrackLine].
class LinePoint extends GeoPoint {
  LinePoint(super.lat, super.lon, {required this.distance, required this.location});

  /// Distance in metres from the position to this nearest point of the line.
  final double distance;

  /// Distance in metres along the line from its start to this point.
  final double location;
}

/// A polyline (e.g. the points of a track) with distances along it.
///
/// Projections use a local flat approximation per segment, accurate to well
/// under a metre for the segment lengths of a trail.
class TrackLine {
  TrackLine(Iterable<GeoPoint> points) : points = List.unmodifiable(points) {
    if (this.points.isEmpty) throw const ContentFormatException('a track line needs at least one point');
    final cum = List<double>.filled(this.points.length, 0);
    for (var i = 1; i < this.points.length; i++) {
      cum[i] = cum[i - 1] + this.points[i - 1].distanceTo(this.points[i]);
    }
    _cumulative = cum;
  }

  final List<GeoPoint> points;
  late final List<double> _cumulative;

  /// Total length in metres.
  double get length => _cumulative.last;

  /// The point of the line nearest to ([lat], [lon]).
  LinePoint nearest(double lat, double lon) {
    if (points.length == 1) {
      final p = points.first;
      return LinePoint(p.lat, p.lon, distance: distanceMeters(lat, lon, p.lat, p.lon), location: 0);
    }
    LinePoint? best;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      // Flat projection centred on a: x east, y north, in metres.
      final kx = math.cos(a.lat * math.pi / 180) * earthRadius * math.pi / 180;
      const ky = earthRadius * math.pi / 180;
      final bx = (b.lon - a.lon) * kx, by = (b.lat - a.lat) * ky;
      final px = (lon - a.lon) * kx, py = (lat - a.lat) * ky;
      final len2 = bx * bx + by * by;
      final t = len2 == 0 ? 0.0 : ((px * bx + py * by) / len2).clamp(0.0, 1.0);
      final qLat = a.lat + (b.lat - a.lat) * t, qLon = a.lon + (b.lon - a.lon) * t;
      final d = distanceMeters(lat, lon, qLat, qLon);
      if (best == null || d < best.distance) {
        final loc = _cumulative[i] + (_cumulative[i + 1] - _cumulative[i]) * t;
        best = LinePoint(qLat, qLon, distance: d, location: loc);
      }
    }
    return best!;
  }

  /// The point at [location] metres along the line (clamped to its ends).
  GeoPoint pointAt(double location) {
    if (location <= 0 || points.length == 1) return points.first;
    if (location >= length) return points.last;
    final i = _segmentAt(location);
    final segLen = _cumulative[i + 1] - _cumulative[i];
    final t = segLen == 0 ? 0.0 : (location - _cumulative[i]) / segLen;
    final a = points[i], b = points[i + 1];
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
  }

  /// The part of the line between [from] and [to] metres along it.
  List<GeoPoint> slice(double from, double to) {
    from = from.clamp(0, length);
    to = to.clamp(from, length);
    final out = <GeoPoint>[pointAt(from)];
    for (var i = 0; i < points.length; i++) {
      if (_cumulative[i] > from && _cumulative[i] < to) out.add(points[i]);
    }
    out.add(pointAt(to));
    return out;
  }

  /// Index of the segment containing [location] (binary search).
  int _segmentAt(double location) {
    var lo = 0, hi = points.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_cumulative[mid] <= location) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
