/// `pep`: command-line client for manual end-to-end testing of pep_core.
///
/// Run with `dart run pep_core:pep <command> ...` (build hooks provide libsodium).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';
import 'package:pep_core/pep_core.dart';

const _defaultBroker = 'mqtt://127.0.0.1:18883';

/// Options accepted before or after the command name.
ArgParser _common([ArgParser? p]) => (p ?? ArgParser())
  ..addOption('broker', abbr: 'b', help: 'Broker URL (default: from link, else $_defaultBroker)')
  ..addOption('user', help: 'Broker username')
  ..addOption('broker-password', help: 'Broker password')
  ..addOption('identity', help: 'Identity seed file (default: ${_defaultIdentityPath()})')
  ..addOption('password', abbr: 'p', help: 'Project password (or env PEP_PASSWORD, else prompt)')
  ..addOption('device', help: 'Device id for positions (several devices of one identity)');

/// Looks an option up on the command first, then globally.
typedef _Opt = String? Function(String name);

Future<void> main(List<String> argv) async {
  final parser = _common()..addFlag('help', abbr: 'h', negatable: false);

  parser
    ..addCommand('id', _common())
    ..addCommand('identity', _common()..addOption('passphrase', help: 'Export passphrase (else prompt)'))
    ..addCommand(
      'create',
      _common()
        ..addOption('name', mandatory: true)
        ..addOption('discipline', allowed: ['ru', 'mt'], defaultsTo: 'ru')
        ..addOption('description')
        ..addOption('ttl', help: 'Position TTL in seconds', defaultsTo: '1800')
        ..addMultiOption('gpx', help: 'GPX file(s) to publish')
        ..addOption('link-broker', help: 'Broker URL to embed in the link'),
    )
    ..addCommand('watch', _common())
    ..addCommand('info', _common())
    ..addCommand(
      'push',
      _common()
        ..addOption('gpx', mandatory: true)
        ..addOption('id', help: 'Update this track id')
        ..addOption('name', help: 'Set the GPX metadata name')
        ..addOption('description', help: 'Set the GPX metadata description')
        ..addMultiOption(
          'visible-to',
          help: 'Member ids allowed to see the track (default: everyone; update: unchanged)',
        )
        ..addFlag('everyone', negatable: false, help: 'Make the track visible to every member'),
    )
    ..addCommand('rm', _common())
    ..addCommand('export', _common()..addOption('out', defaultsTo: '.'))
    ..addCommand('pos', _common()..addOption('acc'))
    ..addCommand('name', _common()..addFlag('bot', negatable: false, help: 'Mark this member as automated'))
    ..addCommand(
      'run',
      _common()
        ..addOption('track', help: 'Track id (add)')
        ..addOption('dog', help: 'Dog name (add)')
        ..addOption('handler', help: 'Handler name (add)')
        ..addOption('source', help: 'Member sharing the dog position (add)'),
    )
    ..addCommand(
      'replay',
      _common()
        ..addOption('speed', help: 'Walking speed in m/s', defaultsTo: '0.8')
        ..addOption('rate', help: 'Time acceleration factor', defaultsTo: '1')
        ..addOption('interval', help: 'Seconds between positions', defaultsTo: '5')
        ..addOption('name', help: 'Display name to publish first')
        ..addFlag('bot', negatable: false, help: 'Publish the display name as a bot')
        ..addFlag('record', negatable: false, help: 'Always record the path (default: while run source)'),
    )
    ..addCommand('assign', _common()..addFlag('new', negatable: false, help: 'Reserve a new track id'))
    ..addCommand('delete', _common());

  late ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    _usage(parser, e.message);
  }
  final cmd = args.command;
  if (args.flag('help') || cmd == null) _usage(parser);

  String? opt(String name) => cmd.option(name) ?? args.option(name);

  final crypto = await PepCrypto.init();
  final me = _loadIdentity(crypto, opt('identity') ?? _defaultIdentityPath());

  // mqtt5_client may report a connection reset by the broker as an uncaught
  // error: keep running (the transport reconnects) instead of dying.
  final done = Completer<void>();
  final run = runZonedGuarded(() async {
    try {
      await _run(cmd, opt, crypto, me);
    } on PepException catch (e) {
      stderr.writeln('error: ${e.message}');
      exitCode = 1;
    } on TransportException catch (e) {
      stderr.writeln('error: ${e.message}');
      exitCode = 2;
    } catch (e) {
      stderr.writeln('error: $e');
      exitCode = 3;
    } finally {
      done.complete();
    }
  }, (e, _) => stderr.writeln('warning: $e'));
  if (run != null) unawaited(run); // never fails: errors are handled inside
  await done.future;
  exit(exitCode);
}

