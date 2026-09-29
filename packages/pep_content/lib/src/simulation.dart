import 'dart:math' as math;

import 'geo.dart';

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
