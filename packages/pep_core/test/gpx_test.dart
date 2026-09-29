import 'package:pep_core/pep_core.dart';
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

  test('rejects invalid documents', () {
    for (final bad in [
      'not xml',
      '<kml/>',
      '<gpx><wpt lon="5"/></gpx>',
      '<gpx><trk><trkseg><trkpt lat="95" lon="5"/></trkseg></trk></gpx>',
    ]) {
      expect(() => Gpx.parse(bad), throwsA(isA<FormatPepException>()), reason: bad);
    }
  });
}