Future<void> _run(ArgResults cmd, _Opt opt, PepCrypto crypto, Identity me) async {
  final rest = cmd.rest;
  switch (cmd.name) {
    case 'id':
      print(me.id);
      stderr.writeln('fingerprint ${me.fingerprint}');
      return;

    case 'identity':
      // Export: prints the passphrase-protected identity (for a backup or
      // another device). Import: replaces the identity file with an export.
      final passphrase = cmd.option('passphrase') ?? _prompt('export passphrase: ');
      switch (rest) {
        case ['export']:
          print(IdentityExport.export(crypto, me, passphrase));
        case ['import', final exported]:
          final id = IdentityExport.import(crypto, exported, passphrase);
          _saveIdentity(id, opt('identity') ?? _defaultIdentityPath());
          print(id.id);
        default:
          throw const FormatPepException('usage: pep identity export | import <export>');
      }
      return;

    case 'create':
      final password = _password(opt);
      final s = await ProjectSession.create(
        crypto: crypto,
        transport: _transport(opt, null),
        identity: me,
        name: cmd.option('name')!,
        description: cmd.option('description'),
        discipline: Discipline.parse(cmd.option('discipline')!),
        password: password,
        positionTtl: Duration(seconds: int.parse(cmd.option('ttl')!)),
        linkBroker: cmd.option('link-broker'),
      );
      for (final f in cmd.multiOption('gpx')) {
        final t = await s.publishTrack(gpx: _readGpx(f));
        stderr.writeln('published track ${t.id} (${t.name})');
      }
      print(s.joinLink.toUri());
      await s.close();
      return;
  }

  if (rest.isEmpty) throw const FormatPepException('missing join link');
  final link = JoinLink.parse(rest.first);
  final s = await ProjectSession.join(
    crypto: crypto,
    transport: _transport(opt, link),
    identity: me,
    link: link,
    password: _password(opt),
    deviceId: opt('device'),
  );
  final extra = rest.skip(1).toList();

  switch (cmd.name) {
    case 'info':
      _printInfo(s);
      _printTracks(s);
      _printRuns(s);
    case 'watch':
      _printInfo(s);
      stderr.writeln('watching, Ctrl-C to stop');
      await _watch(s);
    case 'push':
      final t = await s.publishTrack(
        id: cmd.option('id'),
        gpx: _readGpx(cmd.option('gpx')!, name: cmd.option('name'), description: cmd.option('description')),
        visibleTo: cmd.multiOption('visible-to').isEmpty ? null : cmd.multiOption('visible-to').toSet(),
        everyone: cmd.flag('everyone'),
      );
      print('${t.id} rev ${t.rev}');
    case 'rm':
      if (extra.isEmpty) throw const FormatPepException('usage: pep rm <link> <track id>');
      await s.deleteTrack(extra.first);
    case 'export':
      final out = Directory(cmd.option('out')!)..createSync(recursive: true);
      for (final t in s.tracks.values) {
        final f = File('${out.path}/${_safe(t.name ?? t.id)}-${t.id}.gpx')..writeAsStringSync(t.gpx);
        print(f.path);
      }
    case 'pos':
      if (extra.length < 2) throw const FormatPepException('usage: pep pos <link> <lat> <lon>');
      await s.publishPosition(
        Position(
          lat: double.parse(extra[0]),
          lon: double.parse(extra[1]),
          time: DateTime.now().toUtc(),
          accuracy: cmd.option('acc') == null ? null : double.parse(cmd.option('acc')!),
        ),
      );
      await s.close(clearPosition: false);
      return;
    case 'name':
      if (extra.isEmpty) throw const FormatPepException('usage: pep name <link> <display name>');
      await s.setMemberName(extra.join(' '), bot: cmd.flag('bot'));
    case 'run':
      await _runCommand(s, cmd, extra);
    case 'replay':
      if (extra.length != 1) throw const FormatPepException('usage: pep replay <link> <gpx file>');
      await _replay(s, cmd, File(extra.single).readAsStringSync());
      return;
    case 'assign':
      final (track, member) = switch ((extra, cmd.flag('new'))) {
        ([final m], true) => (s.newTrackId(), m),
        ([final t, final m], false) => (t, m),
        _ => throw const FormatPepException('usage: pep assign <link> [--new] -- [<track id>] <member>|owner'),
      };
      await s.assignTrack(track, member == 'owner' ? null : member);
      print(track);
    case 'delete':
      await s.deleteProject();
      return;
  }
  await s.close();
}

