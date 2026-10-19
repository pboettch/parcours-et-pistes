import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart';
import 'package:pep_channel/src/codec/bytes.dart' show ByteWriter;
import 'package:test/test.dart';

import 'crypto.dart';

/// Environment for channel tests: transports on one broker, optional fake clock.
abstract class ChannelHarness {
  Transport transport();

  /// Fake clock shared by channels (and broker), or null for real time.
  DateTime Function()? get clock;

  void advance(Duration d);

  /// Retained payloads (memory broker only).
  Map<String, Uint8List>? get retained;

  /// Every payload published (memory broker only).
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

/// Test collections: one per writer policy, plus an ephemeral one.
const testCollections = {
  'doc': CollectionPolicy(Writers.owner),
  'note': CollectionPolicy(Writers.assigned),
  'profile': CollectionPolicy(Writers.self),
  'pos': CollectionPolicy(Writers.self, ttl: Duration(minutes: 1)),
};

Uint8List b(String s) => utf8Bytes(s);

/// A transport that keeps saying "connected" while its publishes fail (e.g. a
/// broker refusing them, or a connection dying unnoticed).
class _FailingPublishes implements Transport {
  _FailingPublishes(this.inner);

  final Transport inner;
  var failing = false;

  @override
  TransportState get state => inner.state;
  @override
  Stream<TransportState> get states => inner.states;
  @override
  Stream<TransportMessage> get messages => inner.messages;
  @override
  Future<void> connect() => inner.connect();
  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<void> publish(String topic, Uint8List payload, {bool retain = false, Duration? expiry}) => failing
      ? Future.error(TransportException('refused'))
      : inner.publish(topic, payload, retain: retain, expiry: expiry);
  @override
  Future<void> subscribe(String filter) => inner.subscribe(filter);
  @override
  Future<void> unsubscribe(String filter) => inner.unsubscribe(filter);
}

String s(Uint8List? b) => b == null ? '<none>' : utf8.decode(b);

void channelContract(String name, ChannelHarness Function() harnessFactory) {
  group('SecureChannel ($name)', () {
    late PepCrypto c;
    late ChannelHarness h;
    late Identity ownerId, aliceId, bobId;
    final open = <SecureChannel>[];
    final events = <SecureChannel, List<ChannelEvent>>{};

    setUpAll(() async => c = await testCrypto());

    setUp(() {
      h = harnessFactory();
      ownerId = Identity.generate(c);
      aliceId = Identity.generate(c);
      bobId = Identity.generate(c);
    });

    tearDown(() async {
      for (final ch in open) {
        if (ch.isOwner) {
          try {
            await ch.deleteChannel();
          } on StateError {
            // already closed
          }
        }
        await ch.close();
      }
      open.clear();
      events.clear();
    });

    SecureChannel track(SecureChannel ch) {
      open.add(ch);
      final list = events[ch] = [];
      ch.events.listen(list.add);
      return ch;
    }

    Future<SecureChannel> create({String password = 'pw-1', Transport? transport}) async => track(
      await SecureChannel.create(
        crypto: c,
        transport: transport ?? h.transport(),
        identity: ownerId,
        password: password,
        collections: testCollections,
        kdf: fastKdf(c),
        clock: h.clock,
        pruneInterval: const Duration(hours: 1),
      ),
    );

    Future<SecureChannel> join(
      SecureChannel owner,
      Identity who, {
      String password = 'pw-1',
      JoinLink? link,
      Duration timeout = const Duration(seconds: 5),
      Transport? transport,
    }) async => track(
      await SecureChannel.join(
        crypto: c,
        transport: transport ?? h.transport(),
        identity: who,
        link: link ?? JoinLink.parse(owner.joinLink.toUri()),
        password: password,
        timeout: timeout,
        clock: h.clock,
        pruneInterval: const Duration(hours: 1),
      ),
    );

    DateTime now() => (h.clock ?? DateTime.now)().toUtc();

    /// A password holder forging messages with arbitrary identities.
    Future<(Transport, Envelope, ProjectKey)> attacker(SecureChannel owner, String password) async {
      final t = h.transport();
      await t.connect();
      final got = Completer<Uint8List>();
      final sub = t.messages.listen((m) {
        if (m.topic == owner.topics.meta && !got.isCompleted) got.complete(m.payload);
      });
      await t.subscribe(owner.topics.meta);
      final meta = ChannelMeta.open(
        c,
        topic: owner.topics.meta,
        data: await got.future,
        ownerKey: publicKeyFromId(owner.ownerId),
      );
      await sub.cancel();
      await t.unsubscribe(owner.topics.meta);
      return (t, Envelope(c), ProjectKey.derive(c, password, meta.kdf));
    }

    Future<void> forge(
      Transport t,
      Envelope env,
      ProjectKey key,
      String topic,
      Uint8List body,
      Identity as, {
      int rev = 1,
      DateTime? time,
    }) => t.publish(
      topic,
      env.seal(key: key.dataKey, topic: topic, body: body, signer: as, rev: rev, time: time ?? now()),
      retain: true,
    );

    /// A validly signed and encrypted envelope with a raw header time [ms]
    /// (beyond what DateTime can hold), or a hand-built [restricted] body.
    Uint8List rawEnvelope(
      ProjectKey key,
      String topic,
      Uint8List body,
      Identity as, {
      int rev = 1,
      int? ms,
      bool restricted = false,
    }) {
      final t = ms ?? now().millisecondsSinceEpoch;
      final header =
          (ByteWriter()
                ..u8(restricted ? 0x04 : 0)
                ..u32(rev)
                ..u32(t ~/ 0x100000000)
                ..u32(t % 0x100000000))
              .take();
      final toSign =
          (ByteWriter()
                ..bytes(utf8Bytes('pep-sig-v1'))
                ..lp16(utf8Bytes(topic))
                ..bytes(header)
                ..bytes(body))
              .take();
      final plain =
          (ByteWriter()
                ..bytes(header)
                ..bytes(as.publicKey)
                ..bytes(as.sign(toSign))
                ..bytes(body))
              .take();
      final nonce = c.randomBytes(24);
      final ct = c.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plain,
        nonce: nonce,
        key: key.dataKey,
        additionalData: utf8Bytes(topic),
      );
      return (ByteWriter()
            ..bytes(utf8Bytes('PEP1'))
            ..u8(1)
            ..bytes(nonce)
            ..bytes(ct))
          .take();
    }

    test('create: access list and join link', () async {
      final o = await create();
      expect(o.isOwner, isTrue);
      expect(o.acl.collections, testCollections);
      expect(o.aclRev, 1);
      expect(o.canWrite('doc', 'x'), isTrue);
      expect(o.canWrite('profile', o.selfItemIdOf(ownerId.id)), isTrue);
      expect(o.canWrite('profile', o.selfItemIdOf(aliceId.id)), isFalse);
      final link = JoinLink.parse(o.joinLink.toUri());
      expect(link.channelId, o.channelId);
      expect(link.ownerId, ownerId.id);
    });

    test('join returns with all items; later items arrive live', () async {
      final o = await create();
      await o.put('doc', 'main', b('hello'));
      await o.put('note', 'n1', b('note 1'));
      final a = await join(o, aliceId);
      expect(s(a.item('doc', 'main')?.body), 'hello');
      expect(a.items('note').keys, ['n1']);
      expect(a.item('note', 'n1')!.signerId, ownerId.id);
      expect(a.canWrite('doc', 'main'), isFalse);
      await o.put('note', 'n2', b('note 2'));
      await eventually(() => a.item('note', 'n2') != null);
      expect(events[a]!.whereType<ItemUpdated>().map((e) => e.item.id), contains('n2'));
    });

    test('updates increment revisions; tombstones hide deleted items', () async {
      final o = await create();
      final a = await join(o, aliceId);
      expect((await o.put('note', 'n', b('v1'))).rev, 1);
      expect((await o.put('note', 'n', b('v2'))).rev, 2);
      await eventually(() => s(a.item('note', 'n')?.body) == 'v2');
      await o.delete('note', 'n');
      await eventually(() => a.item('note', 'n') == null);
      expect(events[a]!.whereType<ItemRemoved>().single.expired, isFalse);
      final bob = await join(o, bobId);
      expect(bob.items('note'), isEmpty);
      expect((await o.put('note', 'n', b('v4'))).rev, 4, reason: 'revision continues after a tombstone');
    });

    test('wrong password, unknown channel, wrong owner in link', () async {
      final o = await create();
      await expectLater(join(o, aliceId, password: 'nope'), throwsA(isA<WrongPasswordException>()));
      await expectLater(
        join(
          o,
          aliceId,
          link: JoinLink(channelId: newUuid(c), ownerId: ownerId.id),
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<ChannelNotFoundException>()),
      );
      await expectLater(
        join(
          o,
          aliceId,
          link: JoinLink(channelId: o.channelId, ownerId: bobId.id),
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<ChannelNotFoundException>()),
      );
    });

    test('writer policies are enforced locally', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await expectLater(a.put('doc', 'main', b('x')), throwsA(isA<AuthorizationException>()));
      await expectLater(a.put('note', 'n', b('x')), throwsA(isA<AuthorizationException>()));
      await expectLater(a.put('profile', a.selfItemIdOf(bobId.id), b('x')), throwsA(isA<AuthorizationException>()));
      await expectLater(a.put('photo', 'p', b('x')), throwsA(isA<AuthorizationException>()));
      await expectLater(a.assign('note', 'n', aliceId.id), throwsA(isA<AuthorizationException>()));
      await expectLater(a.updateAcl(collections: {}), throwsA(isA<AuthorizationException>()));
      await a.put('profile', a.selfItemIdOf(aliceId.id), b('Alice'));
      await eventually(() => s(o.item('profile', o.selfItemIdOf(aliceId.id))?.body) == 'Alice');
    });

    test('forged items and access lists from a password holder are rejected', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('doc', 'main'), b('evil'), bobId);
      await forge(t, env, key, o.topics.item('note', 'evil'), b('evil'), bobId);
      await forge(t, env, key, o.topics.item('profile', o.selfItemIdOf(aliceId.id)), b('fake Alice'), bobId);
      await forge(t, env, key, o.topics.item('photo', 'p'), b('undeclared'), bobId);
      await forge(t, env, key, o.topics.acl, o.acl.withAssignee('note', 'evil', bobId.id).encode(), bobId, rev: 99);
      await eventually(() => events[a]!.whereType<MessageRejected>().length >= 5, reason: '5 rejections');
      expect(events[a]!.whereType<MessageRejected>().map((e) => e.error), everyElement(isA<AuthorizationException>()));
      expect(a.items('doc'), isEmpty);
      expect(a.items('note'), isEmpty);
      expect(a.items('profile'), isEmpty);
      expect(a.items('photo'), isEmpty);
      expect(a.acl.assignees, isEmpty);
      await t.disconnect();
    });

    test('assigned items: one writer each; reassignment re-signs the current version', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final bob = await join(o, bobId);
      await o.put('note', 'n', b('by owner'));
      await o.assign('note', 'n', aliceId.id);
      await eventually(() => a.canWrite('note', 'n'), reason: 'alice writes n');
      expect(a.canWrite('note', 'other'), isFalse);
      expect(bob.canWrite('note', 'n'), isFalse);
      await a.put('note', 'n', b('by alice'));
      await eventually(() => bob.item('note', 'n')?.signerId == aliceId.id);
      await expectLater(o.assign('doc', 'main', aliceId.id), throwsA(isA<AuthorizationException>()));

      await o.assign('note', 'n', bobId.id);
      await eventually(() => !a.canWrite('note', 'n') && bob.canWrite('note', 'n'));
      await expectLater(a.put('note', 'n', b('x')), throwsA(isA<AuthorizationException>()));
      await eventually(() => bob.item('note', 'n')?.signerId == ownerId.id, reason: 're-signed by the owner');
      expect(s(bob.item('note', 'n')!.body), 'by alice');
      final later = await join(o, Identity.generate(c));
      expect(s(later.item('note', 'n')?.body), 'by alice', reason: 'valid for sessions joining later');
      expect(events[later]!.whereType<MessageRejected>(), isEmpty);

      await bob.put('note', 'n', b('by bob'));
      await eventually(() => o.item('note', 'n')?.signerId == bobId.id);
      await o.assign('note', 'n', null); // back to the owner
      expect(o.acl.assignees, isEmpty);
      final later2 = await join(o, Identity.generate(c));
      expect(s(later2.item('note', 'n')?.body), 'by bob');
      expect(later2.item('note', 'n')!.signerId, ownerId.id);
    });

    test("a former assignee's late edit is rejected by everyone", () async {
      final o = await create();
      final bob = await join(o, bobId);
      await o.assign('note', 'n', aliceId.id);
      final a = await join(o, aliceId);
      await a.put('note', 'n', b('by alice'));
      await o.assign('note', 'n', bobId.id);
      await eventually(() => bob.canWrite('note', 'n'));
      // Alice's app, not yet aware of the change, publishes again.
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('note', 'n'), b('late alice'), aliceId, rev: 9);
      await eventually(() => events[bob]!.whereType<MessageRejected>().isNotEmpty);
      expect(s(bob.item('note', 'n')?.body), 'by alice');
      expect(s(o.item('note', 'n')?.body), 'by alice');
      await t.disconnect();
    });

    test('after a reconnect, publishing waits for the current state (e.g. a reassignment)', () async {
      final o = await create();
      final t = h.transport();
      await o.assign('note', 'n', aliceId.id);
      final a = await join(o, aliceId, transport: t);
      await t.disconnect();
      await o.assign('note', 'n', bobId.id);
      await t.connect();
      await expectLater(a.put('note', 'n', b('stale')), throwsA(isA<AuthorizationException>()));
      expect(a.acl.assigneeOf('note', 'n'), bobId.id);
    });

    test('the same signed version re-encrypted is not a new version', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, env, key) = await attacker(o, 'pw-1');
      final at = now();
      final topic = o.topics.item('doc', 'same');
      await forge(t, env, key, topic, b('content'), ownerId, rev: 2, time: at);
      await eventually(() => a.item('doc', 'same') != null);
      final before = events[a]!.whereType<ItemUpdated>().length;
      await forge(t, env, key, topic, b('content'), ownerId, rev: 2, time: at); // new nonce, same signature
      await settle();
      expect(events[a]!.whereType<ItemUpdated>().length, before);
      await t.disconnect();
    });

    test('changing the policy of an assigned collection drops its assignments', () async {
      final o = await create();
      await o.assign('note', 'n', aliceId.id);
      await o.updateAcl(collections: {...o.acl.collections, 'note': const CollectionPolicy(Writers.owner)});
      expect(o.acl.assignees, isEmpty);
    });

    test('item from a not-yet-assignee is accepted once the owner assigns it', () async {
      final o = await create();
      final bob = await join(o, bobId);
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('note', 'early'), b('early'), aliceId);
      await eventually(() => events[bob]!.whereType<MessageRejected>().isNotEmpty);
      await o.assign('note', 'early', aliceId.id);
      await eventually(() => bob.item('note', 'early')?.signerId == aliceId.id);
      await t.disconnect();
    });

    test('same revision at the same millisecond: everyone keeps the version the broker keeps', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, env, key) = await attacker(o, 'pw-1');
      final at = now();
      final topic = o.topics.item('doc', 'tie');
      await forge(t, env, key, topic, b('first'), ownerId, rev: 3, time: at);
      await eventually(() => s(a.item('doc', 'tie')?.body) == 'first');
      await forge(t, env, key, topic, b('second'), ownerId, rev: 3, time: at);
      await eventually(() => s(a.item('doc', 'tie')?.body) == 'second' && s(o.item('doc', 'tie')?.body) == 'second');
      final bob = await join(o, bobId);
      expect(s(bob.item('doc', 'tie')?.body), 'second');
      await t.disconnect();
    });

    test('new collections can be added to a live channel (content types added later)', () async {
      final o = await create();
      final a = await join(o, aliceId);
      // Published by a newer app version before the owner declares the collection.
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('photo', 'early'), b('jpeg…'), ownerId);
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(a.items('photo'), isEmpty);

      await o.updateAcl(collections: {...o.acl.collections, 'photo': const CollectionPolicy(Writers.assigned)});
      await eventually(() => a.items('photo').containsKey('early'), reason: 'pending item accepted');
      await o.put('photo', 'p2', b('png…'));
      await eventually(() => a.items('photo').length == 2);
      // A client that knows nothing about photos still enforces the policy.
      await forge(t, env, key, o.topics.item('photo', 'forged'), b('x'), bobId);
      await settle();
      expect(a.items('photo').containsKey('forged'), isFalse);
      await t.disconnect();
    });

    test('replayed old revision is ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, _, _) = await attacker(o, 'pw-1');
      final captured = Completer<Uint8List>();
      final sub = t.messages.listen((m) {
        if (!captured.isCompleted && m.payload.isNotEmpty) captured.complete(m.payload);
      });
      await o.put('note', 'n', b('v1'));
      await t.subscribe(o.topics.item('note', 'n'));
      final v1 = await captured.future;
      await sub.cancel();
      await o.put('note', 'n', b('v2'));
      await eventually(() => s(a.item('note', 'n')?.body) == 'v2');
      await t.publish(o.topics.item('note', 'n'), v1, retain: true);
      await settle();
      expect(s(a.item('note', 'n')?.body), 'v2');
      expect(s(o.item('note', 'n')?.body), 'v2');
      await t.disconnect();
    });

    test('ephemeral items: delete clears; close clears only own', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await a.put('pos', a.selfItemIdOf(aliceId.id), b('45.2,5.3'));
      await eventually(() => o.item('pos', o.selfItemIdOf(aliceId.id)) != null);
      await a.delete('pos', a.selfItemIdOf(aliceId.id));
      await eventually(() => o.item('pos', o.selfItemIdOf(aliceId.id)) == null);

      await a.put('pos', a.selfItemIdOf(aliceId.id), b('45.3,5.4'));
      final a2 = await join(o, aliceId); // same identity, e.g. background service
      await eventually(
        () => a2.item('pos', a2.selfItemIdOf(aliceId.id)) != null && o.item('pos', o.selfItemIdOf(aliceId.id)) != null,
      );
      open.remove(a2);
      await a2.close();
      await settle();
      expect(o.item('pos', o.selfItemIdOf(aliceId.id)), isNotNull, reason: 'a2 did not publish it');
      open.remove(a);
      await a.close();
      await eventually(() => o.item('pos', o.selfItemIdOf(aliceId.id)) == null, reason: 'a published it');
    });

    test('ephemeral items expire after the collection TTL', () async {
      if (h.clock == null) return markTestSkipped('needs a controllable clock');
      final o = await create();
      final a = await join(o, aliceId);
      await a.put('pos', a.selfItemIdOf(aliceId.id), b('p'));
      await eventually(() => o.item('pos', o.selfItemIdOf(aliceId.id)) != null);
      h.advance(const Duration(seconds: 61));
      expect(o.items('pos'), isEmpty, reason: 'getter filters expired items');
      o.prune();
      await eventually(() => events[o]!.whereType<ItemRemoved>().any((e) => e.expired));
      final r = h.retained;
      if (r != null) {
        expect(r.containsKey(o.topics.item('pos', o.selfItemIdOf(aliceId.id))), isFalse, reason: 'broker expiry');
      }
    });

    test('a message with an impossible publish time is rejected; the channel and joins go on', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, _, key) = await attacker(o, 'pw-1');
      final topic = o.topics.item('profile', o.selfItemIdOf(bobId.id));
      await t.publish(topic, rawEnvelope(key, topic, b('x'), bobId, ms: 4611686018427387904), retain: true);
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(events[a]!.whereType<MessageRejected>().last.error, isA<FormatPepException>());
      final bob = await join(o, bobId);
      expect(bob.item('profile', bob.selfItemId()), isNull);
      await o.put('doc', 'd', b('fine'));
      await eventually(() => s(a.item('doc', 'd')?.body) == 'fine');
      await t.disconnect();
    });

    test('a restricted item with an invalid recipient key is rejected; assign still works', () async {
      final o = await create();
      await o.assign('note', 'r', aliceId.id);
      final (t, _, key) = await attacker(o, 'pw-1');
      final topic = o.topics.item('note', 'r');
      // count 2: the owner (valid) and 32 zero bytes, then nonce and ciphertext.
      final contentKey = c.sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
      final nonce = c.randomBytes(24);
      final ct = c.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: Uint8List.fromList([0, ...utf8Bytes('hidden')]),
        nonce: nonce,
        key: contentKey,
        additionalData: utf8Bytes(topic),
      );
      final block =
          (ByteWriter()
                ..u8(2)
                ..bytes(Uint8List(32))
                ..bytes(Uint8List(80))
                ..bytes(publicKeyFromId(ownerId.id))
                ..bytes(Identity.sealFor(c, ownerId.id, contentKey.extractBytes()))
                ..bytes(nonce)
                ..bytes(ct))
              .take();
      contentKey.dispose();
      await t.publish(topic, rawEnvelope(key, topic, block, aliceId, restricted: true), retain: true);
      await eventually(() => events[o]!.whereType<MessageRejected>().isNotEmpty);
      expect(o.item('note', 'r'), isNull);
      await o.assign('note', 'r', bobId.id);
      await t.disconnect();
    });

    test('the owner can re-sign an item a member left at the highest revision', () async {
      final o = await create();
      await o.assign('note', 'n', aliceId.id);
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('note', 'n'), b('by alice'), aliceId, rev: maxItemRev);
      await eventually(() => o.item('note', 'n')?.rev == maxItemRev);
      await o.assign('note', 'n', bobId.id);
      expect(o.item('note', 'n')!.rev, maxItemRev + 1);
      final later = await join(o, Identity.generate(c));
      expect(s(later.item('note', 'n')?.body), 'by alice');
      expect(later.item('note', 'n')!.signerId, ownerId.id);
      // The new writer cannot go beyond the limit: refused before publishing.
      final bob = await join(o, bobId);
      await expectLater(bob.put('note', 'n', b('by bob')), throwsA(isA<FormatPepException>()));
      expect(s((await join(o, Identity.generate(c))).item('note', 'n')?.body), 'by alice');
      await o.delete('note', 'n');
      await t.disconnect();
    });

    test('a deleteChannel that fails (offline) leaves the session open: retry works', () async {
      final t = h.transport();
      final o = await create(transport: t);
      await o.put('doc', 'd', b('x'));
      await t.disconnect();
      await expectLater(o.deleteChannel(), throwsA(isA<TransportException>()));
      await t.connect();
      open.remove(o);
      await o.deleteChannel();
      await expectLater(
        join(o, bobId, timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ChannelNotFoundException>()),
      );
    });

    test('a deleteChannel refused because the reload after a reconnect failed can be retried', () async {
      final t = _FailingPublishes(h.transport());
      final o = await create(transport: t);
      await o.put('doc', 'd', b('x'));
      await t.disconnect();
      t.failing = true;
      await t.connect(); // the reload's sync probe fails
      await expectLater(o.deleteChannel(), throwsA(isA<TransportException>()));
      t.failing = false;
      await o.put('doc', 'd', b('still writable'));
      open.remove(o);
      await o.deleteChannel();
      await expectLater(
        join(o, bobId, timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ChannelNotFoundException>()),
      );
    });

    test('close completes even when clearing ephemeral items fails', () async {
      final o = await create();
      final t = _FailingPublishes(h.transport());
      final a = await join(o, aliceId, transport: t);
      await a.put('pos', a.selfItemId(), b('p'));
      t.failing = true;
      open.remove(a);
      await a.close();
      await expectLater(a.put('pos', a.selfItemId(), b('p2')), throwsStateError);
      await a.close(); // again: nothing to do
    });

    test('a wrong password, then the right one, on the same transport', () async {
      final o = await create();
      final t = h.transport();
      await expectLater(join(o, aliceId, password: 'nope', transport: t), throwsA(isA<WrongPasswordException>()));
      final a = await join(o, aliceId, transport: t);
      expect(a.acl.ownerId, ownerId.id);
    });

    test('close waits for writes in progress; later writes fail', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final write = a.put('profile', a.selfItemId(), b('Alice'));
      open.remove(a);
      final closing = a.close();
      expect((await write).rev, 1);
      await closing;
      await expectLater(a.put('profile', a.selfItemId(), b('again')), throwsStateError);
      await eventually(() => o.item('profile', o.selfItemIdOf(aliceId.id)) != null);
    });

    test('writes queued behind deleteChannel fail; nothing is left at the broker', () async {
      final o = await create();
      await o.put('doc', 'd', b('x'));
      open.remove(o);
      final deleting = o.deleteChannel();
      final late = expectLater(o.put('doc', 'late', b('y')), throwsStateError);
      await deleting;
      await late;
      final r = h.retained;
      if (r != null) expect(r.keys.where((k) => k.contains(o.channelId)), isEmpty);
    });

    test('writes run one at a time, in call order', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final writes = [for (var i = 1; i <= 5; i++) o.put('doc', 'd', b('v$i'))];
      final revs = [for (final w in writes) (await w).rev];
      expect(revs, [1, 2, 3, 4, 5]);
      await eventually(() => s(a.item('doc', 'd')?.body) == 'v5');
    });

    test('metadata with another key, even signed by the owner, is rejected', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, _, _) = await attacker(o, 'pw-1');
      final kdf = fastKdf(c);
      await t.publish(
        o.topics.meta,
        ChannelMeta(
          kdf: kdf,
          keyCheck: ProjectKey.derive(c, 'other', kdf).check,
        ).seal(topic: o.topics.meta, owner: ownerId),
        retain: true,
      );
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      await o.put('doc', 'd', b('still readable'));
      await eventually(() => s(a.item('doc', 'd')?.body) == 'still readable');
      await t.disconnect();
    });

    test('fake meta from a non-owner is ignored', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, _, _) = await attacker(o, 'pw-1');
      final kdf = fastKdf(c);
      await t.publish(
        o.topics.meta,
        ChannelMeta(
          kdf: kdf,
          keyCheck: ProjectKey.derive(c, 'hijack', kdf).check,
        ).seal(topic: o.topics.meta, owner: bobId),
        retain: true,
      );
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      await o.put('doc', 'd', b('still readable'));
      await eventually(() => s(a.item('doc', 'd')?.body) == 'still readable');
      await t.disconnect();
    });

    test('deleteChannel clears the broker', () async {
      final o = await create();
      await o.put('note', 'n', b('x'));
      final a = await join(o, aliceId);
      await a.put('profile', a.selfItemIdOf(aliceId.id), b('A'));
      await eventually(() => o.item('profile', o.selfItemIdOf(aliceId.id)) != null);
      open.remove(o);
      await o.deleteChannel();
      await eventually(() => events[a]!.whereType<ChannelDeleted>().isNotEmpty);
      await expectLater(
        join(o, bobId, timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ChannelNotFoundException>()),
      );
      final r = h.retained;
      if (r != null) expect(r.keys.where((k) => k.contains(o.channelId)), isEmpty);
    });

    test('sync() completes', () async {
      final o = await create();
      await o.sync();
      await (await join(o, aliceId)).sync();
    });

    // ------------------------------------------------ pseudonyms, devices

    test('self items use per-channel pseudonyms, never member ids', () async {
      final o = await create();
      final a = await join(o, aliceId);
      expect(a.selfItemId(), isNot(aliceId.id));
      expect(a.selfItemId(), o.selfItemIdOf(aliceId.id), reason: 'same pseudonym for every member');
      await expectLater(a.put('profile', aliceId.id, b('x')), throwsA(isA<AuthorizationException>()));
      final o2 = await create(); // another channel: another pseudonym
      expect(o2.selfItemIdOf(aliceId.id), isNot(o.selfItemIdOf(aliceId.id)));
    });

    test('several devices of one identity keep separate self items', () async {
      final o = await create();
      final phone = await join(o, aliceId);
      final tablet = await join(o, aliceId);
      await phone.put('pos', phone.selfItemId(device: 'phone'), b('p'));
      await tablet.put('pos', tablet.selfItemId(device: 'tablet'), b('t'));
      await eventually(() => o.items('pos').length == 2);
      expect(o.items('pos').values.map((i) => i.signerId), everyElement(aliceId.id));
      expect(() => phone.selfItemId(device: 'bad/device'), throwsA(isA<FormatPepException>()));
      expect(phone.selfItemId(device: 'phone'), isNot(contains('phone')), reason: 'device names are hashed');
      expect((await create()).selfItemIdOf(aliceId.id, device: 'phone'), isNot(phone.selfItemId(device: 'phone')));
      await expectLater(
        phone.put('pos', '${phone.selfItemIdOf(bobId.id)}.phone', b('x')),
        throwsA(isA<AuthorizationException>()),
      );
    });

    test('an access list or metadata signed by anyone but the owner is rejected', () async {
      final o = await create();
      final a = await join(o, aliceId);
      // A link naming someone else as owner does not open the channel.
      await expectLater(
        join(
          o,
          Identity.generate(c),
          link: JoinLink(channelId: o.channelId, ownerId: bobId.id),
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<ChannelNotFoundException>()),
      );
      final (t, env, key) = await attacker(o, 'pw-1');
      final hijack = ChannelAcl(ownerId: bobId.id, collections: testCollections);
      await forge(t, env, key, o.topics.acl, hijack.encode(), bobId, rev: 50);
      await t.publish(
        o.topics.meta,
        ChannelMeta(kdf: fastKdf(c), keyCheck: key.check).seal(topic: o.topics.meta, owner: bobId),
        retain: true,
      );
      await eventually(() => events[a]!.whereType<MessageRejected>().length >= 2);
      expect(a.ownerId, ownerId.id);
      expect(a.acl.ownerId, ownerId.id);
      await o.put('doc', 'd', b('still the owner'));
      await eventually(() => s(a.item('doc', 'd')?.body) == 'still the owner');
      await t.disconnect();
    });

    // ------------------------------------------------ restricted items

    test('restricted items are readable by their recipients only', () async {
      final o = await create();
      await o.assign('note', 'secret', aliceId.id);
      final a = await join(o, aliceId);
      final bob = await join(o, bobId);
      final carol = Identity.generate(c);
      final cc = await join(o, carol);

      final it = await a.put('note', 'secret', b('only for bob'), recipients: {bobId.id});
      expect(it.recipients, {bobId.id, ownerId.id, aliceId.id}, reason: 'owner and publisher added');
      await eventually(() => bob.item('note', 'secret') != null && o.item('note', 'secret') != null);
      expect(s(bob.item('note', 'secret')!.body), 'only for bob');
      await settle();
      expect(cc.item('note', 'secret'), isNull);
      expect(events[cc]!.whereType<MessageRejected>(), isEmpty, reason: 'hidden, not rejected');

      // Narrowing the recipients removes the item from bob's view.
      await a.put('note', 'secret', b('now only for carol'), recipients: {carol.id});
      await eventually(() => bob.item('note', 'secret') == null && cc.item('note', 'secret') != null);
      expect(events[bob]!.whereType<ItemRemoved>().map((e) => e.id), contains('secret'));
      // Opening it up again makes it public.
      await a.put('note', 'secret', b('public'));
      await eventually(() => bob.item('note', 'secret')?.recipients == null);
    });

    test('assigning a restricted item makes its new writer a recipient', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await o.put('note', 'r', b('for bob'), recipients: {bobId.id});
      await eventually(() => a.items('note').isEmpty && events[a]!.whereType<MessageRejected>().isEmpty);
      await o.assign('note', 'r', aliceId.id);
      await eventually(() => s(a.item('note', 'r')?.body) == 'for bob');
      expect(a.item('note', 'r')!.recipients, {bobId.id, ownerId.id, aliceId.id});
      await a.put('note', 'r', b('edited by alice'), recipients: {bobId.id});
    });

    test('items at an absurd revision are rejected; owner operations go on', () async {
      final o = await create();
      await o.assign('note', 'n', aliceId.id);
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('note', 'n'), b('max'), aliceId, rev: Envelope.maxRev);
      await eventually(() => events[o]!.whereType<MessageRejected>().isNotEmpty);
      expect(o.item('note', 'n'), isNull);
      await o.assign('note', 'n', bobId.id);
      await o.put('doc', 'd', b('still works'));
      await t.disconnect();
    });

    test('two reconnects in a row: the next write waits for the last reload and succeeds', () async {
      final o = await create();
      final t = h.transport();
      final a = await join(o, aliceId, transport: t);
      await t.disconnect();
      await t.connect();
      await t.disconnect();
      await o.put('doc', 'd', b('while away'));
      await t.connect();
      await a.put('profile', a.selfItemId(), b('Alice'));
      expect(s(a.item('doc', 'd')?.body), 'while away', reason: 'reloaded before writing');
      await eventually(() => o.item('profile', o.selfItemIdOf(aliceId.id)) != null);
    });

    test("after a reconnect, the owner's operations see the current access list", () async {
      final o = await create();
      final t = h.transport();
      final o2 = await join(o, ownerId, transport: t); // a second device of the owner
      await t.disconnect();
      await o.assign('note', 'a', aliceId.id);
      await t.connect();
      await o2.assign('note', 'b', bobId.id);
      await eventually(() => o.acl.assigneeOf('note', 'b') == bobId.id);
      expect(o.acl.assigneeOf('note', 'a'), aliceId.id, reason: 'not lost by a stale copy');
    });

    test('nothing but meta is readable on the broker', () async {
      final log = h.log;
      if (log == null) return markTestSkipped('broker log not observable');
      final o = await create();
      await o.put('note', 'n', b('Secret forest trail'));
      final a = await join(o, aliceId);
      await a.put('profile', a.selfItemIdOf(aliceId.id), b('Alice Martin'));
      await settle();
      for (final (topic, payload) in log) {
        if (payload.isEmpty || !topic.contains(o.channelId)) continue;
        final text = latin1.decode(payload);
        for (final secret in ['Secret forest', 'Alice', 'assign', 'note']) {
          expect(text.contains(secret), isFalse, reason: '"$secret" leaked on $topic');
        }
        if (!topic.endsWith('/meta')) expect(text.startsWith('PEP1'), isTrue, reason: topic);
        for (final id in [ownerId.id, aliceId.id]) {
          expect(topic.contains(id), isFalse, reason: 'member id in topic $topic');
        }
      }
    });
  });
}
