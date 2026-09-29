// Runnable version of the README example, using the in-memory broker.
// With a real broker: Mqtt5Transport(BrokerConfig(Uri.parse('wss://…'))).
import 'package:pep_core/pep_core.dart';

const gpxString = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="example" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.2001" lon="5.3002"><name>Objet 1</name><type>pep:object</type></wpt>
  <trk><name>Piste 1</name><trkseg>
    <trkpt lat="45.2000" lon="5.3000"/><trkpt lat="45.2005" lon="5.3005"/>
  </trkseg></trk>
</gpx>''';

Future<void> main() async {
  final crypto = await PepCrypto.init();
  final broker = MemoryBroker();

  // Owner
  final owner = Identity.generate(crypto);
  final project = await ProjectSession.create(
    crypto: crypto, transport: MemoryTransport(broker), identity: owner,
    name: 'Forêt de Chambaran', discipline: Discipline.ru, password: 'secret',
  );
  await project.publishTrack(gpx: gpxString, name: 'Piste 1');
  final link = project.joinLink.toUri();
  print('join link: $link');

  // Participant
  final me = Identity.generate(crypto);
  final session = await ProjectSession.join(
    crypto: crypto, transport: MemoryTransport(broker), identity: me,
    link: JoinLink.parse(link), password: 'secret',
  );
  project.events.listen((e) {
    if (e case PositionUpdated(:final memberId, :final position)) {
      print('owner sees ${memberId.substring(0, 8)} at ${position.lat}, ${position.lon}');
    }
  });
  final track = session.tracks.values.first;
  print('participant sees track "${track.name}" with '
      '${Gpx.parse(track.gpx!).objects.length} object(s)');
  await session.publishPosition(Position(lat: 45.2, lon: 5.3, time: DateTime.now()));
  await Future<void>.delayed(const Duration(milliseconds: 50));

  await session.close();
  await project.deleteProject();
}
