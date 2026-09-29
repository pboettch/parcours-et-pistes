import 'package:xml/xml.dart';

import 'gpx.dart';

/// Official RU trail details, in the track's GPX metadata as
/// `<pep:trail code="V1" level="I" setter="…"/>`.
///
/// Placeholder for the official trail sheet ("description de pose"): the
/// organizers' part and the judge's part will be added here.
class TrailInfo {
  const TrailInfo({this.code, this.level, this.setter});

  /// The trail details of [gpx], if any.
  static TrailInfo? of(Gpx gpx) {
    final e = gpx.metadataExtensions.pep(element);
    if (e == null) return null;
    String? a(String n) => e.getAttribute(n);
    return TrailInfo(code: a('code'), level: a('level'), setter: a('setter'));
  }

  static const element = 'trail';

  /// Trail number within the event, e.g. `V1`.
  final String? code;

  /// Level: `B` (brevet), `I`, `II`, `III`.
  final String? level;

  /// Who laid the trail ("poseur").
  final String? setter;

  XmlElement toElement() => pepElement(element, attributes: {'code': ?code, 'level': ?level, 'setter': ?setter});

  /// [gpx] with these details (replacing earlier ones).
  Gpx applyTo(Gpx gpx) => gpx.copyWith(
    metadataExtensions: [
      for (final e in gpx.metadataExtensions)
        if (!identical(e, gpx.metadataExtensions.pep(element))) e,
      toElement(),
    ],
  );
}

/// For GPX files from other tools (e.g. Visorando) where every waypoint is a
/// plain one: waypoints of no known type that are not at the start or the end
/// of the track (within [tolerance] metres) become RU objects; the others are
/// kept as they are.
Gpx objectsFromWaypoints(Gpx gpx, {double tolerance = 15}) {
  final pts = gpx.tracks.expand((t) => t.points).toList();
  bool atEnd(GpxWaypoint w) =>
      pts.isNotEmpty && (w.distanceTo(pts.first) <= tolerance || w.distanceTo(pts.last) <= tolerance);
  return gpx.copyWith(
    waypoints: [
      for (final w in gpx.waypoints)
        (w.type ?? '').startsWith('pep:') || atEnd(w) ? w : w.copyWith(type: GpxWaypoint.objectType),
    ],
  );
}
