/// `pep`: command-line client for manual end-to-end testing of pep_core.
///
/// Run with `dart run pep_core:pep <command> ...` (build hooks provide libsodium).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pep_core/pep_core.dart';

const _defaultBroker = 'mqtt://127.0.0.1:18883';

/// Options accepted before or after the command name.
ArgParser _common([ArgParser? p]) => (p ?? ArgParser())
  ..addOption('broker', abbr: 'b', help: 'Broker URL (default: from link, else $_defaultBroker)')
  ..addOption('user', help: 'Broker username')
  ..addOption('broker-password', help: 'Broker password')
  ..addOption('identity', help: 'Identity seed file (default: ${_defaultIdentityPath()})')
  ..addOption('password', abbr: 'p', help: 'Project password (or env PEP_PASSWORD, else prompt)');

/// Looks an option up on the command first, then globally.
typedef _Opt = String? Function(String name);

Future<void> main(List<String> argv) async {
  final parser = _common()..addFlag('help', abbr: 'h', negatable: false);

  parser
    ..addCommand('id', _common())
    ..addCommand(
        'create',
        _common()
          ..addOption('name', mandatory: true)
          ..addOption('discipline', allowed: ['ru', 'mt'], defaultsTo: 'ru')
          ..addOption('description')
          ..addOption('ttl', help: 'Position TTL in seconds', defaultsTo: '1800')
          ..addMultiOption('gpx', help: 'GPX file(s) to publish')
          ..addOption('link-broker', help: 'Broker URL to embed in the link'))
    ..addCommand('watch', _common())
    ..addCommand('info', _common())
    ..addCommand(
        'push',
        _common()
          ..addOption('gpx', mandatory: true)
          ..addOption('id', help: 'Update this track id')
          ..addOption('name', help: 'Set the GPX metadata name')
          ..addOption('description', help: 'Set the GPX metadata description'))
    ..addCommand('rm', _common())
    ..addCommand('export', _common()..addOption('out', defaultsTo: '.'))
    ..addCommand('pos', _common()..addOption('acc'))
    ..addCommand('name', _common())
    ..addCommand('editor', _common())
    ..addCommand('passwd', _common()..addOption('new', mandatory: true))
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

  try {
    await _run(cmd, opt, crypto, me);
  } on PepException catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
  } on TransportException catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 2;
  }
  exit(exitCode);
}

Future<void> _run(ArgResults cmd, _Opt opt, PepCrypto crypto, Identity me) async {
  final rest = cmd.rest;
  switch (cmd.name) {
    case 'id':
      print(me.id);
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
        settings: ProjectSettings(positionTtl: Duration(seconds: int.parse(cmd.option('ttl')!))),
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
  );
  final extra = rest.skip(1).toList();

  switch (cmd.name) {
    case 'info':
      _printInfo(s);
      _printTracks(s);
    case 'watch':
      _printInfo(s);
      stderr.writeln('watching, Ctrl-C to stop');
      await _watch(s);
    case 'push':
      final t = await s.publishTrack(
        id: cmd.option('id'),
        gpx: _readGpx(cmd.option('gpx')!, name: cmd.option('name'), description: cmd.option('description')),
      );
      print('${t.id} rev ${t.rev}');
    case 'rm':
      if (extra.isEmpty) throw const FormatPepException('usage: pep rm <link> <track id>');
      await s.deleteTrack(extra.first);
    case 'export':
      final out = Directory(cmd.option('out')!)..createSync(recursive: true);
      for (final t in s.tracks.values) {
        final f = File('${out.path}/${_safe(t.name ?? t.id)}-${t.id}.gpx')..writeAsStringSync(t.gpx!);
        print(f.path);
      }
    case 'pos':
      if (extra.length < 2) throw const FormatPepException('usage: pep pos <link> <lat> <lon>');
      await s.publishPosition(Position(
        lat: double.parse(extra[0]),
        lon: double.parse(extra[1]),
        time: DateTime.now().toUtc(),
        accuracy: cmd.option('acc') == null ? null : double.parse(cmd.option('acc')!),
      ));
      await s.close(clearPosition: false);
      return;
    case 'name':
      if (extra.isEmpty) throw const FormatPepException('usage: pep name <link> <display name>');
      await s.setMemberName(extra.join(' '));
    case 'editor':
      if (extra.length != 2 || !const {'add', 'remove'}.contains(extra[0])) {
        throw const FormatPepException('usage: pep editor <link> add|remove <member id>');
      }
      extra[0] == 'add' ? await s.addEditor(extra[1]) : await s.removeEditor(extra[1]);
    case 'passwd':
      await s.changePassword(cmd.option('new')!);
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
        print('$t project rev ${project.rev}: ${project.name}, editors ${project.editors.length}');
      case TrackUpdated(:final track, :final signerId):
        print('$t track ${track.id} rev ${track.rev} "${track.name ?? ''}" by ${_who(s, signerId)}'
            ' (${_gpxSummary(track.gpx!)})');
      case TrackRemoved(:final trackId):
        print('$t track $trackId removed');
      case MemberUpdated(:final memberId, :final member):
        print('$t member ${_short(memberId)} = ${member.name}');
      case MemberRemoved(:final memberId):
        print('$t member ${_short(memberId)} removed');
      case PositionUpdated(:final memberId, :final position):
        print('$t position ${_who(s, memberId)}: ${position.lat}, ${position.lon}'
            '${position.accuracy == null ? '' : ' ±${position.accuracy}m'}');
      case PositionRemoved(:final memberId):
        print('$t position ${_who(s, memberId)} gone');
      case PasswordChanged():
        print('$t password changed, session locked');
        stop();
      case ProjectDeleted():
        print('$t project deleted');
        stop();
      case MessageRejected(:final topic, :final error):
        print('$t REJECTED $topic: ${error.message}');
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
  print('editors  ${p.editors.map(_short).join(', ')}');
  print('pos ttl  ${p.settings.positionTtl.inSeconds}s');
}

void _printTracks(ProjectSession s) {
  for (final t in s.tracks.values) {
    print('track    ${t.id} rev ${t.rev} "${t.name ?? ''}" (${_gpxSummary(t.gpx!)})');
  }
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

Transport _transport(_Opt opt, JoinLink? link) => Mqtt5Transport(BrokerConfig(
      Uri.parse(opt('broker') ?? link?.broker ?? _defaultBroker),
      username: opt('user'),
      password: opt('broker-password'),
    ));

String _password(_Opt opt) {
  final p = opt('password') ?? Platform.environment['PEP_PASSWORD'];
  if (p != null) return p;
  stderr.write('project password: ');
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
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${b64u(id.exportSeed())}\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
  stderr.writeln('created identity ${id.id} in $path');
  return id;
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
  id                                  print this device's member id
  create --name N [--discipline ru|mt] [--gpx f]...   create a project, print its join link
  info <link>                         show project and tracks
  watch <link>                        follow tracks, members and positions live
  push <link> --gpx f [--id T] [--name N]   publish (or update) a track (owner/editor)
  rm <link> <track id>                delete a track (owner/editor)
  export <link> [--out dir]           write all tracks as .gpx files
  pos <link> <lat> <lon> [--acc m]    share a position
  name <link> <display name>          set your display name
  editor <link> add|remove -- <member>  manage editors (owner; "--" because ids may start with "-")
  passwd <link> --new P               change the project password (owner)
  delete <link>                       delete the project from the broker (owner)

options:
${p.usage}''');
  exit(64);
}
