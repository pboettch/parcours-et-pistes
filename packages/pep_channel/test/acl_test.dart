import 'dart:convert';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

void main() {
  late PepCrypto c;
  late String owner, writer, other;
  setUpAll(() async {
    c = await testCrypto();
    owner = Identity.generate(c).id;
    writer = Identity.generate(c).id;
    other = Identity.generate(c).id;
  });

  ChannelAcl acl() => ChannelAcl(
    ownerId: owner,
    collections: {
      'doc': const CollectionPolicy(Writers.owner),
      'note': const CollectionPolicy(Writers.assigned),
      'pos': const CollectionPolicy(Writers.self, ttl: Duration(minutes: 5)),
    },
  ).withAssignee('note', 'x', writer);

  test('round trip', () {
    final a = ChannelAcl.decode(acl().encode());
    expect(a.toJson(), acl().toJson());
    expect(a.collections['pos']!.ephemeral, isTrue);
    expect(a.collections['pos']!.ttl, const Duration(minutes: 5));
    expect(a.collections['doc']!.ephemeral, isFalse);
    expect(a.collections['pos']!.withTtl(null).ephemeral, isFalse);
    expect(a.assigneeOf('note', 'x'), writer);
    expect(a.withAssignee('note', 'x', null).assignees, isEmpty);
  });

  test('permission matrix', () {
    final a = acl();
    final cases = {
      ('doc', owner, 'x'): true,
      ('doc', writer, 'x'): false,
      ('doc', other, 'x'): false,
      ('note', owner, 'x'): true,
      ('note', writer, 'x'): true,
      ('note', writer, 'y'): false,
      ('note', owner, 'y'): true,
      ('note', other, 'x'): false,
      ('pos', other, other): true,
      ('pos', other, writer): false,
      ('pos', owner, other): false,
      ('undeclared', owner, 'x'): false,
    };
    cases.forEach((k, v) => expect(a.canWrite(k.$2, k.$1, k.$3, isSelfItem: (m, i) => m == i), v, reason: '$k'));
  });

  test('rejects invalid access lists', () {
    Map<String, dynamic> j() => jsonDecode(jsonEncode(acl().toJson())) as Map<String, dynamic>;
    final bad = <Map<String, dynamic>>[
      j()..['v'] = 2,
      j()..['owner'] = 'short',
      j()..['owner'] = 5,
      j()..remove('owner'),
      j()
        ..['assign'] = {
          'note': {'x': 'short'},
        },
      j()
        ..['assign'] = {
          'doc': {'x': owner},
        },
      j()
        ..['assign'] = {
          'note': {'bad/id': owner},
        },
      j()..['assign'] = {'note': 'x'},
      j()
        ..['collections'] = {
          'note': {'w': 'everyone'},
        },
      j()
        ..['collections'] = {
          'pos': {'w': 'self', 'ttl': 1},
        },
      j()
        ..['collections'] = {
          'pos': {'w': 'self', 'ttl': 30 * 24 * 3600},
        },
      j()
        ..['collections'] = {
          'meta': {'w': 'owner'},
        },
      j()
        ..['collections'] = {
          'Bad-Name': {'w': 'owner'},
        },
      j()
        ..['collections'] = {
          for (var i = 0; i < 65; i++) 'c$i': {'w': 'owner'},
        },
      j()..remove('collections'),
    ];
    for (final b in bad) {
      expect(() => ChannelAcl.fromJson(b), throwsA(isA<FormatPepException>()), reason: '$b');
    }
  });
}
