import 'dart:typed_data';

import 'errors.dart';
import 'geo.dart';
import 'json.dart';

/// Points recorded by one device of a member, as published in one `path` item:
/// a segment of the device's full track (pep_core republishes the open segment
/// as it grows). Points are kept in time order, one per millisecond.
///
/// Compact JSON, so that a day of points stays small:
/// `{"v":1, "p":[t, lat, lon, dt, dlat, dlon, …], "extra":{…}?}` — the first point absolute,
/// every next one as the difference to the previous one; times in
/// milliseconds since the epoch, coordinates in millionths of a degree.
class RecordedPath {
  RecordedPath(Iterable<TimedPoint> points, {this.extra = const {}}) : points = List.unmodifiable(_ordered(points));

  factory RecordedPath.fromJson(Json j) {
    j.checkVersion(version);
    final p = j.opt<List<dynamic>>('p') ?? const [];
    if (p.length % 3 != 0 || p.any((x) => x is! int)) {
      throw const ContentFormatException('field "p" must hold integer triples');
    }
    final points = <TimedPoint>[];
    var t = 0, lat = 0, lon = 0;
    for (var i = 0; i < p.length; i += 3) {
      t += p[i] as int;
      lat += p[i + 1] as int;
      lon += p[i + 2] as int;
      points.add(TimedPoint(lat / _scale, lon / _scale, msToDate(t))); // checks the time and coordinates
    }
    return RecordedPath(points, extra: Map.unmodifiable(j.optMap('extra')));
  }

  factory RecordedPath.decode(Uint8List b) => RecordedPath.fromJson(decodeJson(b));

  static const version = 1;
  static const _scale = 1e6;

  /// In time order, at most one per millisecond.
  final List<TimedPoint> points;

  /// Additional fields (the document's `extra` object), preserved as is on a
  /// round trip. Other unknown fields are dropped.
  final Json extra;

  Json toJson() {
    final p = <int>[];
    var t = 0, lat = 0, lon = 0;
    for (final x in points) {
      final nt = x.time.millisecondsSinceEpoch, nlat = (x.lat * _scale).round(), nlon = (x.lon * _scale).round();
      p.addAll([nt - t, nlat - lat, nlon - lon]);
      (t, lat, lon) = (nt, nlat, nlon);
    }
    return {'v': version, 'p': p, if (extra.isNotEmpty) 'extra': extra};
  }

  Uint8List encode() => encodeJson(toJson());

  static List<TimedPoint> _ordered(Iterable<TimedPoint> points) {
    final byMs = {for (final p in points) p.time.millisecondsSinceEpoch: p};
    return [for (final ms in byMs.keys.toList()..sort()) byMs[ms]!];
  }
}
