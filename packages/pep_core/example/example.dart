// Runnable version of the README example, using the in-memory broker.
// With a real broker: Mqtt5Transport(BrokerConfig(Uri.parse('wss://…'))).
import 'package:pep_core/pep_core.dart';

// Everything about a track travels in the GPX: name, trail, RU objects
// (waypoints of type pep:object) and custom <extensions> in the pep namespace.
final gpxString = Gpx(
  name: 'Piste 1',
  waypoints: [
    GpxWaypoint.object(45.2001, 5.3002, name: 'Objet 1', extensions: [
      pepElement('note', text: 'gant en cuir'),
    ]),
  ],
  tracks: [
    GpxTrack(segments: [
      [GpxPoint(45.2000, 5.3000), GpxPoint(45.2005, 5.3005)]
    ]),
  ],
).toXml();

Future<void> main() async {
  final crypto = await PepCrypto.init();
  final broker = MemoryBroker();

  // Owner
  final owner = Identity.generate(crypto);
  final project = await ProjectSession.create(
    crypto: crypto, transport: MemoryTransport(broker), identity: owner,
    name: 'Forêt de Chambaran', discipline: Discipline.ru, password: 'secret',
  );
  await project.publishTrack(gpx: gpxString);
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
  final object = track.document.objects.single;
  print('participant sees track "${track.name}", object "${object.name}" '
      '(note: ${object.extensions.pep('note')?.innerText})');
  await session.publishPosition(Position(lat: 45.2, lon: 5.3, time: DateTime.now()));
  await Future<void>.delayed(const Duration(milliseconds: 50));

  await session.close();
  await project.deleteProject();
}
