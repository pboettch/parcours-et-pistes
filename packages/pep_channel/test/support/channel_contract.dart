import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pep_channel/pep_channel.dart';
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
  'note': CollectionPolicy(Writers.editors),
  'profile': CollectionPolicy(Writers.self),
  'pos': CollectionPolicy(Writers.self, ttl: Duration(minutes: 1)),
};

Uint8List b(String s) => utf8Bytes(s);
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
        if (ch.isOwner && !ch.locked) {
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

    Future<SecureChannel> create({String password = 'pw-1'}) async => track(
      await SecureChannel.create(
        crypto: c,
        transport: h.transport(),
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
    }) async => track(
      await SecureChannel.join(
        crypto: c,
        transport: h.transport(),
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
    }) => t.publish(
      topic,
      env.seal(key: key.dataKey, topic: topic, body: body, signer: as, rev: rev, time: now()),
      retain: true,
    );

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
      await expectLater(a.updateAcl(editors: {aliceId.id}), throwsA(isA<AuthorizationException>()));
      await expectLater(a.changePassword('x'), throwsA(isA<AuthorizationException>()));
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
      await forge(t, env, key, o.topics.acl, o.acl.copyWith(editors: {bobId.id}).encode(), bobId, rev: 99);
      await eventually(() => events[a]!.whereType<MessageRejected>().length >= 5, reason: '5 rejections');
      expect(events[a]!.whereType<MessageRejected>().map((e) => e.error), everyElement(isA<AuthorizationException>()));
      expect(a.items('doc'), isEmpty);
      expect(a.items('note'), isEmpty);
      expect(a.items('profile'), isEmpty);
      expect(a.items('photo'), isEmpty);
      expect(a.acl.editors, isEmpty);
      await t.disconnect();
    });

    test('delegation: editors write until removed; earlier items stay', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final bob = await join(o, bobId);
      await o.addEditor(aliceId.id);
      await eventually(() => a.canWrite('note', 'x'), reason: 'alice becomes editor');
      await a.put('note', 'by-alice', b('A'));
      await eventually(() => bob.item('note', 'by-alice')?.signerId == aliceId.id);
      await o.removeEditor(aliceId.id);
      await eventually(() => !a.canWrite('note', 'x'));
      await expectLater(a.put('note', 'again', b('A2')), throwsA(isA<AuthorizationException>()));
      expect(bob.item('note', 'by-alice'), isNotNull);
    });

    test('item from a not-yet-editor is accepted once the owner adds them', () async {
      final o = await create();
      final bob = await join(o, bobId);
      final (t, env, key) = await attacker(o, 'pw-1');
      await forge(t, env, key, o.topics.item('note', 'early'), b('early'), aliceId);
      await eventually(() => events[bob]!.whereType<MessageRejected>().isNotEmpty);
      await o.addEditor(aliceId.id);
      await eventually(() => bob.item('note', 'early')?.signerId == aliceId.id);
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

      await o.updateAcl(collections: {...o.acl.collections, 'photo': const CollectionPolicy(Writers.editors)});
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
          rev: 99,
        ).seal(topic: o.topics.meta, owner: bobId),
        retain: true,
      );
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(a.locked, isFalse);
      await t.disconnect();
    });

    test('password change re-seals, clears what the owner cannot sign, locks others', () async {
      final o = await create();
      await o.addEditor(aliceId.id);
      final a = await join(o, aliceId);
      await o.put('doc', 'main', b('doc'));
      await a.put('note', 'by-alice', b('A'));
      await o.put('note', 'gone', b('x'));
      await o.delete('note', 'gone');
      await a.put('profile', a.selfItemIdOf(aliceId.id), b('Alice'));
      await o.put('profile', o.selfItemIdOf(ownerId.id), b('Owner'));
      await a.put('pos', a.selfItemIdOf(aliceId.id), b('p'));
      await eventually(() => o.item('note', 'by-alice') != null && o.item('pos', o.selfItemIdOf(aliceId.id)) != null);

      await o.changePassword('pw-2', kdf: fastKdf(c));
      await eventually(() => a.locked, reason: 'alice locked');
      expect(events[a]!.whereType<PasswordChanged>(), hasLength(1));
      expect(() => a.put('profile', a.selfItemIdOf(aliceId.id), b('x')), throwsStateError);
      await expectLater(a.unlock('pw-1'), throwsA(isA<WrongPasswordException>()));
      await a.unlock('pw-2');
      expect(a.item('profile', a.selfItemIdOf(aliceId.id)), isNull, reason: 'cleared while alice was locked');
      expect(a.items('pos'), isEmpty);
      await eventually(() => a.item('note', 'by-alice')?.signerId == ownerId.id);

      final bob = await join(o, bobId, password: 'pw-2');
      expect(events[bob]!.whereType<MessageRejected>(), isEmpty, reason: 'nothing left under the old key');
      expect(s(bob.item('doc', 'main')?.body), 'doc');
      expect(bob.item('note', 'by-alice')!.signerId, ownerId.id, reason: 're-signed by the owner');
      expect(bob.item('note', 'gone'), isNull, reason: 'tombstone kept');
      expect(s(bob.item('profile', bob.selfItemIdOf(ownerId.id))?.body), 'Owner');
      expect(bob.item('profile', bob.selfItemIdOf(aliceId.id)), isNull, reason: "alice's own item cleared");
      expect(bob.items('pos'), isEmpty);
      expect(bob.acl.editors, {aliceId.id});
      await expectLater(join(o, bobId, password: 'pw-1'), throwsA(isA<WrongPasswordException>()));
    });

    test('unlock after an interrupted password change shows nothing from the old key', () async {
      final o = await create();
      final a = await join(o, aliceId);
      await o.put('note', 'n', b('old'));
      await a.put('pos', a.selfItemId(), b('p'));
      await eventually(() => a.item('note', 'n') != null && a.items('pos').isNotEmpty);
      // The owner's app publishes the new metadata, then dies before re-sealing.
      final kdf = fastKdf(c);
      final newKey = ProjectKey.derive(c, 'pw-2', kdf);
      final t = h.transport();
      await t.connect();
      await t.publish(
        o.topics.meta,
        ChannelMeta(kdf: kdf, keyCheck: newKey.check, rev: 2).seal(topic: o.topics.meta, owner: ownerId),
        retain: true,
      );
      await eventually(() => a.locked);
      await a.unlock('pw-2');
      expect(a.items('note'), isEmpty);
      expect(a.items('pos'), isEmpty);
      await eventually(() => events[a]!.whereType<ItemRemoved>().length >= 2);
      await t.disconnect();
    });

    test('password change from a fresh owner session covers every item', () async {
      final o = await create();
      final ids = [for (var i = 0; i < 5; i++) 'n$i'];
      for (final id in ids) {
        await o.put('note', id, b(id));
      }
      final o2 = await join(o, ownerId);
      await o2.changePassword('pw-2', kdf: fastKdf(c));
      final bob = await join(o, bobId, password: 'pw-2');
      expect(bob.items('note').keys, unorderedEquals(ids));
      expect(events[bob]!.whereType<MessageRejected>(), isEmpty);
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
      await expectLater(
        phone.put('pos', '${phone.selfItemIdOf(bobId.id)}.phone', b('x')),
        throwsA(isA<AuthorizationException>()),
      );
    });

    // ------------------------------------------------ ownership transfer

    test('ownership transfer: offer, accept, former owner becomes editor', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final oldLink = o.joinLink;
      await o.put('doc', 'main', b('by owner'));
      await o.put('note', 'n', b('note by owner'));
      await expectLater(a.acceptOwnership(), throwsA(isA<AuthorizationException>()));

      await o.offerOwnership(aliceId.id);
      await eventually(() => a.ownershipOfferedToMe);
      await a.acceptOwnership();
      expect(a.isOwner, isTrue);
      await eventually(() => o.ownerId == aliceId.id);
      expect(o.isOwner, isFalse);
      expect(o.acl.editors, contains(ownerId.id));
      expect(o.acl.owners.map((l) => l.memberId), [ownerId.id, aliceId.id]);
      expect(a.item('doc', 'main')!.signerId, aliceId.id, reason: 'owner items re-signed');
      await eventually(() => o.item('doc', 'main')?.signerId == aliceId.id);

      // The new owner has the powers, the former one no longer.
      await a.put('doc', 'main', b('by new owner'));
      await a.addEditor(bobId.id);
      await expectLater(o.updateAcl(editors: {}), throwsA(isA<AuthorizationException>()));
      await expectLater(o.put('doc', 'main', b('x')), throwsA(isA<AuthorizationException>()));
      await o.put('note', 'n2', b('former owner is an editor'));

      // Old links (pinning the former owner) and new links both work.
      final viaOld = await join(o, bobId, link: JoinLink.parse(oldLink.toUri()));
      expect(viaOld.ownerId, aliceId.id);
      expect(s(viaOld.item('doc', 'main')?.body), 'by new owner');
      expect(viaOld.item('note', 'n')?.signerId, ownerId.id, reason: 'former owner stays a valid editor');
      expect(a.joinLink.ownerId, aliceId.id);
      final viaNew = await join(a, Identity.generate(c));
      expect(viaNew.acl.owners, hasLength(2));
      await eventually(() => a.item('note', 'n2') != null);
    });

    test('ownership offer: only the designated member, cancellable', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final bob = await join(o, bobId);
      await o.offerOwnership(bobId.id);
      await eventually(() => bob.ownershipOfferedToMe);
      expect(a.ownershipOfferedToMe, isFalse);
      await expectLater(a.acceptOwnership(), throwsA(isA<AuthorizationException>()));
      await o.cancelOwnershipOffer();
      await eventually(() => !bob.ownershipOfferedToMe);
      await expectLater(bob.acceptOwnership(), throwsA(isA<AuthorizationException>()));
      expect(o.isOwner, isTrue);
    });

    test('forged ownership chains and a former owner rolling back are rejected', () async {
      final o = await create();
      final a = await join(o, aliceId);
      final (t, env, key) = await attacker(o, 'pw-1');
      // Bob appends himself to the chain without the owner's signature.
      final fakeLink = OwnerLink(bobId.id, bobId.sign(OwnerLink.toSign(o.channelId, 1, bobId.id)));
      final forged = o.acl.copyWith(owners: [...o.acl.owners, fakeLink]);
      await forge(t, env, key, o.topics.acl, forged.encode(), bobId, rev: 50);
      await eventually(() => events[a]!.whereType<MessageRejected>().isNotEmpty);
      expect(a.ownerId, ownerId.id);

      // Legit transfer to alice, then the former owner tries to take it back.
      await o.offerOwnership(aliceId.id);
      await eventually(() => a.ownershipOfferedToMe);
      await a.acceptOwnership();
      await eventually(() => o.ownerId == aliceId.id);
      final before = events[a]!.whereType<MessageRejected>().length;
      final rollback = ChannelAcl.initial(ownerId: ownerId.id, collections: testCollections);
      await forge(t, env, key, o.topics.acl, rollback.encode(), ownerId, rev: 99);
      await t.publish(
        o.topics.meta,
        ChannelMeta(kdf: fastKdf(c), keyCheck: key.check, rev: 99).seal(topic: o.topics.meta, owner: ownerId),
        retain: true,
      );
      await eventually(() => events[a]!.whereType<MessageRejected>().length >= before + 2);
      expect(a.ownerId, aliceId.id);
      expect(a.locked, isFalse, reason: 'meta from the former owner does not count');
      await t.disconnect();
    });

    // ------------------------------------------------ restricted items

    test('restricted items are readable by their recipients only', () async {
      final o = await create();
      await o.addEditor(aliceId.id);
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

    test('restricted items survive password change and ownership transfer', () async {
      final o = await create();
      await o.addEditor(aliceId.id);
      final a = await join(o, aliceId);
      final bob = await join(o, bobId);
      await a.put('note', 'r', b('for alice and owner'), recipients: {});
      await o.put('doc', 'd', b('owner doc for alice'), recipients: {aliceId.id});
      await eventually(() => bob.items('note').isEmpty && a.item('doc', 'd') != null);

      await o.changePassword('pw-2', kdf: fastKdf(c));
      await eventually(() => a.locked);
      await a.unlock('pw-2');
      await eventually(() => a.item('note', 'r')?.rev == 2 && a.item('doc', 'd')?.rev == 2);
      expect(s(a.item('note', 'r')!.body), 'for alice and owner');

      // Bob becomes owner: he re-signs the owner doc without being able to read it.
      await bob.unlock('pw-2');
      await o.offerOwnership(bobId.id);
      await eventually(() => bob.ownershipOfferedToMe);
      await bob.acceptOwnership();
      expect(bob.item('doc', 'd'), isNull, reason: 'not a recipient');
      await eventually(() => a.item('doc', 'd')?.signerId == bobId.id);
      expect(s(a.item('doc', 'd')!.body), 'owner doc for alice');
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
        for (final secret in ['Secret forest', 'Alice', 'editors', 'note']) {
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