Future<void> _watch(ProjectSession s) async {
  final done = Completer<void>();
  void stop() => done.isCompleted ? null : done.complete();
  unawaited(ProcessSignal.sigint.watch().first.then((_) => stop()));
  _printTracks(s);
  final sub = s.events.listen((e) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    switch (e) {
      case ProjectUpdated(:final project):
        print('$t project rev ${project.rev}: ${project.name}, ${project.trackOwners.length} assigned track(s)');
      case TrackUpdated(:final track):
        print(
          '$t track ${track.id} rev ${track.rev} "${track.name ?? ''}" by ${_who(s, track.signerId)}'
          ' (${_gpxSummary(track.gpx)})',
        );
      case TrackRemoved(:final trackId):
        print('$t track $trackId removed');
      case MemberUpdated(:final memberId, :final profile):
        print('$t member ${_short(memberId)} = ${profile.name}');
      case MemberRemoved(:final memberId):
        print('$t member ${_short(memberId)} removed');
      case PositionUpdated(:final memberId, :final position):
        print(
          '$t position ${_who(s, memberId)}: ${position.lat}, ${position.lon}'
          '${position.accuracy == null ? '' : ' ±${position.accuracy}m'}',
        );
      case PositionRemoved(:final memberId):
        print('$t position ${_who(s, memberId)} gone');
      case ProjectDeleted():
        print('$t project deleted');
        stop();
      case RunUpdated(:final runId, :final run):
        print('$t run $runId: ${_runSummary(s, runId, run)}');
      case RunRemoved(:final runId):
        print('$t run $runId removed');
      case PathUpdated(:final memberId):
        for (final r in s.runs.entries.where((r) => r.value.source == memberId)) {
          print('$t run ${r.key}: ${_runSummary(s, r.key, r.value)}');
        }
      case MessageRejected(:final topic, :final error):
        print('$t REJECTED $topic: $error');
    }
  });
  await done.future;
  await sub.cancel();
}

void _printInfo(ProjectSession s) {
  final p = s.project;
  print('project  ${p.name} (${p.discipline.name}) rev ${p.rev}');
  if (p.description != null) print('         ${p.description}');
  print('owner    ${_short(p.ownerId)}${s.isOwner ? ' (me)' : ''}');
  print('pos ttl  ${p.positionTtl.inSeconds}s');
}

