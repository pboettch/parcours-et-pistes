import 'package:pep_content/pep_content.dart';
import 'package:test/test.dart';

const sample = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Some GPS" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:x="urn:vendor">
  <metadata><name>Forêt de Chambaran</name><time>2026-09-20T08:00:00Z</time></metadata>
  <wpt lat="45.2001" lon="5.3002"><ele>400</ele><name>Objet 1</name><type>pep:object</type></wpt>
  <wpt lat="45.2010" lon="5.3010"><name>Parking</name><sym>Parking Area</sym></wpt>
  <trk>
    <name>Piste RU</name>
    <extensions><x:color>red</x:color></extensions>
    <trkseg>
      <trkpt lat="45.2000" lon="5.3000"><ele>401.5</ele><time>2026-09-20T08:01:00Z</time></trkpt>
      <trkpt lat="45.2005" lon="5.3005"><ele>402</ele></trkpt>
    </trkseg>
    <trkseg><trkpt lat="45.2008" lon="5.3008"/></trkseg>
  </trk>
  <rte><name>Route</name><rtept lat="45.1" lon="5.1"/><rtept lat="45.2" lon="5.2"/></rte>
</gpx>''';

void main() {
  test('parses tracks, routes, waypoints and objects', () {
    final g = Gpx.parse(sample);
    expect(g.name, 'Forêt de Chambaran');
    expect(g.time, DateTime.utc(2026, 9, 20, 8));
    expect(g.waypoints, hasLength(2));
    expect(g.objects.single.name, 'Objet 1');
    expect(g.objects.single.ele, 400);
    expect(g.waypoints[1].symbol, 'Parking Area');
    expect(g.tracks, hasLength(2));
    final trk = g.tracks.first;
    expect(trk.name, 'Piste RU');
    expect(trk.segments.map((s) => s.length), [2, 1]);
    expect(trk.points.first.time, DateTime.utc(2026, 9, 20, 8, 1));
    expect(trk.points.first.ele, 401.5);
    expect(g.tracks[1].isRoute, isTrue);
    expect(g.tracks[1].points, hasLength(2));
  });

  test('write → parse round trip', () {
    final g = Gpx(
      name: 'MT',
      time: DateTime.utc(2026, 1, 2),
      waypoints: [GpxWaypoint.object(45.0, 5.0, name: 'Gant')],
      tracks: [
        GpxTrack(name: 'Trail', segments: [
          [GpxPoint(45.0, 5.0, ele: 300, time: DateTime.utc(2026, 1, 2, 10)), GpxPoint(45.001, 5.001)]
        ]),
        GpxTrack(name: 'R', isRoute: true, segments: [
          [GpxPoint(1, 2), GpxPoint(3, 4)]
        ]),
      ],
    );
    final xml = g.toXml();
    expect(xml, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
    final h = Gpx.parse(xml);
    expect(h.name, 'MT');
    expect(h.objects.single.name, 'Gant');
    expect(h.tracks.first.points.first.time, DateTime.utc(2026, 1, 2, 10));
    expect(h.tracks.first.points.last.lon, 5.001);
    expect(h.tracks[1].isRoute, isTrue);
    expect(Gpx.parse(h.toXml()).toXml(), xml);
  });

  extensionTests();

  test('rejects invalid documents', () {
    for (final bad in [
      'not xml',
      '<kml/>',
      '<gpx><wpt lon="5"/></gpx>',
      '<gpx><trk><trkseg><trkpt lat="95" lon="5"/></trkseg></trk></gpx>',
    ]) {
      expect(() => Gpx.parse(bad), throwsA(isA<ContentFormatException>()), reason: bad);
    }
  });
}

const withExtensions = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Garmin" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3"
     xmlns:pep="urn:parcours-et-pistes:gpx:1">
  <metadata>
    <name>Piste RU</name>
    <extensions><pep:trail level="2"><pep:note>Terrain humide</pep:note></pep:trail></extensions>
  </metadata>
  <wpt lat="45.2" lon="5.3">
    <name>Objet 1</name><type>pep:object</type>
    <extensions>
      <pep:object index="1" material="cuir"/>
      <gpxx:WaypointExtension><gpxx:Proximity>10</gpxx:Proximity></gpxx:WaypointExtension>
    </extensions>
  </wpt>
  <trk>
    <name>T</name>
    <extensions><gpxx:TrackExtension><gpxx:DisplayColor>Red</gpxx:DisplayColor></gpxx:TrackExtension></extensions>
    <trkseg><trkpt lat="45.1" lon="5.1"><extensions><pep:age minutes="30"/></extensions></trkpt></trkseg>
  </trk>
  <extensions><pep:app version="1"/></extensions>
</gpx>''';

void checkExtensions(Gpx g) {
  final trail = g.metadataExtensions.pep('trail')!;
  expect(trail.getAttribute('level'), '2');
  expect(trail.innerText.trim(), 'Terrain humide');
  final obj = g.objects.single;
  expect(obj.extensions.pep('object')!.getAttribute('material'), 'cuir');
  final garmin = obj.extensions.firstWhere((e) => e.name.local == 'WaypointExtension');
  expect(garmin.name.namespaceUri, 'http://www.garmin.com/xmlschemas/GpxExtensions/v3');
  expect(garmin.innerText.trim(), '10');
  expect(g.tracks.single.extensions.single.name.local, 'TrackExtension');
  expect(g.tracks.single.points.single.extensions.pep('age')!.getAttribute('minutes'), '30');
  expect(g.extensions.pep('app')!.getAttribute('version'), '1');
}

void extensionTests() {
  group('extensions (custom sections)', () {
    test('parsed at metadata, waypoint, track, point and file level', () {
      checkExtensions(Gpx.parse(withExtensions));
    });

    test('preserved on write, ours and foreign, with valid namespaces', () {
      final xml = Gpx.parse(withExtensions).toXml();
      final doc = XmlDocument.parse(xml);
      // Every prefixed element resolves to a namespace in the new document.
      for (final e in doc.descendantElements) {
        if (e.name.prefix != null) expect(e.name.namespaceUri, isNotNull, reason: e.name.qualified);
      }
      expect(xml, contains('xmlns:pep="$pepNamespace"'));
      expect(RegExp('xmlns:pep=').allMatches(xml).length, 1, reason: 'declared once on the root');
      checkExtensions(Gpx.parse(xml));
      expect(Gpx.parse(xml).toXml(), xml, reason: 'stable');
    });

    test('built with pepElement', () {
      final g = Gpx(
        name: 'MT',
        metadataExtensions: [pepElement('trail', attributes: {'kind': 'mt'}, children: [pepElement('note', text: 'x')])],
        waypoints: [
          GpxWaypoint.object(1, 2, name: 'O', extensions: [pepElement('object', attributes: {'index': '1'})])
        ],
      );
      final h = Gpx.parse(g.toXml());
      expect(h.metadataExtensions.pep('trail')!.getAttribute('kind'), 'mt');
      expect(h.metadataExtensions.pep('trail')!.findElements('note', namespaceUri: pepNamespace).single.innerText, 'x');
      expect(h.objects.single.extensions.pep('object')!.getAttribute('index'), '1');
      expect(g.metadataExtensions.pep('trail'), isNotNull, reason: 'lookup works on unattached elements');
    });

    test('copyWith keeps extensions', () {
      final g = Gpx.parse(withExtensions).copyWith(name: 'Renamed');
      expect(Gpx.parse(g.toXml()).name, 'Renamed');
      checkExtensions(Gpx.parse(g.toXml()));
    });
  });
}
