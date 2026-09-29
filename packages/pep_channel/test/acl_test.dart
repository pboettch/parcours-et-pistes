import 'dart:convert';

import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

void main() {
  late PepCrypto c;
  late String owner, editor, other;
  setUpAll(() async {
    c = await testCrypto();
    owner = Identity.generate(c).id;
    editor = Identity.generate(c).id;
    other = Identity.generate(c).id;
  });

  ChannelAcl acl() => ChannelAcl(ownerId: owner, editors: {editor}, collections: {
        'doc': const CollectionPolicy(Writers.owner),
        'note': const CollectionPolicy(Writers.editors),
        'pos': const CollectionPolicy(Writers.self, ttl: Duration(minutes: 5)),
      });

  test('round trip', () {
    final a = ChannelAcl.decode(acl().encode());
    expect(a.toJson(), acl().toJson());
    expect(a.collections['pos']!.ephemeral, isTrue);
    expect(a.collections['pos']!.ttl, const Duration(minutes: 5));
    expect(a.collections['doc']!.ephemeral, isFalse);
    expect(a.collections['pos']!.withTtl(null).ephemeral, isFalse);
  });

  test('permission matrix', () {
    final a = acl();
    final cases = {
      ('doc', owner, 'x'): true, ('doc', editor, 'x'): false, ('doc', other, 'x'): false,
      ('note', owner, 'x'): true, ('note', editor, 'x'): true, ('note', other, 'x'): false,
      ('pos', other, other): true, ('pos', other, editor): false, ('pos', owner, other): false,
      ('undeclared', owner, 'x'): false,
    };
    cases.forEach((k, v) => expect(a.canWrite(k.$2, k.$1, k.$3), v, reason: '$k'));
  });

  test('rejects invalid access lists', () {
    Map<String, dynamic> j() => jsonDecode(jsonEncode(acl().toJson())) as Map<String, dynamic>;
    final bad = <Map<String, dynamic>>[
      j()..['v'] = 2,
      j()..['owner'] = 'short',
      j()..['editors'] = ['short'],
      j()..['collections'] = {'note': {'w': 'everyone'}},
      j()..['collections'] = {'pos': {'w': 'self', 'ttl': 1}},
      j()..['collections'] = {'pos': {'w': 'self', 'ttl': 30 * 24 * 3600}},
      j()..['collections'] = {'meta': {'w': 'owner'}},
      j()..['collections'] = {'Bad-Name': {'w': 'owner'}},
      j()..['collections'] = {for (var i = 0; i < 65; i++) 'c$i': {'w': 'owner'}},
      j()..remove('collections'),
    ];
    for (final b in bad) {
      expect(() => ChannelAcl.fromJson(b), throwsA(isA<FormatPepException>()), reason: '$b');
    }
  });
}
