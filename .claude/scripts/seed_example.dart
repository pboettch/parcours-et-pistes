/// Creates an example project with simulated, fictional trails (no external
/// data): one track per trail, with objects, trail details (code, level,
/// setter) and parking places, plus one planned run. The same trails every
/// time (fixed seeds); a new project (UUID, password) on each run.
///
/// The owner identity, join link and password go to --out (default
/// build/example/ in the repo, ignored by git); the identity is reused on the
/// next run.
///
///   source .claude/scripts/env.sh
///   dart run .claude/scripts/seed_example.dart [--out DIR] [--broker URL] [--user U --broker-password P]
///
/// Default broker: the local dev broker (ws on 18080, reachable from the web app).
library;

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:pep_core/pep_core.dart';

/// Fictional trails in the Forêt de Chambaran: code, level, setter, lieu-dit,
/// start, length (m), objects, laid at.
final _trails = [
  ('V1', 'B', 'Camille', 'Les Fougères', (45.3150, 5.2050), 520.0, 2, DateTime.utc(2026, 6, 12, 7, 40)),
  ('V2', 'I', 'Dominique', 'Bois du Tilleul', (45.3215, 5.2180), 830.0, 3, DateTime.utc(2026, 6, 12, 8, 5)),
  ('S1', 'II', 'Sacha', 'Combe aux Renards', (45.3085, 5.2265), 1120.0, 4, DateTime.utc(2026, 6, 13, 7, 30)),
  ('S2', 'II', 'Camille', 'Étang Neuf', (45.3010, 5.2105), 1240.0, 4, DateTime.utc(2026, 6, 13, 7, 55)),
  ('D1', 'III', 'Alix', 'Croix des Bûcherons', (45.3270, 5.2015), 1650.0, 5, DateTime.utc(2026, 6, 14, 7, 20)),
];

Future<void> main(List<String> argv) async {
  final repo = File.fromUri(Platform.script).parent.parent.parent;
  final args =
      (ArgParser()
            ..addOption('out', defaultsTo: '${repo.path}/build/example')
            ..addOption('broker', defaultsTo: 'ws://127.0.0.1:18080')
            ..addOption('user')
            ..addOption('broker-password')
            ..addOption('name', defaultsTo: 'Exemple — Forêt de Chambaran'))
          .parse(argv);
  final out = Directory(args.option('out')!)..createSync(recursive: true);

  final crypto = await PepCrypto.init();
  final identityFile = File('${out.path}/owner.id');
  final Identity me;
  if (identityFile.existsSync()) {
    me = Identity.fromSeed(crypto, unb64u(identityFile.readAsStringSync().trim()));
  } else {
    me = Identity.generate(crypto);
    _writePrivate(identityFile, '${b64u(me.exportSeed())}\n');
  }

  final password = _password();
  final s = await ProjectSession.create(
    crypto: crypto,
    transport: Mqtt5Transport(
      BrokerConfig(
        Uri.parse(args.option('broker')!),
        username: args.option('user'),
        password: args.option('broker-password'),
      ),
    ),
    identity: me,
    name: args.option('name')!,
    description: 'Pistes RU fictives (simulées) pour le développement et les démos',
    discipline: Discipline.ru,
    password: password,
    linkBroker: args.option('broker'),
  );
  await s.setMemberName('Organisation');

  for (final (i, (code, level, setter, place, (lat, lon), length, objects, laid)) in _trails.indexed) {
    final start = GeoPoint(lat, lon);
    var gpx = simulateTrail(start, length: length, objects: objects, name: '$code · $place', laid: laid, seed: i + 1);
    gpx = gpx.copyWith(
      waypoints: [
        ...gpx.waypoints,
        ..._parkings(start, cyno: level != 'B', seed: i + 1),
      ],
    );
    gpx = TrailInfo(code: code, level: level, setter: setter).applyTo(gpx);
    final t = await s.publishTrack(id: code.toLowerCase(), gpx: gpx.toXml());
    stderr.writeln('  ${t.id}: ${t.name} — ${gpx.objects.length} objects, level $level, ${gpx.places.length} place(s)');
  }

  await s.putRun(
    Run(track: 'v1', dog: 'Rex', handler: 'Ana'),
    id: 'demo',
  );
  stderr.writeln('  run "demo": Rex / Ana on v1 (planned; designate a source, then "pep replay")');

  final link = s.joinLink.toUri().toString();
  final info = File('${out.path}/project.txt');
  _writePrivate(
    info,
    'link: $link\npassword: $password\nbroker: ${args.option('broker')}\nowner identity: ${identityFile.path}\n',
  );
  await s.close();
  stdout.writeln(link);
  stderr.writeln('link and password saved to ${info.path}');
  exit(0);
}

/// The minibus parking 120–250 m from the start and, except for brevets, the
/// cyno parking closer by.
List<GpxWaypoint> _parkings(GeoPoint start, {required bool cyno, required int seed}) {
  final r = Random(seed);
  const mPerDeg = earthRadius * pi / 180;
  GpxWaypoint at(double d, double heading, String name, String description) => GpxWaypoint.place(
    start.lat + d * cos(heading) / mPerDeg,
    start.lon + d * sin(heading) / (mPerDeg * cos(start.lat * pi / 180)),
    name: name,
    description: description,
  );
  final heading = r.nextDouble() * 2 * pi;
  return [
    at(120 + r.nextDouble() * 130, heading, 'Parking minibus', 'bord de route forestière'),
    if (cyno) at(40 + r.nextDouble() * 50, heading + r.nextDouble() - 0.5, 'Parking cyno', '2 véhicules max'),
  ];
}

/// Writes [content] to [file], readable by the user only (from before the
/// content is written).
void _writePrivate(File file, String content) {
  file.writeAsStringSync('');
  if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  file.writeAsStringSync(content);
}

/// A random, readable project password.
String _password() {
  const words = ['piste', 'truffe', 'forêt', 'objet', 'flair', 'sentier', 'chêne', 'renard', 'balise', 'mousse'];
  final r = Random.secure();
  return [for (var i = 0; i < 4; i++) words[r.nextInt(words.length)], r.nextInt(100)].join('-');
}
