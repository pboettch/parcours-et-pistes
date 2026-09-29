import 'dart:convert';

import 'package:pep_content/pep_content.dart';
import 'package:test/test.dart';

T roundTrip<T>(T Function(Json) from, Json j) => from(jsonDecode(jsonEncode(j)) as Json);

void main() {
  group('ProjectInfo', () {
    final info = ProjectInfo(
        name: 'Piste de la forêt', description: 'Samedi', discipline: Discipline.ru, extra: {'future': 1});

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
    expect(() => roundTrip(MemberProfile.fromJson, {'v': 1}), throwsA(isA<ContentFormatException>()));
  });

  group('Position', () {
    test('round trip', () {
      final p = Position(
          lat: 45.18, lon: 5.72, time: DateTime.utc(2026, 9, 29), altitude: 212, accuracy: 4.5, heading: 90, speed: 1.2);
      expect(Position.decode(p.encode()).toJson(), p.toJson());
      expect(Position.decode(Position(lat: 0, lon: 0, time: DateTime.utc(2026)).encode()).accuracy, isNull);
    });

    test('rejects invalid coordinates', () {
      expect(() => Position(lat: 91, lon: 0, time: DateTime.now()), throwsA(isA<ContentFormatException>()));
      expect(() => Position(lat: double.nan, lon: 0, time: DateTime.now()), throwsA(isA<ContentFormatException>()));
      expect(() => roundTrip(Position.fromJson, {'v': 1, 'lat': 'x', 'lon': 0, 'ts': 0}),
          throwsA(isA<ContentFormatException>()));
    });
  });
}
