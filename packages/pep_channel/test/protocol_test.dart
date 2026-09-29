import 'package:pep_core/pep_core.dart';
import 'package:test/test.dart';

import 'support/crypto.dart';

void main() {
  late PepCrypto c;
  setUpAll(() async => c = await testCrypto());

  test('newUuid produces distinct valid v4 UUIDs', () {
    final ids = {for (var i = 0; i < 200; i++) newUuid(c)};
    expect(ids, hasLength(200));
    expect(ids.every(isProjectId), isTrue);
  });

  group('ProjectTopics', () {
    late String id;
    late ProjectTopics t;
    setUp(() {
      id = newUuid(c);
      t = ProjectTopics(id);
    });

    test('layout', () {
      expect(t.all, 'pep/v1/$id/#');
      expect(t.meta, 'pep/v1/$id/meta');
      expect(t.project, 'pep/v1/$id/project');
      expect(t.track('t1'), 'pep/v1/$id/track/t1');
      expect(t.member('m_1-x'), 'pep/v1/$id/member/m_1-x');
      expect(t.position('m1'), 'pep/v1/$id/pos/m1');
      expect(ProjectTopics(id, base: 'club/x').meta, 'club/x/$id/meta');
    });

    test('parse', () {
      expect(t.parse(t.meta), const TopicRef(TopicKind.meta));
      expect(t.parse(t.project), const TopicRef(TopicKind.project));
      expect(t.parse(t.track('a')), const TopicRef(TopicKind.track, 'a'));
      expect(t.parse(t.member('b')), const TopicRef(TopicKind.member, 'b'));
      expect(t.parse(t.position('c')), const TopicRef(TopicKind.position, 'c'));
      expect(t.parse('pep/v1/$id/track/a/b'), isNull);
      expect(t.parse('pep/v1/$id/unknown'), isNull);
      expect(t.parse('pep/v1/${newUuid(c)}/meta'), isNull);
    });

    test('rejects unsafe ids and bases', () {
      for (final bad in ['', 'a/b', '+', '#', 'a b', 'x' * 65]) {
        expect(() => t.track(bad), throwsA(isA<FormatPepException>()), reason: bad);
      }
      expect(() => ProjectTopics('not-a-uuid'), throwsA(isA<FormatPepException>()));
      expect(() => ProjectTopics(id, base: 'a/#'), throwsA(isA<FormatPepException>()));
      expect(() => ProjectTopics(id, base: '/a'), throwsA(isA<FormatPepException>()));
    });
  });

  group('JoinLink', () {
    test('round trip with defaults', () {
      final l = JoinLink(projectId: newUuid(c), ownerId: Identity.generate(c).id);
      final s = l.toUri();
      expect(s, startsWith('${JoinLink.defaultPrefix}#p='));
      final p = JoinLink.parse(s);
      expect(p.projectId, l.projectId);
      expect(p.ownerId, l.ownerId);
      expect(p.broker, isNull);
      expect(p.topicBase, ProjectTopics.defaultBase);
    });

    test('round trip with broker and base, custom web prefix', () {
      final l = JoinLink(
          projectId: newUuid(c),
          ownerId: Identity.generate(c).id,
          broker: 'wss://mqtt.example.org:8443/mqtt',
          topicBase: 'club/pep');
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
