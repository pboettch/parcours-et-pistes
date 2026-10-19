import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

/// Environment for session tests: transports on one broker, optional fake clock.
abstract class SessionHarness {
  Transport transport();
  DateTime Function()? get clock;
  void advance(Duration d);
  Map<String, Uint8List>? get retained;
  List<(String, Uint8List)>? get log;
}

Future<void> eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for ${reason ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 300));

PepCrypto? _crypto;
Future<PepCrypto> testCrypto() async => _crypto ??= await PepCrypto.init();
KdfParams fastKdf(PepCrypto c) => KdfParams.generate(c, opsLimit: KdfParams.minOps, memLimit: KdfParams.minMem);

const gpxA = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1" xmlns:pep="urn:parcours-et-pistes:gpx:1">
  <wpt lat="45.2001" lon="5.3002"><name>Objet 1</name><type>pep:object</type>
    <extensions><pep:object material="cuir"/></extensions></wpt>
  <trk><name>Secret forest trail</name><trkseg>
    <trkpt lat="45.2000" lon="5.3000"/><trkpt lat="45.2005" lon="5.3005"/>
  </trkseg></trk>
</gpx>''';

final gpxB = gpxA.replaceAll('45.2005', '45.2105');

/// Metres per degree of latitude.
const _mPerDeg = earthRadius * 3.141592653589793 / 180;

/// A point [north] metres north of (45.2, 5.3).
GeoPoint north(double m) => GeoPoint(45.2 + m / _mPerDeg, 5.3);

/// A straight 600 m track heading north.
final lineGpx = Gpx(
  name: 'Ligne droite',
  tracks: [
    GpxTrack(
      segments: [
        [for (var m = 0.0; m <= 600; m += 50) GpxPoint(north(m).lat, north(m).lon)],
      ],
    ),
  ],
).toXml();

/// [gpx] with a GPX metadata name (the track's display name).
String named(String gpx, String name) =>
    gpx.replaceFirstMapped(RegExp(r'<gpx[^>]*>'), (m) => '${m[0]}<metadata><name>$name</name></metadata>');

void sessionContract(String name, SessionHarness Function() harnessFactory) {
  group('ProjectSession ($name)', () {
    late PepCrypto c;
    late SessionHarness h;
    late Identity ownerId, aliceId, bobId;
    final sessions = <ProjectSession>[];
    final events = <ProjectSession, List<SessionEvent>>{};

    setUpAll(() async => c = await testCrypto());

    setUp(() {
      h = harnessFactory();
      ownerId = Identity.generate(c);
      aliceId = Identity.generate(c);
      bobId = Identity.generate(c);
    });

    tearDown(() async {
      for (final s in sessions) {
        if (s.isOwner) {
          try {
            await s.deleteProject();
          } on StateError {
            // already closed
          }
        }
        await s.close();
      }
      sessions.clear();
      events.clear();
    });

    ProjectSession track(ProjectSession s) {
      sessions.add(s);
      final list = events[s] = [];
      s.events.listen(list.add);
      return s;
    }

    Future<ProjectSession> create({
      String password = 'pw-1',
      Duration ttl = const Duration(minutes: 10),
      Transport? transport,
    }) async => track(
      await ProjectSession.create(
        crypto: c,
        transport: transport ?? h.transport(),
        identity: ownerId,
        name: 'Forêt de Chambaran',
        description: 'Entraînement du samedi',
        discipline: Discipline.ru,
        password: password,
        positionTtl: ttl,
        kdf: fastKdf(c),
        clock: h.clock,
        pruneInterval: const Duration(hours: 1),
        pathInterval: null,
      ),
    );

    Future<ProjectSession> join(
      ProjectSession owner,
      Identity who, {
      String password = 'pw-1',
      JoinLink? link,
      Duration timeout = const Duration(seconds: 5),
      String? deviceId,
      Transport? transport,
    }) async => track(
      await ProjectSession.join(
        crypto: c,
        transport: transport ?? h.transport(),
        identity: who,
        link: link ?? JoinLink.parse(owner.joinLink.toUri()),
        password: password,
        timeout: timeout,
        clock: h.clock,
        pruneInterval: const Duration(hours: 1),
        deviceId: deviceId,
        pathInterval: null,
      ),
    );

    DateTime now() => (h.clock ?? DateTime.now)().toUtc();

    /// Lets time pass (fake clock), so that successive steps get distinct times.
    Future<void> tick([Duration d = const Duration(seconds: 10)]) async {
      if (h.clock != null) {
        h.advance(d);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    /// [s] walks through the given distances along [lineGpx].
    Future<void> walk(ProjectSession s, Iterable<double> metres) async {
      for (final m in metres) {
        await s.publishPosition(Position(lat: north(m).lat, lon: north(m).lon, time: now(), accuracy: 5));
        await tick();
      }
    }

    test('create and join: project, owner, link', () async {
      final o = await create();
      expect(o.isOwner, isTrue);
      expect(o.canEditTrack('any'), isTrue);
      expect(o.project.name, 'Forêt de Chambaran');
      expect(o.project.description, 'Entraînement du samedi');
      expect(o.project.discipline, Discipline.ru);
      expect(o.project.ownerId, ownerId.id);
      expect(o.project.positionTtl, const Duration(minutes: 10));
      expect(o.channel.acl.collections.keys, unorderedEquals(PepCollections.defaults().keys));
      final a = await join(o, aliceId);
      expect(a.isOwner, isFalse);
      expect(a.canEditTrack('any'), isFalse);
      expect(a.project.name, 'Forêt de Chambaran');
      expect(a.projectId, o.projectId);
    });

    test('tracks: GPX content, objects and custom sections travel intact', () async {
      final o = await create();
      final t1 = await o.publishTrack(gpx: named(gpxA, 'Trail 1'));
      expect(t1.name, 'Trail 1');
      final a = await join(o, aliceId);
      final t = a.tracks[t1.id]!;
      expect(t.gpx, named(gpxA, 'Trail 1'), reason: 'byte for byte');
      expect(t.name, 'Trail 1');
      expect(t.signerId, ownerId.id);
      final obj = t.document.objects.single;
      expect(obj.name, 'Objet 1');
      expect(obj.extensions.pep('object')!.getAttribute('material'), 'cuir');

      final t2 = await o.publishTrack(gpx: gpxB);
      await eventually(() => a.tracks.containsKey(t2.id));
      expect(a.tracks[t2.id]!.name, 'Secret forest trail', reason: 'fallback to the <trk> name');
      expect(events[a]!.whereType<TrackUpdated>().map((e) => e.track.id), contains(t2.id));
    });

    test('track update and delete', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final t = await o.publishTrack(gpx: named(gpxA, 'v1'));
      await eventually(() => a.tracks[t.id]?.name == 'v1');
      await o.publishTrack(id: t.id, gpx: named(gpxB, 'v2'));
      await eventually(() => a.tracks[t.id]?.name == 'v2');
      expect(a.tracks[t.id]!.rev, 2);
      await o.deleteTrack(t.id);
      await eventually(() => !a.tracks.containsKey(t.id));
      expect(events[a]!.whereType<TrackRemoved>().single.trackId, t.id);
      expect((await join(o, bobId)).tracks, isEmpty);
    });

    test('invalid GPX: refused on publish, rejected on receipt', () async {
      final o = await create();
      await expectLater(o.publishTrack(gpx: 'not gpx'), throwsA(isA<ContentFormatException>()));
      final a = await join(o, aliceId);
      // An app with a bug publishes a validly signed but broken track.
      await o.channel.put(PepCollections.track, 'broken', utf8Bytes('<kml/>'));
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(events[a]!.whereType<MessageRejected>().single.error, isA<ContentFormatException>());
      expect(a.tracks, isEmpty);
      expect(o.tracks, isEmpty);
    });

    test('track owners: one per track, assigned by the project owner', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final b = await join(o, bobId);
      await expectLater(a.publishTrack(gpx: gpxA), throwsA(isA<AuthorizationException>()));
      await expectLater(a.updateProject(name: 'x'), throwsA(isA<AuthorizationException>()));
      await expectLater(a.assignTrack('x', aliceId.id), throwsA(isA<AuthorizationException>()));
      final t = await o.publishTrack(gpx: named(gpxA, 'by owner'));
      final reserved = o.newTrackId();
      await o.assignTrack(t.id, aliceId.id);
      await o.assignTrack(reserved, aliceId.id); // before the track exists
      await eventually(() => a.canEditTrack(t.id) && a.canEditTrack(reserved), reason: 'alice owns both');
      await eventually(() => events[b]!.whereType<ProjectUpdated>().any((e) => e.project.trackOwners.length == 2));
      expect(b.trackOwner(t.id), aliceId.id);
      expect(o.canEditTrack(t.id), isFalse);
      await expectLater(o.publishTrack(id: t.id, gpx: gpxB), throwsA(isA<AuthorizationException>()));
      await a.publishTrack(id: t.id, gpx: named(gpxA, 'by alice'));
      await a.publishTrack(id: reserved, gpx: named(gpxB, 'new by alice'));
      await expectLater(a.publishTrack(gpx: gpxB), throwsA(isA<AuthorizationException>()), reason: 'new: owner');
      await eventually(() => b.tracks[t.id]?.signerId == aliceId.id && b.tracks.containsKey(reserved));

      // Reassigned to bob: alice can no longer change it; it stays valid for everyone.
      await o.assignTrack(t.id, bobId.id);
      await eventually(() => b.canEditTrack(t.id) && !a.canEditTrack(t.id));
      await expectLater(a.publishTrack(id: t.id, gpx: gpxB), throwsA(isA<AuthorizationException>()));
      final later = await join(o, Identity.generate(c));
      expect(later.tracks[t.id]?.name, 'by alice');
      expect(events[later]!.whereType<MessageRejected>(), isEmpty);
      await b.deleteTrack(t.id);
      await eventually(() => !o.tracks.containsKey(t.id));
      await o.assignTrack(reserved, null); // back to the project owner
      expect(o.canEditTrack(reserved), isTrue);
      await o.publishTrack(id: reserved, gpx: named(gpxB, 'by owner again'));
    });

    test('members and positions', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.setMemberName('Alice & Rex');
      await o.setMemberName('Owner');
      await a.publishPosition(Position(lat: 45.2, lon: 5.3, time: now(), accuracy: 5));
      await eventually(() => o.members[aliceId.id]?.name == 'Alice & Rex' && o.positions.containsKey(aliceId.id));
      await eventually(() => a.members[ownerId.id]?.name == 'Owner');
      expect(o.positions[aliceId.id]!.accuracy, 5);
      await a.publishPosition(Position(lat: 45.21, lon: 5.31, time: now()));
      await eventually(() => o.positions[aliceId.id]?.lat == 45.21);
      await a.clearPosition();
      await eventually(() => !o.positions.containsKey(aliceId.id));
      expect(events[o]!.whereType<PositionRemoved>(), isNotEmpty);
    });

    test('close clears the position shared by this session only', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.publishPosition(Position(lat: 1, lon: 2, time: now()));
      final a2 = await join(o, aliceId);
      await eventually(() => o.positions.containsKey(aliceId.id));
      sessions.remove(a2);
      await a2.close();
      await settle();
      expect(o.positions.containsKey(aliceId.id), isTrue);
      sessions.remove(a);
      await a.close();
      await eventually(() => !o.positions.containsKey(aliceId.id));
    });

    test('project updates: name, description, position TTL', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await o.updateProject(name: 'Nouveau nom', positionTtl: const Duration(minutes: 3));
      await eventually(() => a.project.name == 'Nouveau nom' && a.project.positionTtl == const Duration(minutes: 3));
      expect(a.project.description, 'Entraînement du samedi');
      expect(a.project.rev, 2);
      expect(events[a]!.whereType<ProjectUpdated>(), isNotEmpty);
    });

    test('positions expire after the project TTL', () async {
      if (h.clock == null) return markTestSkipped('needs a controllable clock');
      final o = await create(ttl: const Duration(minutes: 1));
      final a = await join(o, aliceId);
      await a.publishPosition(Position(lat: 1, lon: 2, time: now()));
      await eventually(() => o.positions.containsKey(aliceId.id));
      h.advance(const Duration(seconds: 61));
      expect(o.positions, isEmpty);
      o.prunePositions();
      await eventually(() => events[o]!.whereType<PositionRemoved>().isNotEmpty);
    });

    test('wrong password and unknown project', () async {
      final o = await create();
      await expectLater(join(o, aliceId, password: 'nope'), throwsA(isA<WrongPasswordException>()));
      await expectLater(
        join(
          o,
          aliceId,
          link: JoinLink(channelId: newUuid(c), ownerId: ownerId.id),
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<ProjectNotFoundException>()),
      );
    });

    test('deleteProject notifies participants', () async {
      final o = await create();
      await o.publishTrack(gpx: gpxA);
      final a = await join(o, aliceId);
      sessions.remove(o);
      await o.deleteProject();
      await eventually(() => events[a]!.whereType<ProjectDeleted>().isNotEmpty);
      await expectLater(
        join(o, bobId, timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ProjectNotFoundException>()),
      );
    });

    test('content types unknown to this version are ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      // A newer app version adds a "photo" collection to the project.
      await o.channel.updateAcl(
        collections: {...o.channel.acl.collections, 'photo': const CollectionPolicy(Writers.owner)},
      );
      await o.channel.put('photo', 'p1', utf8Bytes('jpeg…'));
      await eventually(() => a.channel.items('photo').containsKey('p1'), reason: 'channel carries it');
      await settle();
      expect(events[a]!.whereType<MessageRejected>(), isEmpty);
      expect(a.tracks, isEmpty);
    });

    test('track visibility: hidden tracks are invisible to other members', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final b = await join(o, bobId);
      final hidden = await o.publishTrack(gpx: named(gpxA, 'for alice'), visibleTo: {aliceId.id});
      expect(hidden.visibleTo, {aliceId.id, ownerId.id});
      final open = await o.publishTrack(gpx: named(gpxB, 'for everyone'));
      expect(open.visibleTo, isNull);
      await eventually(() => a.tracks.length == 2 && b.tracks.length == 1);
      expect(b.tracks.keys, [open.id]);
      expect(a.tracks[hidden.id]!.name, 'for alice');
      // An update without visibleTo keeps the visibility.
      await o.publishTrack(id: hidden.id, gpx: named(gpxA, 'still for alice'));
      await eventually(() => a.tracks[hidden.id]?.name == 'still for alice');
      expect(b.tracks.containsKey(hidden.id), isFalse);
      // Sharing it with bob later.
      await o.publishTrack(id: hidden.id, gpx: named(gpxA, 'for alice'), visibleTo: {aliceId.id, bobId.id});
      await eventually(() => b.tracks.containsKey(hidden.id));
      expect(events[b]!.whereType<TrackUpdated>().map((e) => e.track.id), contains(hidden.id));
    });

    test('device ids are checked before any channel exists', () async {
      await expectLater(
        ProjectSession.create(
          crypto: c,
          transport: h.transport(),
          identity: ownerId,
          name: 'x',
          discipline: Discipline.ru,
          password: 'pw',
          kdf: fastKdf(c),
          deviceId: 'not.valid',
        ),
        throwsArgumentError,
      );
    });

    test('a last full-track segment this version cannot read does not block the device', () async {
      final o = await create();
      final a = await join(o, aliceId, deviceId: 'phone');
      await a.channel.put(
        PepCollections.path,
        a.channel.selfItemId(device: 'f0-phone'),
        utf8Bytes('{"v":2,"p":"a newer format"}'),
      );
      sessions.remove(a);
      await a.close();
      final a2 = await join(o, aliceId, deviceId: 'phone');
      a2.pathMode = PathMode.always;
      await walk(a2, [0]);
      expect(await a2.flushPath(), isTrue);
      await eventually(() => o.path(aliceId.id).length == 1);
      expect(o.channel.items(PepCollections.path), hasLength(2), reason: 'the unreadable segment is left as it is');
    });

    test('a deleteProject that fails (offline) keeps the session and its recorded points', () async {
      final t = h.transport();
      final o = await create(transport: t);
      o.pathMode = PathMode.always;
      await walk(o, [0]);
      await t.disconnect();
      await expectLater(
        o.publishPosition(Position(lat: north(10).lat, lon: 5.3, time: now(), accuracy: 5)),
        throwsA(isA<TransportException>()),
      );
      await expectLater(o.deleteProject(), throwsA(isA<TransportException>()));
      expect(o.pathPending, isTrue, reason: 'the offline point is still waiting');
      await t.connect();
      expect(await o.flushPath(), isTrue);
      expect(o.path(ownerId.id), hasLength(2));
      sessions.remove(o);
      await o.deleteProject();
    });

    test('deleteProject: only by the owner, and leaves the recorder of others alone', () async {
      final o = await create();
      final a = await join(o, aliceId);
      a.pathMode = PathMode.always;
      await walk(a, [0]);
      await expectLater(a.deleteProject(), throwsA(isA<AuthorizationException>()));
      expect(a.pathPending, isFalse);
      await walk(a, [10]);
      await a.flushPath();
      await eventually(() => o.path(aliceId.id).length == 2, reason: 'same full track, not a new one');
      expect(o.channel.items(PepCollections.path), hasLength(1));
    });

    test('positions from several devices of one member', () async {
      final o = await create();
      final phone = track(
        await ProjectSession.join(
          crypto: c,
          transport: h.transport(),
          identity: aliceId,
          link: JoinLink.parse(o.joinLink.toUri()),
          password: 'pw-1',
          clock: h.clock,
          deviceId: 'phone',
        ),
      );
      final watch = track(
        await ProjectSession.join(
          crypto: c,
          transport: h.transport(),
          identity: aliceId,
          link: JoinLink.parse(o.joinLink.toUri()),
          password: 'pw-1',
          clock: h.clock,
          deviceId: 'watch',
        ),
      );
      await phone.publishPosition(Position(lat: 45.1, lon: 5.1, time: now()));
      await eventually(() => o.positions[aliceId.id]?.lat == 45.1);
      if (h.clock != null) h.advance(const Duration(seconds: 1));
      await watch.publishPosition(Position(lat: 45.2, lon: 5.2, time: now()));
      await eventually(() => o.positions[aliceId.id]?.lat == 45.2, reason: 'latest device wins');
      expect(o.channel.items(PepCollections.position), hasLength(2));
      await watch.clearPosition();
      await eventually(() => o.positions[aliceId.id]?.lat == 45.1, reason: 'phone position still shared');
      expect(events[o]!.whereType<PositionRemoved>(), isEmpty);
      await phone.clearPosition();
      await eventually(() => !o.positions.containsKey(aliceId.id));
      await eventually(() => events[o]!.whereType<PositionRemoved>().single.memberId == aliceId.id);
    });

    test('member events carry member ids, not topic pseudonyms', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.setMemberName('Alice');
      await eventually(() => events[o]!.whereType<MemberUpdated>().any((e) => e.memberId == aliceId.id));
      await a.channel.delete(PepCollections.member, a.channel.selfItemId());
      await eventually(() => events[o]!.whereType<MemberRemoved>().any((e) => e.memberId == aliceId.id));
    });

    test('runs: the designated source records the dog path; progress', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final b = await join(o, bobId);
      await a.setMemberName('Alice');
      final t = await o.publishTrack(gpx: lineGpx);
      final runId = await o.putRun(Run(track: t.id, dog: 'Rex', handler: 'Ana'));
      await eventually(() => a.runs.containsKey(runId) && b.runs.containsKey(runId));
      expect(a.runs[runId]!.status, RunStatus.planned);
      expect(a.recordingPath, isFalse);
      expect(o.runProgress(runId)!.started, isFalse);
      expect(o.runProgress('nope'), isNull);
      expect(o.dogPath('nope'), isEmpty);
      await expectLater(a.putRun(Run(track: t.id, dog: 'Max')), throwsA(isA<AuthorizationException>()));
      await expectLater(o.startRun('nope'), throwsArgumentError);

      await o.setRunSource(runId, aliceId.id);
      await o.startRun(runId);
      await eventually(() => a.recordingPath && a.runs[runId]!.status == RunStatus.running);
      await tick();
      await walk(a, [for (var m = 0.0; m <= 200; m += 40) m]);
      await eventually(() => o.path(aliceId.id).length == 6, reason: 'rolling points');
      expect(o.channel.items(PepCollections.pathPoint), hasLength(6));
      expect(o.channel.items(PepCollections.path), hasLength(1), reason: 'and the full track');
      expect(events[o]!.whereType<PathUpdated>().map((e) => e.memberId), contains(aliceId.id));
      await walk(b, [300]); // not the source: not recorded
      expect(b.recordingPath, isFalse);

      // The official follower changes: bob shares the dog's position from now on.
      await o.setRunSource(runId, bobId.id);
      await eventually(() => b.recordingPath && !a.recordingPath);
      await tick();
      await walk(b, [for (var m = 240.0; m <= 400; m += 40) m]);
      await walk(a, [550]); // no longer the source
      await eventually(() => o.dogPath(runId).length == 11, reason: 'both sources, each over its period');
      expect(o.path(aliceId.id), hasLength(6));
      final p = o.runProgress(runId)!;
      expect(p.started, isTrue);
      expect(p.progress, closeTo(400, 2));
      expect(p.fraction, closeTo(400 / 600, 0.01));

      await o.finishRun(runId);
      await eventually(() => !b.recordingPath);
      expect(o.runs[runId]!.sources.map((s) => s.memberId), [aliceId.id, bobId.id]);
      expect(events[a]!.whereType<RunUpdated>(), isNotEmpty);

      // Someone joining later sees the same path.
      final late = await join(o, aliceId, deviceId: 'tablet');
      expect(late.dogPath(runId), hasLength(11));
      expect(late.runProgress(runId)!.progress, closeTo(400, 2));

      await o.deleteRun(runId);
      await eventually(() => events[a]!.whereType<RunRemoved>().isNotEmpty && a.runs.isEmpty);
    });

    test('recorder: 20 rolling points, the full track has them all, a restart continues it', () async {
      final o = await create();
      final a = await join(o, aliceId);
      a.pathMode = PathMode.always;
      await walk(a, [for (var i = 0; i < 25; i++) i * 10.0]);
      expect(await a.flushPath(), isTrue);
      await eventually(() => o.path(aliceId.id).length == 25);
      expect(o.channel.items(PepCollections.pathPoint), hasLength(PepCollections.rollingPoints));
      List<TimedPoint> full(ProjectSession s) =>
          RecordedPath.decode(s.channel.items(PepCollections.path).values.single.body).points;
      expect(full(o), hasLength(25));

      // The app restarts on the same device: same full track, next rolling item.
      sessions.remove(a);
      await a.close();
      final a2 = await join(o, aliceId);
      a2.pathMode = PathMode.always;
      await walk(a2, [250]);
      await a2.flushPath();
      await eventually(() => full(o).length == 26);
      expect(o.path(aliceId.id), hasLength(26));
      final rolling = o.channel.items(PepCollections.pathPoint).values.map((i) => Position.decode(i.body).time).toList()
        ..sort();
      expect(rolling, hasLength(20));
      expect(rolling.last, o.path(aliceId.id).last.time, reason: 'the oldest rolling point was replaced');
    });

    test('the full track is split into segments of 1000 points', () async {
      if (h.clock == null) return markTestSkipped('fast on the memory broker only');
      final o = await create();
      final a = await join(o, aliceId);
      a.pathMode = PathMode.always;
      final t0 = now();
      for (var i = 0; i < PepCollections.pathSegmentPoints + 5; i++) {
        await a.publishPosition(Position(lat: 45.2, lon: 5.3, time: t0.add(Duration(seconds: i)), accuracy: 5));
      }
      expect(await a.flushPath(), isTrue);
      await eventually(() => o.channel.items(PepCollections.path).length == 2);
      final sizes = [
        for (final i in o.channel.items(PepCollections.path).values) RecordedPath.decode(i.body).points.length,
      ]..sort();
      expect(sizes, [5, PepCollections.pathSegmentPoints]);
      expect(o.path(aliceId.id), hasLength(PepCollections.pathSegmentPoints + 5));
      // A restart continues the open segment.
      sessions.remove(a);
      await a.close();
      final a2 = await join(o, aliceId);
      a2.pathMode = PathMode.always;
      await a2.publishPosition(Position(lat: 45.2, lon: 5.3, time: now().add(const Duration(hours: 1)), accuracy: 5));
      await a2.flushPath();
      await eventually(() => o.path(aliceId.id).length == PepCollections.pathSegmentPoints + 6);
      expect(o.channel.items(PepCollections.path), hasLength(2));
    });

    test('close waits for a full-track publication already running', () async {
      final o = await create();
      final a = await join(o, aliceId);
      a.pathMode = PathMode.always;
      await walk(a, [0]); // first point: published at once
      await a.publishPosition(Position(lat: north(10).lat, lon: 5.3, time: now(), accuracy: 5));
      final running = a.flushPath();
      await a.publishPosition(
        Position(lat: north(20).lat, lon: 5.3, time: now().add(const Duration(seconds: 1)), accuracy: 5),
      );
      sessions.remove(a);
      await a.close();
      await running;
      await eventually(() => o.path(aliceId.id).length == 3);
      final full = o.channel.items(PepCollections.path).values.single;
      expect(RecordedPath.decode(full.body).points, hasLength(3));
    });

    test('recorded points with an impossible time are rejected, not fatal', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.channel.put(
        PepCollections.pathPoint,
        a.channel.selfItemId(device: 'r0'),
        utf8Bytes('{"v":1,"lat":45.2,"lon":5.3,"ts":99999999999999999}'),
      );
      await eventually(() => events[o]!.whereType<MessageRejected>().isNotEmpty);
      expect(o.path(aliceId.id), isEmpty);
    });

    test('overlapping positions while recording', () async {
      final o = await create();
      final a = await join(o, aliceId);
      a.pathMode = PathMode.always;
      final t0 = now();
      await Future.wait([
        for (var i = 0; i < 4; i++)
          a.publishPosition(
            Position(
              lat: north(i * 10).lat,
              lon: 5.3,
              time: t0.add(Duration(seconds: i)),
              accuracy: 5,
            ),
          ),
      ]);
      await a.flushPath();
      await eventually(() => o.path(aliceId.id).length == 4);
      expect(o.channel.items(PepCollections.pathPoint), hasLength(4));
    });

    test('two owner devices changing a run at once: everyone ends with the same run', () async {
      final o = await create();
      final o2 = await join(o, ownerId, deviceId: 'tablet');
      final a = await join(o, aliceId);
      final t = await o.publishTrack(gpx: lineGpx);
      final runId = await o.putRun(Run(track: t.id, dog: 'Rex'));
      await eventually(() => o2.runs.containsKey(runId) && a.runs.containsKey(runId));
      await Future.wait([o.setRunSource(runId, aliceId.id), o2.startRun(runId)]);
      String view(ProjectSession s) => jsonEncode(s.runs[runId]?.toJson());
      await eventually(() => view(o) == view(o2) && view(o) == view(a), reason: 'one version wins everywhere');
      final late = await join(o, bobId);
      expect(view(late), view(o));
    });

    test('path modes, offline queue', () async {
      final o = await create();
      final t = h.transport();
      final a = await join(o, aliceId, transport: t);
      await walk(a, [0]);
      expect(a.recordingPath, isFalse);
      a.pathMode = PathMode.always;
      expect(a.recordingPath, isTrue);
      await walk(a, [10]);
      await eventually(() => o.path(aliceId.id).length == 1);

      // No connection: positions fail, recorded points wait and keep their time.
      await t.disconnect();
      for (final m in [20.0, 30.0]) {
        await expectLater(
          a.publishPosition(Position(lat: north(m).lat, lon: north(m).lon, time: now(), accuracy: 5)),
          throwsA(isA<TransportException>()),
        );
        await tick();
      }
      expect(a.pathPending, isTrue);
      await t.connect();
      await walk(a, [40]);
      expect(await a.flushPath(), isTrue);
      expect(a.pathPending, isFalse);
      await eventually(() => o.path(aliceId.id).length == 4, reason: 'kept in the full track');
      final times = o.path(aliceId.id).map((p) => p.time).toList();
      expect(times, orderedEquals([...times]..sort()));

      await a.publishPosition(Position(lat: 45.3, lon: 5.3, time: now(), accuracy: 500)); // too inaccurate
      a.pathMode = PathMode.never;
      await walk(a, [50]);
      await settle();
      expect(o.path(aliceId.id), hasLength(4));
    });

    test('the owner adds collections missing from older projects', () async {
      final o = await create();
      final old = {...o.channel.acl.collections}
        ..remove(PepCollections.run)
        ..remove(PepCollections.path)
        ..remove(PepCollections.pathPoint);
      await o.channel.updateAcl(collections: old);
      final a = await join(o, aliceId);
      expect(a.channel.acl.collections.containsKey(PepCollections.run), isFalse);
      await expectLater(a.ensureCollections(), throwsA(isA<AuthorizationException>()));
      await join(o, ownerId, deviceId: 'laptop');
      await eventually(() => a.channel.acl.collections.containsKey(PepCollections.run));
      expect(a.channel.acl.collections[PepCollections.pathPoint]!.writers, Writers.self);
      expect(a.channel.acl.collections[PepCollections.path]!.writers, Writers.self);
    });

    test('bot members', () async {
      final o = await create();
      final bot = await join(o, bobId);
      await bot.setMemberName('Tractive', bot: true);
      await eventually(() => o.members[bobId.id]?.bot ?? false);
    });

    test('nothing readable on the broker', () async {
      final log = h.log;
      if (log == null) return markTestSkipped('broker log not observable');
      final o = await create();
      await o.publishTrack(gpx: named(gpxA, 'Trail name'));
      final a = await join(o, aliceId);
      await a.setMemberName('Alice Martin');
      await a.publishPosition(Position(lat: 45.123456, lon: 5.654321, time: now()));
      await settle();
      for (final (topic, payload) in log) {
        if (payload.isEmpty || !topic.contains(o.projectId)) continue;
        final text = latin1.decode(payload);
        for (final secret in ['Chambaran', 'Trail name', 'Secret forest', 'Alice', '45.12', 'samedi', 'cuir']) {
          expect(text.contains(secret), isFalse, reason: '"$secret" leaked on $topic');
        }
        expect(topic.contains(aliceId.id) || topic.contains(ownerId.id), isFalse, reason: 'member id in $topic');
      }
    });
  });
}
