import 'geo.dart';

/// Tuning of [TrailProgress.match].
class ProgressParams {
  const ProgressParams({
    this.corridor = 50,
    this.startZone = 100,
    this.confirmAdvance = 200,
    this.confirmWindow = const Duration(hours: 1),
    this.confirmMinPoints = 5,
    this.jumpBase = 250,
    this.travelFactor = 1.5,
    this.exitDistance = 350,
    this.exitCount = 4,
  });

  /// A point this close (m) to the line is "on the track".
  final double corridor;

  /// A start anchor must match the first [startZone] metres of the track…
  final double startZone;

  /// …and be followed by this much advance (m) along the line…
  final double confirmAdvance;

  /// …within this time (laying the dog on the track can be slow)…
  final Duration confirmWindow;

  /// …with at least this many points inside the corridor.
  final int confirmMinPoints;

  /// Always-believable advance (m) between accepted points…
  final double jumpBase;

  /// …plus this much per metre actually travelled.
  final double travelFactor;

  /// Being this far (m) from the line…
  final double exitDistance;

  /// …for this many consecutive points ends the run.
  final int exitCount;
}

/// How far a recorded path (e.g. the dog's) has progressed along a track.
///
/// Every point is projected onto the track once; the start is the first point
/// near the beginning of the track from which the path verifiably advances
/// along it (a chance pass-by or a later return to the start never counts).
/// From there a cursor moves forward only — by steps the distance actually
/// travelled can back up, so a path passing near a far part of the track does
/// not jump ahead — until the path leaves the track for good.
class TrailProgress {
  TrailProgress._(this.line, this.anchor, this.end, this.progress);

  /// Matches [path] (in time order) against [line].
  factory TrailProgress.match(TrackLine line, List<TimedPoint> path, {ProgressParams params = const ProgressParams()}) {
    final p = params;
    final proj = [for (final pt in path) line.nearest(pt.lat, pt.lon)];
    final travel = List<double>.filled(path.length, 0);
    for (var i = 1; i < path.length; i++) {
      travel[i] = travel[i - 1] + path[i - 1].distanceTo(path[i]);
    }
    double allowance(double travelled) => p.jumpBase + p.travelFactor * travelled;

    var anchor = -1;
    for (var i = 0; i < proj.length && anchor == -1; i++) {
      if (proj[i].distance > p.corridor || proj[i].location > p.startZone) continue;
      var maxLoc = proj[i].location, maxIdx = i, inCorridor = 0, far = 0;
      for (var j = i + 1; j < proj.length && path[j].time.difference(path[i].time) <= p.confirmWindow; j++) {
        if (proj[j].distance > p.exitDistance) {
          if (++far >= p.exitCount) break; // left before advancing: a pass-by
          continue;
        }
        far = 0;
        if (proj[j].distance > p.corridor) continue;
        inCorridor++;
        if (proj[j].location > maxLoc && proj[j].location - maxLoc <= allowance(travel[j] - travel[maxIdx])) {
          maxLoc = proj[j].location;
          maxIdx = j;
        }
        if (inCorridor >= p.confirmMinPoints && maxLoc - proj[i].location >= p.confirmAdvance) {
          anchor = i;
          break;
        }
      }
    }
    if (anchor == -1) return TrailProgress._(line, null, path.length, 0);

    var progress = proj[anchor].location, progressIdx = anchor, farCount = 0, end = path.length;
    for (var i = anchor + 1; i < proj.length; i++) {
      if (proj[i].distance > p.exitDistance) {
        if (++farCount >= p.exitCount) {
          end = i - p.exitCount + 1;
          break;
        }
        continue;
      }
      farCount = 0;
      if (proj[i].distance < p.corridor &&
          proj[i].location > progress &&
          proj[i].location - progress <= allowance(travel[i] - travel[progressIdx])) {
        progress = proj[i].location;
        progressIdx = i;
      }
    }
    return TrailProgress._(line, anchor, end, progress);
  }

  final TrackLine line;

  /// Index of the path point where the run started; null: not started.
  final int? anchor;

  /// Index after the last path point of the run (the path left the track for
  /// good before it, or the end of the path).
  final int end;

  /// Metres along the track reached.
  final double progress;

  bool get started => anchor != null;

  /// Part of the track reached, 0..1.
  double get fraction => line.length == 0 ? 0 : (progress / line.length).clamp(0, 1);

  /// The part of the track covered so far.
  List<GeoPoint> get done => started ? line.slice(0, progress) : const [];
}
