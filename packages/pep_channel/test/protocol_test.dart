import 'package:pep_channel/pep_channel.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

void main() {
  late PepCrypto c;
  setUpAll(() async => c = await testCrypto());

  test('newUuid produces distinct valid v4 UUIDs', () {
    final ids = {for (var i = 0; i < 200; i++) newUuid(c)};
    expect(ids, hasLength(200));
    expect(ids.every(isChannelId), isTrue);
  });

  group('ChannelTopics', () {
    late String id;
    late ChannelTopics t;
    setUp(() {
      id = newUuid(c);
      t = ChannelTopics(id);
    });

    test('layout', () {
      expect(t.all, 'pep/v1/$id/#');
      expect(t.meta, 'pep/v1/$id/meta');
      expect(t.acl, 'pep/v1/$id/acl');
      expect(t.item('track', 't1'), 'pep/v1/$id/track/t1');
      expect(t.item('pos', 'm_1-x'), 'pep/v1/$id/pos/m_1-x');
      expect(t.sync('n1'), 'pep/v1/$id/sync/n1');
      expect(ChannelTopics(id, base: 'club/x').meta, 'club/x/$id/meta');
    });

    test('parse', () {
      expect(t.parse(t.meta), const TopicRef(TopicKind.meta));
      expect(t.parse(t.acl), const TopicRef(TopicKind.acl));
      expect(t.parse(t.item('track', 'a')), const TopicRef(TopicKind.item, collection: 'track', id: 'a'));
      expect(t.parse(t.item('photo_2', 'b')), const TopicRef(TopicKind.item, collection: 'photo_2', id: 'b'));
      expect(t.parse(t.sync('n')), const TopicRef(TopicKind.sync, id: 'n'));
      expect(t.parse('pep/v1/$id/track/a/b'), isNull);
      expect(t.parse('pep/v1/$id/unknown'), isNull);
      expect(t.parse('pep/v1/$id/Track/a'), isNull);
      expect(t.parse('pep/v1/${newUuid(c)}/meta'), isNull);
    });

    test('rejects unsafe ids, collections and bases', () {
      for (final bad in ['', 'a/b', '+', '#', 'a b', 'x' * 65]) {
        expect(() => t.item('track', bad), throwsA(isA<FormatPepException>()), reason: bad);
      }
      for (final bad in ['meta', 'acl', 'sync', 'Track', '1x', 'a-b', 'x' * 33]) {
        expect(() => t.item(bad, 'a'), throwsA(isA<FormatPepException>()), reason: bad);
      }
      expect(() => ChannelTopics('not-a-uuid'), throwsA(isA<FormatPepException>()));
      expect(() => ChannelTopics(id, base: 'a/#'), throwsA(isA<FormatPepException>()));
      expect(() => ChannelTopics(id, base: '/a'), throwsA(isA<FormatPepException>()));
    });
  });

  group('JoinLink', () {
    test('round trip with defaults', () {
      final l = JoinLink(channelId: newUuid(c), ownerId: Identity.generate(c).id);
      final s = l.toUri();
      expect(s, startsWith('${JoinLink.defaultPrefix}#p='));
      final p = JoinLink.parse(s);
      expect(p.channelId, l.channelId);
      expect(p.ownerId, l.ownerId);
      expect(p.broker, isNull);
      expect(p.topicBase, ChannelTopics.defaultBase);
    });

    test('round trip with broker and base, custom web prefix', () {
      final l = JoinLink(
        channelId: newUuid(c),
        ownerId: Identity.generate(c).id,
        broker: 'wss://mqtt.example.org:8443/mqtt',
        topicBase: 'club/pep',
      );
      final s = l.toUri(prefix: 'https://example.org/join');
      expect(Uri.parse(s).query, isEmpty, reason: 'nothing outside the fragment');
      final p = JoinLink.parse(s);
      expect(p.broker, l.broker);
      expect(p.topicBase, 'club/pep');
    });

    test('rejects invalid links', () {
      final owner = Identity.generate(c).id;
      final pid = newUuid(c);
      for (final bad in [
        'parcoursetpistes://join',
        'parcoursetpistes://join#p=$pid',
        'parcoursetpistes://join#p=nope&o=$owner',
        'parcoursetpistes://join#p=$pid&o=short',
        'parcoursetpistes://join#p=$pid&o=$owner&b=http%3A%2F%2Fx',
      ]) {
        expect(() => JoinLink.parse(bad), throwsA(isA<FormatPepException>()), reason: bad);
      }
    });
  });
}