void _printTracks(ProjectSession s) {
  for (final t in s.tracks.values) {
    final vis = t.visibleTo == null ? '' : ' visible to ${t.visibleTo!.map(_short).join(', ')}';
    print(
      'track    ${t.id} rev ${t.rev} "${t.name ?? ''}" (${_gpxSummary(t.gpx)}), owner ${_who(s, s.trackOwner(t.id))}$vis',
    );
  }
}

void _printRuns(ProjectSession s) {
  for (final r in s.runs.entries) {
    print('run      ${r.key}: ${_runSummary(s, r.key, r.value)}');
  }
}

String _runSummary(ProjectSession s, String id, Run r) {
  final p = s.runProgress(id);
  final progress = p == null ? 'track unknown' : (p.started ? '${(p.fraction * 100).round()}%' : 'not started');
  return '${r.dog}${r.handler == null ? '' : ' / ${r.handler}'} on ${r.track}, ${r.status.name}, '
      'source ${r.source == null ? '-' : _who(s, r.source!)}, $progress';
}

Future<void> _runCommand(ProjectSession s, ArgResults cmd, List<String> extra) async {
  switch (extra) {
    case ['add']:
      final track = cmd.option('track'), dog = cmd.option('dog');
      if (track == null || dog == null) throw const FormatPepException('run add needs --track and --dog');
      var run = Run(track: track, dog: dog, handler: cmd.option('handler'));
      if (cmd.option('source') case final m?) {
        publicKeyFromId(m); // a valid member id
        run = run.withSource(m, DateTime.now().toUtc());
      }
      print(await s.putRun(run));
    case ['list']:
      _printRuns(s);
    case ['source', final id, final member]:
      await s.setRunSource(id, member);
    case ['start', final id]:
      await s.startRun(id);
    case ['finish', final id]:
      await s.finishRun(id);
    case ['rm', final id]:
      await s.deleteRun(id);
    default:
      throw const FormatPepException(
        'usage: pep run <link> add --track T --dog D [--handler H] [--source M] | [--] list'
        ' | source <run> <member> | start <run> | finish <run> | rm <run>',
      );
  }
}

/// Walks along the first track of [gpx], publishing positions, until the end
/// of the track or Ctrl-C.
Future<void> _replay(ProjectSession s, ArgResults cmd, String gpx) async {
  final points = Gpx.parse(gpx).tracks.expand((t) => t.points).toList();
  if (points.isEmpty) throw const FormatPepException('the GPX file has no track points');
  if (cmd.option('name') case final n?) await s.setMemberName(n, bot: cmd.flag('bot'));
  if (cmd.flag('record')) s.pathMode = PathMode.always;
  final walker = TrailWalker(TrackLine(points), speed: double.parse(cmd.option('speed')!));
  final rate = double.parse(cmd.option('rate')!);
  final interval = Duration(milliseconds: (double.parse(cmd.option('interval')!) * 1000 / rate).round());
  var stop = false;
  final sig = ProcessSignal.sigint.watch().listen((_) => stop = true);
  final start = DateTime.now();
  stderr.writeln('walking ${walker.line.length.round()} m, ${walker.duration.inMinutes} min at x$rate; Ctrl-C to stop');
  while (!stop) {
    final elapsed = DateTime.now().difference(start) * rate;
    final p = walker.at(elapsed);
    await s.publishPosition(
      Position(lat: p.lat, lon: p.lon, time: DateTime.now().toUtc(), accuracy: 4 + math.Random().nextDouble() * 4),
    );
    stderr.write(
      '\r${(math.min(1, elapsed.inMilliseconds / walker.duration.inMilliseconds) * 100).round()}% '
      '${s.recordingPath ? '(recording)' : ''}   ',
    );
    if (walker.finishedAt(elapsed)) break;
    await Future<void>.delayed(interval);
  }
  stderr.writeln();
  await sig.cancel();
  await s.close(clearPosition: false);
}

String _gpxSummary(String gpx) {
  try {
    final g = Gpx.parse(gpx);
    return '${g.tracks.fold<int>(0, (n, t) => n + t.points.length)} points, ${g.objects.length} objects';
  } on PepException {
    return 'invalid GPX';
  }
}

