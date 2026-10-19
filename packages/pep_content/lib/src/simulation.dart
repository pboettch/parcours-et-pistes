import 'dart:math' as math;

import 'geo.dart';
import 'gpx.dart';

/// Simulated walk along a track (a dog and its handler), for demos and tests:
/// moves at [speed] along [line], zigzagging across it by up to [wobble]
/// metres, with [jitter] metres of GPS noise.
class TrailWalker {
  TrailWalker(this.line, {this.speed = 0.8, this.wobble = 12, this.jitter = 3, int? seed})
    : _random = math.Random(seed);

  final TrackLine line;

  /// Metres per second along the track.
  final double speed;
  final double wobble;
  final double jitter;
  final math.Random _random;

  /// Walking time needed to reach the end of the track.
  Duration get duration => Duration(milliseconds: (line.length / speed * 1000).round());

  bool finishedAt(Duration elapsed) => elapsed >= duration;

  /// Where the walker is after [elapsed].
  GeoPoint at(Duration elapsed) {
    final loc = math.min(line.length, speed * elapsed.inMilliseconds / 1000);
    final p = line.pointAt(loc);
    final a = line.pointAt(loc - 2), b = line.pointAt(loc + 2);
    // Unit vector across the track, in metres (x east, y north).
    final kx = math.cos(p.lat * math.pi / 180);
    var dx = (b.lon - a.lon) * kx, dy = b.lat - a.lat;
    final n = math.sqrt(dx * dx + dy * dy);
    if (n == 0) {
      dx = 1;
      dy = 0;
    } else {
      dx /= n;
      dy /= n;
    }
    final across = wobble * math.sin(2 * math.pi * loc / 60);
    final ex = -dy * across + _noise(), ny = dx * across + _noise();
    const mPerDeg = earthRadius * math.pi / 180;
    return GeoPoint(p.lat + ny / mPerDeg, p.lon + ex / (mPerDeg * kx));
  }

  double _noise() => (_random.nextDouble() * 2 - 1) * jitter;
}

/// A random trail for demos and tests: a smooth walk of about [length] metres
/// from [start], with [objects] RU objects spread along it (a few metres off
/// the line, never at its ends). With [laid], the points carry the times of a
/// setter walking at [speed] metres per second. The same [seed] gives the
/// same trail.
Gpx simulateTrail(
  GeoPoint start, {
  double length = 1000,
  int objects = 0,
  String? name,
  DateTime? laid,
  double speed = 1.1,
  int? seed,
}) {
  final r = math.Random(seed);
  const mPerDeg = earthRadius * math.pi / 180;
  GeoPoint move(GeoPoint p, double d, double heading) => GeoPoint(
    p.lat + d * math.cos(heading) / mPerDeg,
    p.lon + d * math.sin(heading) / (mPerDeg * math.cos(p.lat * math.pi / 180)),
  );

  final points = <GeoPoint>[start];
  final distances = <double>[0];
  var heading = r.nextDouble() * 2 * math.pi;
  while (distances.last < length) {
    final step = math.min(14 + r.nextDouble() * 12, length - distances.last);
    heading += (r.nextDouble() + r.nextDouble() + r.nextDouble() - 1.5) * 0.4; // gentle bends
    points.add(move(points.last, step, heading));
    distances.add(distances.last + step);
  }
  DateTime? timeAt(double d) => laid?.add(Duration(milliseconds: (d / speed * 1000).round()));

  final line = TrackLine(points);
  final waypoints = <GpxWaypoint>[];
  for (var i = 1; i <= objects; i++) {
    // Evenly spaced, shifted by up to a third of the gap.
    final gap = line.length / (objects + 1);
    final at = gap * i + (r.nextDouble() - 0.5) * gap / 1.5;
    final p = move(line.pointAt(at), 1 + r.nextDouble() * 3, r.nextDouble() * 2 * math.pi);
    waypoints.add(GpxWaypoint.object(p.lat, p.lon, name: 'Objet $i', time: timeAt(at)));
  }
  return Gpx(
    name: name,
    time: laid,
    waypoints: waypoints,
    tracks: [
      GpxTrack(
        name: name,
        segments: [
          [for (var i = 0; i < points.length; i++) GpxPoint(points[i].lat, points[i].lon, time: timeAt(distances[i]))],
        ],
      ),
    ],
  );
}
