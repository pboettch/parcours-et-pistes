import 'package:xml/xml.dart';

import '../errors.dart';

/// A GPX point (track point, route point or waypoint).
class GpxPoint {
  GpxPoint(this.lat, this.lon, {this.ele, this.time}) {
    if (!(lat >= -90 && lat <= 90) || !(lon >= -180 && lon <= 180)) {
      throw FormatPepException('GPX coordinates out of range: $lat, $lon');
    }
  }

  final double lat, lon;
  final double? ele;
  final DateTime? time;
}

/// A GPX waypoint. In RU projects, objects placed along the track are
/// waypoints of type [objectType].
class GpxWaypoint extends GpxPoint {
  GpxWaypoint(super.lat, super.lon,
      {super.ele, super.time, this.name, this.description, this.type, this.symbol});

  /// `<type>` value marking an RU object.
  static const objectType = 'pep:object';

  factory GpxWaypoint.object(double lat, double lon, {String? name, String? description, DateTime? time}) =>
      GpxWaypoint(lat, lon, name: name, description: description, type: objectType, time: time);

  final String? name;
  final String? description;
  final String? type;
  final String? symbol;

  bool get isObject => type == objectType;
}

class GpxTrack {
  GpxTrack({this.name, this.description, this.type, required this.segments, this.isRoute = false});

  final String? name;
  final String? description;
  final String? type;
  final List<List<GpxPoint>> segments;

  /// True when read from a `<rte>` (routes are exposed as single-segment tracks).
  final bool isRoute;

  Iterable<GpxPoint> get points => segments.expand((s) => s);
}

/// Minimal GPX 1.1 reader/writer covering what the app needs: tracks, routes
/// and waypoints. Unknown elements are ignored when parsing.
class Gpx {
  Gpx({this.name, this.description, this.time, this.tracks = const [], this.waypoints = const []});

  factory Gpx.parse(String xml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw FormatPepException('invalid GPX: ${e.message}');
    }
    final root = doc.rootElement;
    if (root.localName != 'gpx') throw const FormatPepException('invalid GPX: root is not <gpx>');
    final meta = _child(root, 'metadata');
    return Gpx(
      name: _text(meta, 'name'),
      description: _text(meta, 'desc'),
      time: _time(meta),
      waypoints: [for (final e in _children(root, 'wpt')) _waypoint(e)],
      tracks: [
        for (final t in _children(root, 'trk'))
          GpxTrack(
            name: _text(t, 'name'),
            description: _text(t, 'desc'),
            type: _text(t, 'type'),
            segments: [
              for (final s in _children(t, 'trkseg')) [for (final p in _children(s, 'trkpt')) _point(p)]
            ],
          ),
        for (final r in _children(root, 'rte'))
          GpxTrack(
            name: _text(r, 'name'),
            description: _text(r, 'desc'),
            type: _text(r, 'type'),
            isRoute: true,
            segments: [
              [for (final p in _children(r, 'rtept')) _point(p)]
            ],
          ),
      ],
    );
  }

  static const namespace = 'http://www.topografix.com/GPX/1/1';

  final String? name;
  final String? description;
  final DateTime? time;
  final List<GpxTrack> tracks;
  final List<GpxWaypoint> waypoints;

  /// RU objects (waypoints of type [GpxWaypoint.objectType]).
  Iterable<GpxWaypoint> get objects => waypoints.where((w) => w.isObject);

  String toXml({String creator = 'Parcours et Pistes', bool pretty = true}) {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element('gpx', namespaceUris: {null: namespace}, attributes: {'version': '1.1', 'creator': creator},
        nest: () {
      if (name != null || description != null || time != null) {
        b.element('metadata', nest: () {
          _opt(b, 'name', name);
          _opt(b, 'desc', description);
          _opt(b, 'time', time?.toUtc().toIso8601String());
        });
      }
      for (final w in waypoints) {
        _writePoint(b, 'wpt', w, () {
          _opt(b, 'name', w.name);
          _opt(b, 'desc', w.description);
          _opt(b, 'sym', w.symbol);
          _opt(b, 'type', w.type);
        });
      }
      for (final t in tracks) {
        b.element(t.isRoute ? 'rte' : 'trk', nest: () {
          _opt(b, 'name', t.name);
          _opt(b, 'desc', t.description);
          _opt(b, 'type', t.type);
          if (t.isRoute) {
            for (final p in t.points) {
              _writePoint(b, 'rtept', p);
            }
          } else {
            for (final s in t.segments) {
              b.element('trkseg', nest: () {
                for (final p in s) {
                  _writePoint(b, 'trkpt', p);
                }
              });
            }
          }
        });
      }
    });
    return b.buildDocument().toXmlString(pretty: pretty);
  }

  static void _writePoint(XmlBuilder b, String tag, GpxPoint p, [void Function()? extra]) {
    b.element(tag, attributes: {'lat': '${p.lat}', 'lon': '${p.lon}'}, nest: () {
      // GPX 1.1 schema order: ele, time, then name/desc/.../type.
      _opt(b, 'ele', p.ele?.toString());
      _opt(b, 'time', p.time?.toUtc().toIso8601String());
      extra?.call();
    });
  }

  static void _opt(XmlBuilder b, String tag, String? v) {
    if (v != null) b.element(tag, nest: v);
  }

  static Iterable<XmlElement> _children(XmlElement? e, String name) =>
      e?.childElements.where((c) => c.localName == name) ?? const [];

  static XmlElement? _child(XmlElement? e, String name) => _children(e, name).firstOrNull;

  static String? _text(XmlElement? e, String name) => _child(e, name)?.innerText.trim();

  static DateTime? _time(XmlElement? e) {
    final t = _text(e, 'time');
    return t == null ? null : DateTime.tryParse(t)?.toUtc();
  }

  static double _coord(XmlElement e, String attr) {
    final v = double.tryParse(e.getAttribute(attr) ?? '');
    if (v == null) throw FormatPepException('invalid GPX: <${e.localName}> lacks $attr');
    return v;
  }

  static GpxPoint _point(XmlElement e) => GpxPoint(_coord(e, 'lat'), _coord(e, 'lon'),
      ele: double.tryParse(_text(e, 'ele') ?? ''), time: _time(e));

  static GpxWaypoint _waypoint(XmlElement e) => GpxWaypoint(_coord(e, 'lat'), _coord(e, 'lon'),
      ele: double.tryParse(_text(e, 'ele') ?? ''),
      time: _time(e),
      name: _text(e, 'name'),
      description: _text(e, 'desc'),
      type: _text(e, 'type'),
      symbol: _text(e, 'sym'));
}
