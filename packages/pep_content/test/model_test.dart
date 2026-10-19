import 'dart:convert';

import 'package:pep_content/pep_content.dart';
import 'package:test/test.dart';

T roundTrip<T>(T Function(Json) from, Json j) => from(jsonDecode(jsonEncode(j)) as Json);

void main() {
  group('ProjectInfo', () {
    final info = ProjectInfo(
      name: 'Piste de la forêt',
      description: 'Samedi',
      discipline: Discipline.ru,
      extra: {'future': 1},
    );

    test('round trip keeps unknown fields', () {
      final d = ProjectInfo.decode(info.encode());
      expect(d.toJson(), info.toJson());
      expect(d.extra, {'future': 1});
      expect(info.copyWith(name: 'x').name, 'x');
      expect(info.copyWith(name: 'x').discipline, Discipline.ru);
    });

    test('validation', () {
      Json j() => info.toJson();
      for (final bad in [j()..['v'] = 99, j()..['disc'] = 'agility', j()..remove('name'), j()..['name'] = 3]) {
        expect(() => roundTrip(ProjectInfo.fromJson, bad), throwsA(isA<ContentFormatException>()));
      }
      expect(() => ProjectInfo.decode(utf8Bytes('[1]')), throwsA(isA<ContentFormatException>()));
      expect(() => ProjectInfo.decode(utf8Bytes('{')), throwsA(isA<ContentFormatException>()));
    });
  });

  test('MemberProfile round trip', () {
    final m = MemberProfile(name: 'Ana & Rex');
    expect(MemberProfile.decode(m.encode()).name, 'Ana & Rex');
    expect(MemberProfile.decode(m.encode()).bot, isFalse);
    expect(m.toJson().containsKey('bot'), isFalse);
    final b = MemberProfile.decode(MemberProfile(name: 'Tractive', bot: true, extra: {'x': 1}).encode());
    expect(b.bot, isTrue);
    expect(b.extra, {'x': 1});
    expect(() => roundTrip(MemberProfile.fromJson, {'v': 1}), throwsA(isA<ContentFormatException>()));
    expect(
      () => roundTrip(MemberProfile.fromJson, {'v': 1, 'name': 'a', 'bot': 1}),
      throwsA(isA<ContentFormatException>()),
    );
  });

  group('Run', () {
    final t = DateTime.utc(2026, 10, 3, 9);
    final planned = Run(track: 'v1', dog: 'Rex', handler: 'Ana');

    test('lifecycle and source changes', () {
      expect(planned.status, RunStatus.planned);
      expect(planned.source, isNull);
      expect(planned.sourceAt(t), isNull);
      final r = planned
          .withSource('alice', t)
          .start(t.add(const Duration(minutes: 5)))
          .withSource('alice', t.add(const Duration(minutes: 6))) // unchanged
          .withSource('bob', t.add(const Duration(minutes: 30)));
      expect(r.status, RunStatus.running);
      expect(r.sources, hasLength(2));
      expect(r.source, 'bob');
      expect(r.sourceAt(t.subtract(const Duration(seconds: 1))), isNull);
      expect(r.sourceAt(t.add(const Duration(minutes: 29))), 'alice');
      expect(r.sourceAt(t.add(const Duration(minutes: 30))), 'bob');
      expect(r.sourceIntervals, [
        ('alice', t, t.add(const Duration(minutes: 30))),
        ('bob', t.add(const Duration(minutes: 30)), null),
      ]);
      final f = r.finish(t.add(const Duration(hours: 1)));
      expect(f.status, RunStatus.finished);
      expect(f.sourceIntervals.last.$3, t.add(const Duration(hours: 1)));
      expect(f.copyWith(dog: 'Max').dog, 'Max');
      expect(f.copyWith(dog: 'Max').sources, hasLength(2));
    });

    test('a source designated with an earlier time is kept in order', () {
      final r = planned.withSource('bob', t.add(const Duration(minutes: 30))).withSource('alice', t);
      expect(r.sources.map((s) => s.memberId), ['alice', 'bob']);
      expect(r.source, 'bob');
      expect(r.withSource('alice', t.add(const Duration(minutes: 10))).sources, hasLength(2), reason: 'unchanged');
    });

    test('round trip keeps unknown fields', () {
      final r = planned
          .withSource('alice', t)
          .start(t)
          .finish(t.add(const Duration(hours: 1)))
          .copyWith(extra: {'judge': 'x'});
      final d = Run.decode(r.encode());
      expect(d.toJson(), r.toJson());
      expect(d.started, t);
      expect(d.sources.single.since, t);
      expect(Run.decode(planned.encode()).toJson(), {'v': 1, 'track': 'v1', 'dog': 'Rex', 'handler': 'Ana'});
    });

    test('validation', () {
      Json j() => planned.withSource('alice', t).toJson();
      for (final bad in [
        j()..remove('dog'),
        j()..['src'] = [1],
        j()
          ..['src'] = [
            {'m': 'a'},
          ],
        j()..['start'] = 'x',
      ]) {
        expect(() => roundTrip(Run.fromJson, bad), throwsA(isA<ContentFormatException>()));
      }
    });
  });

  group('Position', () {
    test('round trip', () {
      final p = Position(
        lat: 45.18,
        lon: 5.72,
        time: DateTime.utc(2026, 9, 29),
        altitude: 212,
        accuracy: 4.5,
        heading: 90,
        speed: 1.2,
      );
      expect(Position.decode(p.encode()).toJson(), p.toJson());
      expect(Position.decode(Position(lat: 0, lon: 0, time: DateTime.utc(2026)).encode()).accuracy, isNull);
    });

    test('rejects invalid coordinates', () {
      expect(() => Position(lat: 91, lon: 0, time: DateTime.now()), throwsA(isA<ContentFormatException>()));
      expect(() => Position(lat: double.nan, lon: 0, time: DateTime.now()), throwsA(isA<ContentFormatException>()));
      expect(
        () => roundTrip(Position.fromJson, {'v': 1, 'lat': 'x', 'lon': 0, 'ts': 0}),
        throwsA(isA<ContentFormatException>()),
      );
    });
  });

  group('RecordedPath', () {
    final t0 = DateTime.utc(2026, 6, 13, 7, 30);
    TimedPoint p(int s, double lat, double lon) => TimedPoint(lat, lon, t0.add(Duration(seconds: s)));

    test('round trip: deltas, order, one point per millisecond, unknown fields', () {
      final path = RecordedPath([p(10, 45.300010, 5.200020), p(0, 45.3, 5.2), p(10, 45.300011, 5.200021)]);
      expect(path.points.map((x) => x.time), [t0, t0.add(const Duration(seconds: 10))]);
      final j = path.toJson();
      expect(j['p'], [t0.millisecondsSinceEpoch, 45300000, 5200000, 10000, 11, 21]);
      final d = roundTrip(RecordedPath.fromJson, {
        ...j,
        'extra': {'future': 1},
      });
      expect(d.points.last.lat, closeTo(45.300011, 1e-9));
      expect(d.points.last.lon, closeTo(5.200021, 1e-9));
      expect(d.extra, {'future': 1});
      expect(RecordedPath.decode(RecordedPath([]).encode()).points, isEmpty);
    });

    test('validation', () {
      for (final bad in <Json>[
        {'v': 2, 'p': []},
        {
          'v': 1,
          'p': [1, 2],
        },
        {
          'v': 1,
          'p': [1, 2.5, 3],
        },
        {
          'v': 1,
          'p': [0, 91000000, 0],
        },
        {
          'v': 1,
          'p': [9007199254740991, 0, 0],
        },
        {
          'v': 1,
          'p': [-9007199254740991, 0, 0],
        },
      ]) {
        expect(() => RecordedPath.fromJson(bad), throwsA(isA<ContentFormatException>()), reason: '$bad');
      }
    });
  });

  test('times out of range are invalid content', () {
    expect(
      () => Position.fromJson({'v': 1, 'lat': 1, 'lon': 2, 'ts': 9000000000000000}),
      throwsA(isA<ContentFormatException>()),
    );
  });
}
