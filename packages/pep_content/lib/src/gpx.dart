import 'package:xml/xml.dart';

import 'errors.dart';

/// GPX 1.1 namespace.
const gpxNamespace = 'http://www.topografix.com/GPX/1/1';

/// Namespace of Parcours et Pistes' custom GPX sections (prefix `pep`).
const pepNamespace = 'urn:parcours-et-pistes:gpx:1';
const pepPrefix = 'pep';

/// Creates an element of a custom section in the [pepNamespace], e.g.
/// `pepElement('object', attributes: {'index': '1'})` → `<pep:object index="1"/>`.
XmlElement pepElement(String localName,
        {Map<String, String> attributes = const {}, String? text, List<XmlNode> children = const []}) =>
    XmlElement(
      XmlName.parts(localName, prefix: pepPrefix, namespaceUri: pepNamespace),
      [for (final a in attributes.entries) XmlAttribute(XmlName.qualified(a.key), a.value)],
      [if (text != null) XmlText(text), ...children],
    );

/// Access to the custom sections among a list of `<extensions>` children.
extension GpxExtensionAccess on List<XmlElement> {
  /// Elements of our own namespace with the given local name.
  Iterable<XmlElement> pepAll(String localName) =>
      where((e) => e.name.local == localName && _namespaceOf(e) == pepNamespace);

  /// First element of our own namespace with the given local name.
  XmlElement? pep(String localName) => pepAll(localName).firstOrNull;
}

/// A GPX point (track point, route point or waypoint).
class GpxPoint {
  GpxPoint(this.lat, this.lon, {this.ele, this.time, this.extensions = const []}) {
    if (!(lat >= -90 && lat <= 90) || !(lon >= -180 && lon <= 180)) {
      throw ContentFormatException('GPX coordinates out of range: $lat, $lon');
    }
  }

  final double lat, lon;
  final double? ele;
  final DateTime? time;

  /// Children of the point's `<extensions>` (ours and other tools').
  final List<XmlElement> extensions;
}

/// A GPX waypoint. Objects placed along an RU track are waypoints of type
/// [objectType]; their additional information goes into [extensions].
class GpxWaypoint extends GpxPoint {
  GpxWaypoint(super.lat, super.lon,
      {super.ele,
      super.time,
      super.extensions,
      this.name,
      this.comment,
      this.description,
      this.type,
      this.symbol});

  /// `<type>` value marking an RU object.
  static const objectType = 'pep:object';

  factory GpxWaypoint.object(double lat, double lon,
          {String? name, String? description, DateTime? time, List<XmlElement> extensions = const []}) =>
      GpxWaypoint(lat, lon,
          name: name, description: description, type: objectType, time: time, extensions: extensions);

  final String? name;
  final String? comment;
  final String? description;
  final String? type;
  final String? symbol;

  bool get isObject => type == objectType;
}

class GpxTrack {
  GpxTrack({
    this.name,
    this.comment,
    this.description,
    this.type,
    required this.segments,
    this.isRoute = false,
    this.extensions = const [],
  });

  final String? name;
  final String? comment;
  final String? description;
  final String? type;
  final List<List<GpxPoint>> segments;

  /// True when read from a `<rte>` (routes are exposed as single-segment tracks).
  final bool isRoute;

  /// Children of the track's `<extensions>`.
  final List<XmlElement> extensions;

  Iterable<GpxPoint> get points => segments.expand((s) => s);
}

/// GPX 1.1 reader/writer: tracks, routes, waypoints and the `<extensions>`
/// sections of the file, its metadata, tracks/routes and points. Extension
/// content (ours in [pepNamespace] and other tools') is preserved on a
/// parse → write round trip; other unknown elements are dropped.
class Gpx {
  Gpx({
    this.name,
    this.description,
    this.time,
    this.tracks = const [],
    this.waypoints = const [],
    this.metadataExtensions = const [],
    this.extensions = const [],
  });

