/// Creates a private example project from a local copy of the CCO prototype
/// site (see .claude/memory/reference-cco-prototype.md): one track per trail
/// card, with objects from the waypoints, trail details (code, level, setter)
/// and the minibus/cyno parking as a place, plus one planned run.
///
/// The site data is private: nothing from it lives in this repository. The
/// join link and password are written next to the site copy.
///
///   source .claude/scripts/env.sh
///   dart run .claude/scripts/seed_cco.dart [--site DIR] [--broker URL] [--user U --broker-password P]
///
/// Default broker: the local dev broker (ws on 18080, reachable from the web app).
library;

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:pep_core/pep_core.dart';

Future<void> main(List<String> argv) async {
  final home = Platform.environment['HOME']!;
  final args =
      (ArgParser()
            ..addOption('site', defaultsTo: '$home/devel/cco-prototype/cco.chien-de-recherche.fr')
            ..addOption('broker', defaultsTo: 'ws://127.0.0.1:18080')
            ..addOption('user')
            ..addOption('broker-password')
            ..addOption('identity', help: 'Owner identity seed file (default: next to the site copy, created)')
            ..addOption('name', defaultsTo: 'CCO 2026 — exemple'))
          .parse(argv);
  final site = Directory(args.option('site')!);
  final index = File('${site.path}/index.html').readAsStringSync();

  final crypto = await PepCrypto.init();
  final identityFile = File(args.option('identity') ?? '${site.parent.path}/pep-example-owner.id');
  final Identity me;
  if (identityFile.existsSync()) {
    me = Identity.fromSeed(crypto, unb64u(identityFile.readAsStringSync().trim()));
  } else {
    me = Identity.generate(crypto);
    identityFile.writeAsStringSync('${b64u(me.exportSeed())}\n');
    if (!Platform.isWindows) Process.runSync('chmod', ['600', identityFile.path]);
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
    description: 'Parcours RU (Essonne) importés du prototype',
    discipline: Discipline.ru,
    password: password,
    linkBroker: args.option('broker'),
  );
  await s.setMemberName('Organisation');

  final cards = RegExp(r'<div class="card" id="(\w+)">(.*?)(?=<div class="card" id=|</div>\s*</body>|$)', dotAll: true);
  String? firstTrack;
  for (final m in cards.allMatches(index)) {
    final body = m[2]!;
    final badge = RegExp(r'class="badge[^"]*">([^<]*)<').firstMatch(body)![1]!; // "V1 · I"
    final desc = _unescape(RegExp(r'class="card-desc">([^<]*)<').firstMatch(body)![1]!);
    final gpxFile = RegExp(r'href="([^"]+\.gpx)"').firstMatch(body)![1]!;
    final [code, level] = badge.split('·').map((e) => e.trim()).toList();
    final setter = RegExp(r'Poseur:\s*(.*)$').firstMatch(desc)?[1]?.trim();
    final place = desc.replaceFirst(RegExp(r'\s*-\s*Poseur:.*$'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final places = [
      for (final p in RegExp(
        r'place-label">([^<]*)</span>(?:<span class="place-desc">([^<]*)</span>)?</div>'
        r'<a class="btn btn-nav" href="https://www.google.com/maps\?q=([-\d.]+),([-\d.]+)"',
      ).allMatches(body))
        if (p[1] != 'Départ' && p[1] != 'Arrivée') // the ends of the track
          GpxWaypoint.place(
            double.parse(p[3]!),
            double.parse(p[4]!),
            name: _unescape(p[1]!),
            description: p[2] == null ? null : _unescape(p[2]!),
          ),
    ];

    var gpx = objectsFromWaypoints(Gpx.parse(File('${site.path}/$gpxFile').readAsStringSync()));
    gpx = gpx.copyWith(name: '$code · $place', waypoints: [...gpx.waypoints, ...places]);
    gpx = TrailInfo(code: code, level: level, setter: setter).applyTo(gpx);
    final t = await s.publishTrack(id: code.toLowerCase(), gpx: gpx.toXml());
    firstTrack ??= t.id;
    stderr.writeln('  ${t.id}: ${t.name} — ${gpx.objects.length} objects, level $level, ${places.length} place(s)');
  }

  if (firstTrack != null) {
    await s.putRun(
      Run(track: firstTrack, dog: 'Rex', handler: 'Ana'),
      id: 'demo',
    );
    stderr.writeln('  run "demo": Rex / Ana on $firstTrack (planned; designate a source, then "pep replay")');
  }

  final link = s.joinLink.toUri().toString();
  final out = File('${site.parent.path}/pep-example-project.txt')
    ..writeAsStringSync(
      'link: $link\npassword: $password\nbroker: ${args.option('broker')}\nowner identity: ${identityFile.path}\n',
    );
  if (!Platform.isWindows) Process.runSync('chmod', ['600', out.path]);
  await s.close();
  stdout.writeln(link);
  stderr.writeln('link and password saved to ${out.path}');
  exit(0);
}

/// A random, readable project password.
String _password() {
  const words = ['piste', 'truffe', 'forêt', 'objet', 'flair', 'sentier', 'chêne', 'renard', 'balise', 'mousse'];
  final r = Random.secure();
  return [for (var i = 0; i < 4; i++) words[r.nextInt(words.length)], r.nextInt(100)].join('-');
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&#39;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');
