import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

import 'crypto.dart';

/// Environment for session tests: transports on one broker, optional fake clock.
abstract class SessionHarness {
  Transport transport();

  /// Fake clock shared by sessions, or null when using real time.
  DateTime Function()? get clock;

  /// Advances the fake clock (only when [clock] != null).
  void advance(Duration d);

  /// Retained payloads on the broker, when observable (memory broker only).
  Map<String, Uint8List>? get retained;

  /// All payloads ever published, when observable (memory broker only).
  List<(String, Uint8List)>? get log;
}

/// Polls [cond] until true (works for in-memory and real brokers alike).
Future<void> eventually(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for ${reason ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Lets in-flight messages arrive (to assert that something did NOT happen).
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 300));

const gpxA = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="45.2001" lon="5.3002"><name>Objet 1</name><type>pep:object</type></wpt>
  <trk><name>Secret forest trail</name><trkseg>
    <trkpt lat="45.2000" lon="5.3000"/><trkpt lat="45.2005" lon="5.3005"/>
  </trkseg></trk>
</gpx>''';

final gpxB = gpxA.replaceAll('45.2005', '45.2105');

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
        // Leave nothing behind on real brokers.
        if (s.isOwner && !s.locked) {
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

    Future<ProjectSession> create({String password = 'pw-1', Duration? ttl}) async => track(await ProjectSession.create(
          crypto: c,
          transport: h.transport(),
          identity: ownerId,
          name: 'Forêt de Chambaran',
          description: 'Entraînement du samedi',
          discipline: Discipline.ru,
          password: password,
          settings: ProjectSettings(positionTtl: ttl ?? const Duration(minutes: 10)),
          kdf: fastKdf(c),
          clock: h.clock,
          pruneInterval: const Duration(hours: 1),
        ));

    Future<ProjectSession> join(ProjectSession owner, Identity who,
            {String password = 'pw-1', JoinLink? link, Duration timeout = const Duration(seconds: 5)}) async =>
        track(await ProjectSession.join(
          crypto: c,
          transport: h.transport(),
          identity: who,
          link: link ?? JoinLink.parse(owner.joinLink.toUri()),
          password: password,
          timeout: timeout,
          clock: h.clock,
          pruneInterval: const Duration(hours: 1),
        ));

    /// A password holder forging messages with arbitrary identities.
    Future<(Transport, Envelope, ProjectKey)> attacker(ProjectSession owner, String password) async {
      final t = h.transport();
      await t.connect();
      final got = Completer<Uint8List>();
      final sub = t.messages.listen((m) {
        if (m.topic == owner.topics.meta && !got.isCompleted) got.complete(m.payload);
      });
      await t.subscribe(owner.topics.meta);
      final meta = ProjectMeta.open(c,
          topic: owner.topics.meta, data: await got.future, ownerKey: publicKeyFromId(owner.ownerId));
      await sub.cancel();
      await t.unsubscribe(owner.topics.meta);
      return (t, Envelope(c), ProjectKey.derive(c, password, meta.kdf));
    }

    test('create: owner state and join link', () async {
      final o = await create();
      expect(o.isOwner, isTrue);
      expect(o.canEditTracks, isTrue);
      expect(o.project.name, 'Forêt de Chambaran');
      expect(o.project.discipline, Discipline.ru);
      expect(o.project.rev, 1);
      final link = JoinLink.parse(o.joinLink.toUri());
      expect(link.projectId, o.projectId);
      expect(link.ownerId, ownerId.id);
    });

    test('join sees project and tracks published before and after joining', () async {
      final o = await create();
      final t1 = await o.publishTrack(gpx: gpxA, name: 'Trail 1', notes: 'objets: 1');
      final a = await join(o, aliceId);
      expect(a.isOwner, isFalse);
      expect(a.canEditTracks, isFalse);
      expect(a.project.name, 'Forêt de Chambaran');
      expect(a.tracks.containsKey(t1.id), isTrue, reason: 'join returns with all retained tracks');
      expect(a.tracks[t1.id]!.gpx, gpxA);
      expect(a.tracks[t1.id]!.name, 'Trail 1');
      expect(a.trackSigner(t1.id), ownerId.id);
      expect(Gpx.parse(a.tracks[t1.id]!.gpx!).objects, hasLength(1));

      final t2 = await o.publishTrack(gpx: gpxB, name: 'Trail 2');
      await eventually(() => a.tracks.containsKey(t2.id), reason: 'track 2 at alice');
      expect(events[a]!.whereType<TrackUpdated>().map((e) => e.track.id), contains(t2.id));
    });

    test('track update and delete propagate; stale revisions are ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final t = await o.publishTrack(gpx: gpxA, name: 'v1');
      await eventually(() => a.tracks[t.id]?.name == 'v1');
      await o.publishTrack(id: t.id, gpx: gpxB, name: 'v2');
      await eventually(() => a.tracks[t.id]?.name == 'v2');
      expect(a.tracks[t.id]!.rev, 2);

      await o.deleteTrack(t.id);
      await eventually(() => !a.tracks.containsKey(t.id), reason: 'delete at alice');
      expect(o.tracks, isEmpty);
      expect(events[a]!.whereType<TrackRemoved>().single.trackId, t.id);

      final b = await join(o, bobId);
      await settle();
      expect(b.tracks, isEmpty, reason: 'tombstone hides the track from new joiners');
    });

    test('wrong password, unknown project, wrong owner in link', () async {
      final o = await create();
      await expectLater(join(o, aliceId, password: 'nope'), throwsA(isA<WrongPasswordException>()));
      final ghost = JoinLink(projectId: newUuid(c), ownerId: ownerId.id);
      await expectLater(join(o, aliceId, link: ghost, timeout: const Duration(milliseconds: 500)),
          throwsA(isA<ProjectNotFoundException>()));
      final fakeOwner = JoinLink(projectId: o.projectId, ownerId: bobId.id);
      await expectLater(join(o, aliceId, link: fakeOwner, timeout: const Duration(milliseconds: 500)),
          throwsA(isA<ProjectNotFoundException>()));
    });

    test('participants cannot edit tracks or the project', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await expectLater(a.publishTrack(gpx: gpxA), throwsA(isA<AuthorizationException>()));
      await expectLater(a.updateProject(name: 'x'), throwsA(isA<AuthorizationException>()));
      await expectLater(a.addEditor(aliceId.id), throwsA(isA<AuthorizationException>()));
      await expectLater(a.changePassword('x'), throwsA(isA<AuthorizationException>()));
      await expectLater(o.publishTrack(gpx: 'not gpx'), throwsA(isA<FormatPepException>()));
    });

    test('forged tracks and project docs from a password holder are rejected', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, env, key) = await attacker(o, 'pw-1');
      final forged = TrackDoc(id: 'evil', rev: 1, updated: DateTime.now().toUtc(), gpx: gpxA);
      await t.publish(o.topics.track('evil'),
          env.seal(key: key.dataKey, topic: o.topics.track('evil'), body: forged.encode(), signer: bobId),
          retain: true);
      final fakeDoc = o.project.next(editors: {bobId.id});
      await t.publish(o.topics.project,
          env.seal(key: key.dataKey, topic: o.topics.project, body: fakeDoc.encode(), signer: bobId),
          retain: true);
      await eventually(() => events[a]!.whereType<MessageRejected>().length >= 2, reason: 'rejections');
      expect(a.tracks, isEmpty);
      expect(o.tracks, isEmpty);
      expect(a.project.editors, isEmpty);
      expect(events[a]!.whereType<MessageRejected>().map((e) => e.error), everyElement(isA<AuthorizationException>()));
      await t.disconnect();
    });

    test('delegation: editors publish tracks until removed', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final b = await join(o, bobId);
      await o.addEditor(aliceId.id);
      await eventually(() => a.canEditTracks, reason: 'alice becomes editor');
      final t = await a.publishTrack(gpx: gpxA, name: 'by alice');
      await eventually(() => b.tracks.containsKey(t.id) && o.tracks.containsKey(t.id));
      expect(b.trackSigner(t.id), aliceId.id);

      await o.removeEditor(aliceId.id);
      await eventually(() => !a.canEditTracks, reason: 'alice loses editor rights');
      await expectLater(a.publishTrack(gpx: gpxB), throwsA(isA<AuthorizationException>()));
      expect(b.tracks.containsKey(t.id), isTrue, reason: 'earlier tracks stay');
    });

    test('track from a not-yet-editor is accepted once the owner adds them', () async {
      final o = await create();
      final b = await join(o, bobId);
      final (t, env, key) = await attacker(o, 'pw-1');
      final early = TrackDoc(id: 'early', rev: 1, updated: DateTime.now().toUtc(), gpx: gpxA);
      await t.publish(o.topics.track('early'),
          env.seal(key: key.dataKey, topic: o.topics.track('early'), body: early.encode(), signer: aliceId),
          retain: true);
      await eventually(() => events[b]!.whereType<MessageRejected>().isNotEmpty);
      expect(b.tracks, isEmpty);
      await o.addEditor(aliceId.id);
      await eventually(() => b.tracks.containsKey('early'), reason: 'pending track accepted');
      expect(b.trackSigner('early'), aliceId.id);
      await t.disconnect();
    });

    test('replayed old track revision is ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, _, _) = await attacker(o, 'pw-1');
      final captured = Completer<Uint8List>();
      final sub = t.messages.listen((m) {
        if (!captured.isCompleted && m.payload.isNotEmpty) captured.complete(m.payload);
      });
      final tr = await o.publishTrack(id: 'tr', gpx: gpxA, name: 'v1');
      await t.subscribe(o.topics.track(tr.id));
      final v1 = await captured.future;
      await sub.cancel();
      await o.publishTrack(id: tr.id, gpx: gpxB, name: 'v2');
      await eventually(() => a.tracks[tr.id]?.name == 'v2');
      await t.publish(o.topics.track(tr.id), v1, retain: true);
      await settle();
      expect(a.tracks[tr.id]!.name, 'v2');
      expect(o.tracks[tr.id]!.name, 'v2');
      await t.disconnect();
    });

    test('members and positions', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.setMemberName('Alice & Rex');
      await o.setMemberName('Owner');
      final now = (h.clock ?? DateTime.now)();
      await a.publishPosition(Position(lat: 45.2, lon: 5.3, time: now, accuracy: 5));
      await eventually(() => o.members[aliceId.id]?.name == 'Alice & Rex' && o.positions.containsKey(aliceId.id));
      await eventually(() => a.members[ownerId.id]?.name == 'Owner');
      expect(o.positions[aliceId.id]!.accuracy, 5);

      await a.publishPosition(Position(lat: 45.21, lon: 5.31, time: now.add(const Duration(seconds: 5))));
      await eventually(() => o.positions[aliceId.id]?.lat == 45.21);

      await a.clearPosition();
      await eventually(() => !o.positions.containsKey(aliceId.id), reason: 'cleared position');
      expect(events[o]!.whereType<PositionRemoved>(), isNotEmpty);
    });

    test('forged member profiles and positions are rejected', () async {
      final o = await create();
      final (t, env, key) = await attacker(o, 'pw-1');
      final topicA = o.topics.member(aliceId.id);
      await t.publish(topicA,
          env.seal(key: key.dataKey, topic: topicA, body: MemberDoc(name: 'fake', updated: DateTime.now()).encode(), signer: bobId),
          retain: true);
      final posA = o.topics.position(aliceId.id);
      await t.publish(posA,
          env.seal(key: key.dataKey, topic: posA, body: Position(lat: 1, lon: 1, time: (h.clock ?? DateTime.now)()).encode(), signer: bobId),
          retain: true);
      await eventually(() => events[o]!.whereType<MessageRejected>().length >= 2);
      expect(o.members, isEmpty);
      expect(o.positions, isEmpty);
      await t.disconnect();
    });

    test('project updates propagate; fake meta from others is ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await o.updateProject(name: 'Nouveau nom', settings: o.project.settings.copyWith(positionTtl: const Duration(minutes: 3)));
      await eventually(() => a.project.name == 'Nouveau nom');
      expect(a.project.settings.positionTtl, const Duration(minutes: 3));
      expect(a.project.rev, 2);

      final (t, _, _) = await attacker(o, 'pw-1');
      final kdf = fastKdf(c);
      final fake = ProjectMeta(kdf: kdf, keyCheck: ProjectKey.derive(c, 'hijack', kdf).check, rev: 99)
          .seal(topic: o.topics.meta, owner: bobId);
      await t.publish(o.topics.meta, fake, retain: true);
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(a.locked, isFalse);
      expect(events[a]!.whereType<PasswordChanged>(), isEmpty);
      await t.disconnect();
    });

    test('password change locks others until unlocked with the new password', () async {
      final o = await create();
      final t = await o.publishTrack(gpx: gpxA, name: 'keep me');
      final gone = await o.publishTrack(gpx: gpxB, name: 'deleted');
      await o.deleteTrack(gone.id);
      final a = await join(o, aliceId);
      expect(a.memberId, aliceId.id);
      await a.setMemberName('Alice');
      await o.setMemberName('Owner');
      await eventually(() => a.tracks.containsKey(t.id) && o.members.containsKey(aliceId.id));

      await o.changePassword('pw-2', kdf: fastKdf(c));
      await eventually(() => a.locked, reason: 'alice locked');
      expect(events[a]!.whereType<PasswordChanged>(), hasLength(1));
      expect(() => a.publishPosition(Position(lat: 1, lon: 1, time: DateTime.now())), throwsStateError);
      await expectLater(a.unlock('pw-1'), throwsA(isA<WrongPasswordException>()));
      await a.unlock('pw-2');
      expect(a.locked, isFalse);
      await eventually(() => a.tracks[t.id]?.rev == 2, reason: 're-sealed track');
      expect(a.tracks.containsKey(gone.id), isFalse);
      expect(a.project.rev, 2);
      await a.setMemberName('Alice');
      await eventually(() => o.members[aliceId.id]?.name == 'Alice');

      await expectLater(join(o, bobId, password: 'pw-1'), throwsA(isA<WrongPasswordException>()));
      final b = await join(o, bobId, password: 'pw-2');
      await eventually(() => b.tracks.containsKey(t.id));
      expect(b.tracks.containsKey(gone.id), isFalse);
      expect(b.members[ownerId.id]?.name, 'Owner', reason: "owner's profile re-sealed");
    });

    test('deleteProject clears the broker; participants are notified', () async {
      final o = await create();
      await o.publishTrack(gpx: gpxA);
      final a = await join(o, aliceId);
      await a.setMemberName('A');
      await eventually(() => o.members.isNotEmpty);
      sessions.remove(o);
      await o.deleteProject();
      await eventually(() => events[a]!.whereType<ProjectDeleted>().isNotEmpty);
      await expectLater(join(o, bobId, timeout: const Duration(milliseconds: 500)),
          throwsA(isA<ProjectNotFoundException>()));
      final r = h.retained;
      if (r != null) expect(r.keys.where((k) => k.contains(o.projectId)), isEmpty);
    });

    test('close clears own position', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.publishPosition(Position(lat: 1, lon: 2, time: (h.clock ?? DateTime.now)()));
      await eventually(() => o.positions.containsKey(aliceId.id));
      sessions.remove(a);
      await a.close();
      await eventually(() => !o.positions.containsKey(aliceId.id));
    });

    test('password change right after join re-seals every track (short-lived owner session)', () async {
      final o = await create();
      final ids = [for (var i = 0; i < 5; i++) (await o.publishTrack(gpx: gpxA, name: 't$i')).id];
      // A fresh owner session (e.g. CLI, second device) must see all tracks
      // before changing the password, or some would stay under the old key.
      final o2 = await join(o, ownerId);
      await o2.changePassword('pw-2', kdf: fastKdf(c));
      final b = await join(o, bobId, password: 'pw-2');
      expect(b.tracks.keys, unorderedEquals(ids));
      expect(events[b]!.whereType<MessageRejected>(), isEmpty);
    });

    test('sync() barrier completes', () async {
      final o = await create();
      await o.sync();
      final a = await join(o, aliceId);
      await a.sync();
    });

    test('close only clears a position shared by this session', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.publishPosition(Position(lat: 1, lon: 2, time: (h.clock ?? DateTime.now)()));
      // Second session of the same identity (e.g. app UI vs background service).
      final a2 = await join(o, aliceId);
      await eventually(() => a2.positions.containsKey(aliceId.id) && o.positions.containsKey(aliceId.id));
      sessions.remove(a2);
      await a2.close();
      await settle();
      expect(o.positions.containsKey(aliceId.id), isTrue);
    });

    test('nothing but meta is readable on the broker', () async {
      final log = h.log;
      if (log == null) return markTestSkipped('broker log not observable');
      final o = await create();
      await o.publishTrack(gpx: gpxA, name: 'Trail name');
      final a = await join(o, aliceId);
      await a.setMemberName('Alice Martin');
      await a.publishPosition(Position(lat: 45.123456, lon: 5.654321, time: (h.clock ?? DateTime.now)()));
      await settle();
      for (final (topic, payload) in log) {
        if (payload.isEmpty || !topic.contains(o.projectId)) continue;
        final text = latin1.decode(payload);
        for (final secret in ['Chambaran', 'Trail name', 'Secret forest', 'Alice', '45.12', 'samedi']) {
          expect(text.contains(secret), isFalse, reason: '"$secret" leaked on $topic');
        }
        if (!topic.endsWith('/meta')) expect(text.startsWith('PEP1'), isTrue, reason: topic);
      }
    });

    test('stale incoming positions are never shown', () async {
      if (h.clock == null) return markTestSkipped('needs a controllable clock');
      final o = await create(ttl: const Duration(minutes: 1));
      final a = await join(o, aliceId);
      final now = h.clock!();
      await a.publishPosition(Position(lat: 1, lon: 2, time: now));
      await eventually(() => o.positions.containsKey(aliceId.id));
      // Same timestamp arriving after the TTL (e.g. a cached fix republished late).
      h.advance(const Duration(minutes: 2));
      await a.publishPosition(Position(lat: 1, lon: 2.5, time: now));
      await eventually(() => events[o]!.whereType<PositionRemoved>().isNotEmpty);
      expect(o.positions, isEmpty);
    });

    test('positions expire after the project TTL', () async {
      if (h.clock == null) return markTestSkipped('needs a controllable clock');
      final o = await create(ttl: const Duration(minutes: 1));
      final a = await join(o, aliceId);
      await a.publishPosition(Position(lat: 1, lon: 2, time: h.clock!()));
      await eventually(() => o.positions.containsKey(aliceId.id));
      h.advance(const Duration(seconds: 61));
      expect(o.positions, isEmpty, reason: 'getter filters stale positions');
      o.prunePositions();
      await eventually(() => events[o]!.whereType<PositionRemoved>().isNotEmpty);
      final r = h.retained;
      if (r != null) expect(r.containsKey(o.topics.position(aliceId.id)), isFalse, reason: 'broker expiry');
      final b = await join(o, bobId);
      expect(b.positions, isEmpty);
    });
  });
}
