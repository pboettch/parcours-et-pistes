import 'dart:math' as math;

import 'package:pep_content/pep_content.dart';
import 'package:test/test.dart';

/// Metres per degree of latitude.
const mPerDeg = earthRadius * math.pi / 180;

/// A point [north] / [east] metres from (48.6, 2.17).
GeoPoint at(double north, [double east = 0]) =>
    GeoPoint(48.6 + north / mPerDeg, 2.17 + east / (mPerDeg * math.cos(48.6 * math.pi / 180)));

final t0 = DateTime.utc(2026, 9, 20, 10);

/// A path sampled every 20 s through the given (north, east) metres.
List<TimedPoint> path(List<(double, double)> nes) => [
  for (var i = 0; i < nes.length; i++)
    TimedPoint(at(nes[i].$1, nes[i].$2).lat, at(nes[i].$1, nes[i].$2).lon, t0.add(Duration(seconds: 20 * i))),
];

void main() {
  group('geometry', () {
    test('haversine', () {
      expect(distanceMeters(48.6, 2.17, 48.6, 2.17), 0);
      expect(at(0).distanceTo(at(1000)), closeTo(1000, 0.5));
      // Paris – Lyon ≈ 392 km.
      expect(distanceMeters(48.8566, 2.3522, 45.764, 4.8357) / 1000, closeTo(392, 2));
    });

    test('coordinates are validated', () {
      expect(() => GeoPoint(91, 0), throwsA(isA<ContentFormatException>()));
      expect(() => GpxPoint(0, 181), throwsA(isA<ContentFormatException>()));
    });

    final line = TrackLine([at(0), at(500), at(500, 500)]); // north, then east

    test('length and nearest point', () {
      expect(line.length, closeTo(1000, 1));
      final n = line.nearest(at(200, 30).lat, at(200, 30).lon);
      expect(n.distance, closeTo(30, 0.5));
      expect(n.location, closeTo(200, 0.5));
      final e = line.nearest(at(560, 250).lat, at(560, 250).lon);
      expect(e.distance, closeTo(60, 0.5));
      expect(e.location, closeTo(750, 1));
      // Beyond the start: clamped to the first point.
      expect(line.nearest(at(-100).lat, at(-100).lon).location, 0);
      expect(line.nearest(at(-100).lat, at(-100).lon).distance, closeTo(100, 0.5));
    });

    test('pointAt and slice', () {
      expect(line.pointAt(250).distanceTo(at(250)), lessThan(0.5));
      expect(line.pointAt(750).distanceTo(at(500, 250)), lessThan(1));
      expect(line.pointAt(-5).distanceTo(at(0)), 0);
      expect(line.pointAt(5000).distanceTo(at(500, 500)), 0);
      final s = line.slice(250, 750);
      expect(s, hasLength(3)); // start, the corner, end
      expect(s[1].distanceTo(at(500)), 0);
      expect(TrackLine(s).length, closeTo(500, 1));
    });

    test('degenerate lines', () {
      expect(() => TrackLine(const []), throwsA(isA<ContentFormatException>()));
      final one = TrackLine([at(0)]);
      expect(one.length, 0);
      expect(one.nearest(at(10).lat, at(10).lon).distance, closeTo(10, 0.1));
      expect(one.pointAt(3).distanceTo(at(0)), 0);
      final dup = TrackLine([at(0), at(0), at(100)]);
      expect(dup.nearest(at(50, 5).lat, at(50, 5).lon).location, closeTo(50, 0.5));
    });
  });

  group('TrailProgress', () {
    final line = TrackLine([at(0), at(1000)]);

    test('follows the dog along the track', () {
      final p = TrailProgress.match(line, path([for (var n = 0.0; n <= 600; n += 30) (n, n % 60 == 0 ? 8 : -8)]));
      expect(p.started, isTrue);
      expect(p.anchor, 0);
      expect(p.progress, closeTo(600, 1));
      expect(p.fraction, closeTo(0.6, 0.01));
      expect(TrackLine(p.done).length, closeTo(600, 1));
    });

    test('not started: too little advance, or a pass-by', () {
      expect(TrailProgress.match(line, path([(0, 0), (20, 0), (40, 0)])).started, isFalse);
      // Crosses the start, then leaves for good.
      final passBy = TrailProgress.match(
        line,
        path([(0, -300), (0, 0), (0, 400), (0, 800), (0, 1200), (0, 1600), (0, 2000)]),
      );
      expect(passBy.started, isFalse);
      expect(passBy.done, isEmpty);
      expect(passBy.fraction, 0);
    });

    test('the anchor is the first confirmed start, after wandering', () {
      final p = TrailProgress.match(
        line,
        path([(0, -600), (0, -300), (5, 0), (40, 0), for (var n = 60.0; n <= 400; n += 40) (n, 0)]),
      );
      expect(p.anchor, 2);
      expect(p.progress, closeTo(380, 1));
    });

    test('the cursor never goes back and ignores unbelievable jumps', () {
      final line2 = TrackLine([at(0), at(1000), at(1000, 60), at(0, 60)]); // a hairpin
      final p = TrailProgress.match(
        line2,
        path([
          for (var n = 0.0; n <= 300; n += 30) (n, 0),
          (250, 0), (200, 0), // back towards the start
          (300, 35), // next to the return leg (≈1760 m along): not believable
          (330, 0),
        ]),
      );
      expect(p.progress, closeTo(330, 1));
    });

    test('the run ends when the path leaves for good', () {
      final p = TrailProgress.match(
        line,
        path([
          for (var n = 0.0; n <= 300; n += 30) (n, 0),
          (300, 500), (300, 600), (300, 700), (300, 800), // gone
          (600, 0), // later, back on the track: not part of the run
        ]),
      );
      expect(p.progress, closeTo(300, 1));
      expect(p.end, 11);
    });
  });
}