  factory Gpx.parse(String xml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw ContentFormatException('invalid GPX: ${e.message}');
    }
    final root = doc.rootElement;
    if (root.localName != 'gpx') throw const ContentFormatException('invalid GPX: root is not <gpx>');
    final meta = _child(root, 'metadata');
    return Gpx(
      name: _text(meta, 'name'),
      description: _text(meta, 'desc'),
      time: _time(meta),
      metadataExtensions: _extensions(meta),
      extensions: _extensions(root),
      waypoints: [for (final e in _children(root, 'wpt')) _waypoint(e)],
      tracks: [
        for (final t in _children(root, 'trk'))
          GpxTrack(
            name: _text(t, 'name'),
            comment: _text(t, 'cmt'),
            description: _text(t, 'desc'),
            type: _text(t, 'type'),
            extensions: _extensions(t),
            segments: [
              for (final s in _children(t, 'trkseg')) [for (final p in _children(s, 'trkpt')) _point(p)]
            ],
          ),
        for (final r in _children(root, 'rte'))
          GpxTrack(
            name: _text(r, 'name'),
            comment: _text(r, 'cmt'),
            description: _text(r, 'desc'),
            type: _text(r, 'type'),
            extensions: _extensions(r),
            isRoute: true,
            segments: [
              [for (final p in _children(r, 'rtept')) _point(p)]
            ],
          ),
      ],
    );
  }

  /// GPX metadata name: the name of the track as shown in the app.
  final String? name;

  /// GPX metadata description.
  final String? description;
  final DateTime? time;
  final List<GpxTrack> tracks;
  final List<GpxWaypoint> waypoints;

  /// Children of `<metadata><extensions>`: custom information about the whole
  /// track file (e.g. RU trail details).
  final List<XmlElement> metadataExtensions;

  /// Children of the root-level `<extensions>`.
  final List<XmlElement> extensions;

  /// RU objects (waypoints of type [GpxWaypoint.objectType]).
  Iterable<GpxWaypoint> get objects => waypoints.where((w) => w.isObject);

  Gpx copyWith({
    String? name,
    String? description,
    DateTime? time,
    List<GpxTrack>? tracks,
    List<GpxWaypoint>? waypoints,
    List<XmlElement>? metadataExtensions,
    List<XmlElement>? extensions,
  }) =>
      Gpx(
        name: name ?? this.name,
        description: description ?? this.description,
        time: time ?? this.time,
        tracks: tracks ?? this.tracks,
        waypoints: waypoints ?? this.waypoints,
        metadataExtensions: metadataExtensions ?? this.metadataExtensions,
        extensions: extensions ?? this.extensions,
      );

  String toXml({String creator = 'Parcours et Pistes', bool pretty = true}) {
    final root = XmlElement(XmlName.qualified('gpx', namespaceUri: gpxNamespace), [
      XmlAttribute(XmlName.qualified('version'), '1.1'),
      XmlAttribute(XmlName.qualified('creator'), creator),
      XmlAttribute(const XmlName.namespace(), gpxNamespace),
      XmlAttribute(const XmlName.namespace(name: pepPrefix), pepNamespace),
    ]);
    final c = root.children;
    if (name != null || description != null || time != null || metadataExtensions.isNotEmpty) {
      c.add(_el('metadata', [
        _opt('name', name),
        _opt('desc', description),
        _opt('time', time?.toUtc().toIso8601String()),
        _ext(metadataExtensions),
      ]));
    }
    for (final w in waypoints) {
      c.add(_pointEl('wpt', w, [
        _opt('name', w.name),
        _opt('cmt', w.comment),
        _opt('desc', w.description),
        _opt('sym', w.symbol),
        _opt('type', w.type),
      ]));
    }
    for (final t in tracks.where((t) => t.isRoute)) {
      c.add(_el('rte', [
        ..._trackHeader(t),
        _ext(t.extensions),
        for (final p in t.points) _pointEl('rtept', p),
      ]));
    }
    for (final t in tracks.where((t) => !t.isRoute)) {
      c.add(_el('trk', [
        ..._trackHeader(t),
        _ext(t.extensions),
        for (final s in t.segments) _el('trkseg', [for (final p in s) _pointEl('trkpt', p)]),
      ]));
    }
    if (extensions.isNotEmpty) c.add(_ext(extensions)!);
    final doc = XmlDocument([XmlProcessing('xml', 'version="1.0" encoding="UTF-8"'), root]);
    return doc.toXmlString(pretty: pretty, indent: '  ');
  }

  // ------------------------------------------------------------ writing

  /// Element with the given children; nulls are skipped.
  static XmlElement _el(String name, List<XmlElement?> children, [List<XmlAttribute> attrs = const []]) =>
      XmlElement(XmlName.qualified(name, namespaceUri: gpxNamespace), attrs, children.nonNulls);

  static XmlElement? _opt(String name, String? v) => v == null ? null : XmlElement(XmlName.qualified(name, namespaceUri: gpxNamespace), [], [XmlText(v)]);

  static List<XmlElement?> _trackHeader(GpxTrack t) =>
      [_opt('name', t.name), _opt('cmt', t.comment), _opt('desc', t.description), _opt('type', t.type)];

  static XmlElement? _ext(List<XmlElement> ext) =>
      ext.isEmpty ? null : _el('extensions', [for (final e in ext) _forOutput(e)]);

  static XmlElement _pointEl(String tag, GpxPoint p, [List<XmlElement?> extra = const []]) => _el(
        tag,
        [
          // GPX 1.1 schema order: ele, time, name, cmt, desc, …, sym, type, extensions.
          _opt('ele', p.ele?.toString()),
          _opt('time', p.time?.toUtc().toIso8601String()),
          ...extra,
          _ext(p.extensions),
        ],
        [XmlAttribute(XmlName.qualified('lat'), '${p.lat}'), XmlAttribute(XmlName.qualified('lon'), '${p.lon}')],
      );

  /// Copy for writing: our namespace is declared on the root, so drop a
  /// redundant local declaration of it.
  static XmlElement _forOutput(XmlElement e) {
    final copy = e.copy();
    copy.attributes.removeWhere((a) =>
        a.name.prefix == 'xmlns' && a.name.local == pepPrefix && a.value == pepNamespace);
    return copy;
  }

  // ------------------------------------------------------------ parsing

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
    if (v == null) throw ContentFormatException('invalid GPX: <${e.localName}> lacks $attr');
    return v;
  }

  /// Detached, self-contained copies of the children of [e]'s `<extensions>`.
  static List<XmlElement> _extensions(XmlElement? e) => List.unmodifiable([
        for (final x in _child(e, 'extensions')?.childElements ?? const <XmlElement>[]) _detach(x),
      ]);

  /// Copies [e] out of its document, declaring every namespace prefix used in
  /// the subtree on the copy itself (the declarations usually live on the
  /// source document's root) and dropping whitespace-only text.
  static XmlElement _detach(XmlElement e) {
    final used = <String, String>{};
    void collect(XmlElement n) {
      for (final name in [n.name, ...n.attributes.map((a) => a.name)]) {
        final p = name.prefix;
        if (p != null && p != 'xmlns' && p != 'xml') {
          final uri = name.namespaceUri;
          if (uri != null) used[p] = uri;
        }
      }
      if (n.name.prefix == null && n.name.namespaceUri != null) used[''] = n.name.namespaceUri!;
      n.childElements.forEach(collect);
    }

    collect(e);
    final copy = e.copy();
    void strip(XmlNode n) {
      if (n.children.length > 1) {
        n.children.removeWhere((c) => c is XmlText && c.value.trim().isEmpty);
      }
      n.children.whereType<XmlElement>().forEach(strip);
    }

    strip(copy);
    for (final u in used.entries) {
      final attr = u.key.isEmpty ? const XmlName.namespace() : XmlName.namespace(name: u.key);
      if (copy.getAttributeNode(attr.qualified) == null && !(u.key.isEmpty && u.value == gpxNamespace)) {
        copy.attributes.add(XmlAttribute(attr, u.value));
      }
    }
    return copy;
  }

  static GpxPoint _point(XmlElement e) => GpxPoint(_coord(e, 'lat'), _coord(e, 'lon'),
      ele: double.tryParse(_text(e, 'ele') ?? ''), time: _time(e), extensions: _extensions(e));

  static GpxWaypoint _waypoint(XmlElement e) => GpxWaypoint(_coord(e, 'lat'), _coord(e, 'lon'),
      ele: double.tryParse(_text(e, 'ele') ?? ''),
      time: _time(e),
      extensions: _extensions(e),
      name: _text(e, 'name'),
      comment: _text(e, 'cmt'),
      description: _text(e, 'desc'),
      type: _text(e, 'type'),
      symbol: _text(e, 'sym'));
}

/// Namespace URI of [e]: resolved in its document, or from a declaration on
/// the element itself when detached (e.g. built with [pepElement]).
String? _namespaceOf(XmlElement e) {
  final resolved = e.name.namespaceUri;
  if (resolved != null) return resolved;
  final p = e.name.prefix;
  if (p == pepPrefix) return pepNamespace; // pepElement() without explicit declaration
  return p == null ? e.getAttribute('xmlns') : e.getAttribute('xmlns:$p');
}
