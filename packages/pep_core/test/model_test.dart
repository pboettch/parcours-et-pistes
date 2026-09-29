import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_core/pep_core.dart';
import 'package:pep_core/src/model/json.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

T roundTrip<T>(T Function(Json) from, Json j) => from(jsonDecode(jsonEncode(j)) as Json);

void main() {
  late PepCrypto c;
  setUpAll(() async => c = await testCrypto());

  group('ProjectMeta', () {
    const topic = 'pep/v1/x/meta';
    late KdfParams k;
    late ProjectKey key;
    late Identity owner;
    setUp(() {
      k = fastKdf(c);
      key = ProjectKey.derive(c, 'pw', k);
      owner = Identity.generate(c);
    });

    test('signed round trip', () {
      final data = ProjectMeta(kdf: k, keyCheck: key.check, rev: 2).seal(topic: topic, owner: owner);
      final m = ProjectMeta.open(c, topic: topic, data: data, ownerKey: owner.publicKey);
      expect(m.keyCheck, key.check);
      expect(m.kdf.salt, k.salt);
      expect(m.rev, 2);
    });

    test('rejects other signer, other topic, tampering', () {
      final data = ProjectMeta(kdf: k, keyCheck: key.check, rev: 1).seal(topic: topic, owner: owner);
      expect(() => ProjectMeta.open(c, topic: topic, data: data, ownerKey: Identity.generate(c).publicKey),
          throwsA(isA<AuthorizationException>()));
      expect(() => ProjectMeta.open(c, topic: 'pep/v1/y/meta', data: data, ownerKey: owner.publicKey),
          throwsA(isA<AuthorizationException>()));
      final t = Uint8List.fromList(data)..[data.length - 3] ^= 1;
      expect(() => ProjectMeta.open(c, topic: topic, data: t, ownerKey: owner.publicKey),
          throwsA(isA<PepException>()));
      expect(() => ProjectMeta.open(c, topic: topic, data: Uint8List(10), ownerKey: owner.publicKey),
          throwsA(isA<FormatPepException>()));
    });
  });

  group('ProjectDoc', () {
    late String owner, editor;
    late ProjectDoc doc;
    setUp(() {
      owner = Identity.generate(c).id;
      editor = Identity.generate(c).id;
      doc = ProjectDoc(
        id: newUuid(c),
        name: 'Piste de la forêt',
        discipline: Discipline.ru,
        ownerId: owner,
        editors: {editor},
        settings: const ProjectSettings(positionTtl: Duration(minutes: 10), extra: {'future': 1}),
        rev: 1,
        updated: DateTime.utc(2026, 9, 29, 12),
      );
    });

    test('round trip keeps unknown settings', () {
      final d = ProjectDoc.decode(doc.encode());
      expect(d.toJson(), doc.toJson());
      expect(d.settings.positionTtl, const Duration(minutes: 10));
      expect(d.settings.extra, {'future': 1});
    });

    test('permissions and next()', () {
      expect(doc.canEditTracks(owner), isTrue);
      expect(doc.canEditTracks(editor), isTrue);
      expect(doc.canEditTracks(Identity.generate(c).id), isFalse);
      final n = doc.next(editors: {});
      expect(n.rev, 2);
      expect(n.canEditTracks(editor), isFalse);
      expect(n.name, doc.name);
    });

    test('validation', () {
      Json j() => doc.toJson();
      for (final bad in [
        j()..['v'] = 99,
        j()..['disc'] = 'agility',
        j()..['owner'] = 'x',
        j()..['editors'] = ['x'],
        j()..['rev'] = '1',
        j()..remove('name'),
        j()..['settings'] = {'posTtl': 1},
      ]) {
        expect(() => roundTrip(ProjectDoc.fromJson, bad), throwsA(isA<FormatPepException>()));
      }
    });
  });

  group('TrackDoc', () {
    test('round trip live and tombstone', () {
      final t = TrackDoc(
          id: 't1',
          rev: 3,
          updated: DateTime.utc(2026),
          name: 'Trail 1',
          discipline: Discipline.mt,
          gpx: '<gpx/>',
          notes: 'n',
          extra: {'k': 'v'});
      expect(TrackDoc.decode(t.encode()).toJson(), t.toJson());
      final d = TrackDoc.decode(TrackDoc.tombstone('t1', rev: 4).encode());
      expect(d.deleted, isTrue);
      expect(d.gpx, isNull);
      expect(d.rev, 4);
    });

    test('live track requires gpx', () {
      expect(() => roundTrip(TrackDoc.fromJson, {'v': 1, 'id': 't', 'rev': 1, 'upd': 0}),
          throwsA(isA<FormatPepException>()));
    });
  });

  test('MemberDoc round trip', () {
    final m = MemberDoc(name: 'Ana & Rex', updated: DateTime.utc(2026));
    expect(MemberDoc.decode(m.encode()).toJson(), m.toJson());
  });

  group('Position', () {
    test('round trip', () {
      final p = Position(
          lat: 45.18, lon: 5.72, time: DateTime.utc(2026, 9, 29), altitude: 212, accuracy: 4.5, heading: 90, speed: 1.2);
      expect(Position.decode(p.encode()).toJson(), p.toJson());
      expect(Position.decode(Position(lat: 0, lon: 0, time: DateTime.utc(2026)).encode()).accuracy, isNull);
    });

    test('rejects invalid coordinates', () {
      expect(() => Position(lat: 91, lon: 0, time: DateTime.now()), throwsA(isA<FormatPepException>()));
      expect(() => Position(lat: double.nan, lon: 0, time: DateTime.now()), throwsA(isA<FormatPepException>()));
      expect(() => roundTrip(Position.fromJson, {'v': 1, 'lat': 'x', 'lon': 0, 'ts': 0}),
          throwsA(isA<FormatPepException>()));
    });

    test('freshness', () {
      final now = DateTime.utc(2026, 9, 29, 12);
      const ttl = Duration(minutes: 10);
      Position at(DateTime t) => Position(lat: 1, lon: 1, time: t);
      expect(at(now.subtract(const Duration(minutes: 9))).isFresh(ttl, now: now), isTrue);
      expect(at(now.subtract(const Duration(minutes: 11))).isFresh(ttl, now: now), isFalse);
      expect(at(now.add(const Duration(minutes: 1))).isFresh(ttl, now: now), isTrue);
      expect(at(now.add(const Duration(hours: 1))).isFresh(ttl, now: now), isFalse);
    });
  });
}