String _short(String id) => id.substring(0, 8);

String _who(ProjectSession s, String id) {
  final name = s.members[id]?.name;
  return name == null ? _short(id) : '$name (${_short(id)})';
}

Transport _transport(_Opt opt, JoinLink? link) => Mqtt5Transport(
  BrokerConfig(
    Uri.parse(opt('broker') ?? link?.broker ?? _defaultBroker),
    username: opt('user'),
    password: opt('broker-password'),
  ),
);

String _password(_Opt opt) => opt('password') ?? Platform.environment['PEP_PASSWORD'] ?? _prompt('project password: ');

String _prompt(String label) {
  stderr.write(label);
  stdin.echoMode = false;
  try {
    return stdin.readLineSync(encoding: utf8) ?? '';
  } finally {
    stdin.echoMode = true;
    stderr.writeln();
  }
}

String _defaultIdentityPath() {
  final home = Platform.environment['HOME'] ?? '.';
  final cfg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  return '$cfg/pep/identity';
}

Identity _loadIdentity(PepCrypto c, String path) {
  final f = File(path);
  if (f.existsSync()) return Identity.fromSeed(c, unb64u(f.readAsStringSync().trim()));
  final id = Identity.generate(c);
  _saveIdentity(id, path);
  stderr.writeln('created identity ${id.id} in $path');
  return id;
}

void _saveIdentity(Identity id, String path) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${b64u(id.exportSeed())}\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
}

/// Reads a GPX file; sets the metadata name/description when given, and the
/// name from the file name when the GPX has none. Otherwise publishes it as is.
String _readGpx(String path, {String? name, String? description}) {
  final xml = File(path).readAsStringSync();
  final g = Gpx.parse(xml);
  if (name == null && description == null && (g.name != null || g.tracks.any((t) => t.name != null))) return xml;
  return g.copyWith(name: name ?? g.name ?? _basename(path), description: description).toXml();
}

String _basename(String path) => path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.gpx$'), '');

String _safe(String s) => s.replaceAll(RegExp(r'[^\w.-]+'), '_');

Never _usage(ArgParser p, [String? error]) {
  if (error != null) stderr.writeln('error: $error\n');
  stderr.writeln('''usage: pep [options] <command> [args]

commands:
  id                                  print this identity's member id (and fingerprint)
  identity export | import <export> [--passphrase P]
                                      passphrase-protected identity export (backup, other devices)
  create --name N [--discipline ru|mt] [--description D] [--ttl s] [--gpx f]... [--link-broker URL]
                                      create a project, print its join link (--ttl: position TTL)
  info <link>                         show project, tracks and runs
  watch <link>                        follow the project live: tracks, members, positions, runs,
                                      recorded paths, rejected messages
  push <link> --gpx f [--id T] [--name N] [--description D] [--visible-to M]... [--everyone]
                                      publish a track (owner), or update it (its owner)
  rm <link> [--] <track id>           delete a track (its owner)
  export <link> [--out dir]           write all tracks as .gpx files
  pos <link> <lat> <lon> [--acc m]    share a position
  name <link> <display name> [--bot]  set your display name (--bot: automated member)
  run <link> add --track T --dog D [--handler H] [--source M]   create a run (owner)
  run <link> [--] list | source <run> <member> | start <run> | finish <run> | rm <run>
                                      manage runs (owner); the source shares the dog's position
  replay <link> <gpx> [--speed m/s] [--rate x] [--interval s] [--name N] [--bot] [--record]
                                      simulate a dog walking the track (publishes positions)
  assign <link> [--new] -- [<track>] <member>|owner
                                      give a track (--new: a new track id) to its only writer
                                      (owner); prints the track id
  delete <link>                       delete the project from the broker (owner)

Put "--" before ids and member ids: they may start with "-".

options:
${p.usage}''');
  exit(64);
}
