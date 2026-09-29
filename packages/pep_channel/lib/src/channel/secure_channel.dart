import 'dart:async';
import 'dart:typed_data';

import '../codec/bytes.dart';
import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import '../crypto/kdf.dart';
import '../crypto/pep_crypto.dart';
import '../errors.dart';
import '../protocol/ids.dart';
import '../protocol/join_link.dart';
import '../protocol/topics.dart';
import '../transport/transport.dart';
import 'acl.dart';
import 'events.dart';
import 'item.dart';
import 'meta.dart';

/// Latest accepted revision of an item (live or tombstone).
class _Entry {
  _Entry(this.rev, this.time, this.item);

  final int rev;
  final DateTime time;

  /// Null for tombstones.
  final ChannelItem? item;

  bool newerThan(int r, DateTime t) => rev > r || (rev == r && time.isAfter(t));
}

/// An end-to-end encrypted, signed and access-controlled channel over a
/// [Transport]: collections of opaque items, kept in sync with the broker.
///
/// Every incoming message is decrypted, its signature verified and its signer
/// checked against the owner-signed [ChannelAcl]; anything else is dropped and
/// reported as [MessageRejected]. Items carry a revision and a publish time in
/// the signed envelope header: older revisions are ignored, deletions are
/// signed tombstones, and items of ephemeral collections expire after the
/// collection's TTL. The channel never interprets item bodies.
class SecureChannel {
  SecureChannel._({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required this.topics,
    required this.ownerId,
    required this.linkBroker,
    required DateTime Function()? clock,
    required Duration pruneInterval,
  }) : _c = crypto,
       _env = Envelope(crypto),
       _transport = transport,
       _me = identity,
       _ownerKey = publicKeyFromId(ownerId),
       _clock = clock ?? DateTime.now,
       _pruneInterval = pruneInterval;

  /// Creates a new channel owned by [identity] with the given [collections].
  static Future<SecureChannel> create({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required String password,
    required Map<String, CollectionPolicy> collections,
    Set<String> editors = const {},
    String topicBase = ChannelTopics.defaultBase,
    String? linkBroker,
    KdfParams? kdf,
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
  }) async {
    await _ensureConnected(transport);
    final s = SecureChannel._(
      crypto: crypto,
      transport: transport,
      identity: identity,
      topics: ChannelTopics(newUuid(crypto), base: topicBase),
      ownerId: identity.id,
      linkBroker: linkBroker,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    final params = kdf ?? KdfParams.generate(crypto);
    s._key = ProjectKey.derive(crypto, password, params);
    await s._publishMeta(ChannelMeta(kdf: params, keyCheck: s._key!.check, rev: 1));
    await s._publishAcl(ChannelAcl(ownerId: identity.id, editors: editors, collections: collections));
    await s._start();
    return s;
  }

  /// Joins an existing channel from its invitation [link] and [password].
  ///
  /// Returns once all retained items have been received (sync barrier).
  /// Throws [WrongPasswordException] for a wrong password and
  /// [ChannelNotFoundException] when no metadata/access list signed by the
  /// owner named in the link arrives within [timeout].
  static Future<SecureChannel> join({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required JoinLink link,
    required String password,
    Duration timeout = const Duration(seconds: 10),
    DateTime Function()? clock,
    Duration pruneInterval = const Duration(seconds: 15),
  }) async {
    await _ensureConnected(transport);
    final s = SecureChannel._(
      crypto: crypto,
      transport: transport,
      identity: identity,
      topics: ChannelTopics(link.channelId, base: link.topicBase),
      ownerId: link.ownerId,
      linkBroker: link.broker,
      clock: clock,
      pruneInterval: pruneInterval,
    );
    try {
      await s._start();
      await s.sync(timeout: timeout);
      await s._metaArrived.future.timeout(
        timeout,
        onTimeout: () => throw const ChannelNotFoundException('no channel metadata on the broker'),
      );
      await s.unlock(password);
      if (s._acl == null) {
        await s._aclArrived.future.timeout(
          timeout,
          onTimeout: () => throw const ChannelNotFoundException('no valid access list on the broker'),
        );
      }
      return s;
    } catch (_) {
      await s.close(clearEphemeral: false);
      rethrow;
    }
  }

  final PepCrypto _c;
  final Envelope _env;
  final Transport _transport;
  final Identity _me;
  final Uint8List _ownerKey;
  final DateTime Function() _clock;
  final Duration _pruneInterval;

  final ChannelTopics topics;

  /// Member id of the owner (trust anchor from the join link).
  final String ownerId;

  /// Broker URL embedded in generated join links (null = app default broker).
  final String? linkBroker;

  ProjectKey? _key;
  ChannelMeta? _meta;
  ChannelAcl? _acl;
  (int, DateTime)? _aclVersion;

  /// Accepted items and tombstones by topic.
  final _entries = <String, _Entry>{};

  /// Latest raw payload per topic (dedup, re-processing after unlock / ACL change).
  final _raw = <String, Uint8List>{};

  /// Item topics not accepted under the current ACL (unknown collection or
  /// unauthorized signer); re-evaluated whenever the ACL changes.
  final _pending = <String>{};

  /// Ephemeral items published by this session and not cleared yet.
  final _ownEphemeral = <String>{};

  final _syncWaiters = <String, Completer<void>>{};
  final _metaArrived = Completer<void>();
  final _aclArrived = Completer<void>();
  final _events = StreamController<ChannelEvent>.broadcast();
  StreamSubscription<TransportMessage>? _sub;
  Timer? _pruneTimer;
  var _closed = false;

  // ---------------------------------------------------------------- state

  String get channelId => topics.channelId;

  /// This device's member id.
  String get memberId => _me.id;

  bool get isOwner => _me.id == ownerId;

  /// True after the owner changed the password, until [unlock] succeeds.
  bool get locked => _key == null;

  Stream<ChannelEvent> get events => _events.stream;

  ChannelAcl get acl => _acl ?? (throw StateError('access list not loaded'));

  /// Revision of the current access list.
  int get aclRev => _aclVersion?.$1 ?? 0;

  JoinLink get joinLink => JoinLink(channelId: channelId, ownerId: ownerId, broker: linkBroker, topicBase: topics.base);

  /// A new random item id (16 chars, topic-safe).
  String generateItemId() => newItemId(_c);

  /// Whether this member may currently publish item [id] of [collection].
  bool canWrite(String collection, String id) => !locked && _acl != null && acl.canWrite(_me.id, collection, id);

  /// Live items of [collection] by id (expired ephemeral items filtered out).
  Map<String, ChannelItem> items(String collection) {
    final now = _now();
    return Map.unmodifiable({
      for (final e in _entries.values)
        if (e.item case final i? when i.collection == collection && _fresh(i, now)) i.id: i,
    });
  }

  ChannelItem? item(String collection, String id) {
    final i = _entries[topics.item(collection, id)]?.item;
    return i != null && _fresh(i, _now()) ? i : null;
  }

  // -------------------------------------------------------------- actions

  /// Publishes a new revision of item [id] in [collection]. Returns it.
  Future<ChannelItem> put(String collection, String id, Uint8List body) async {
    final policy = _requireWrite(collection, id);
    final topic = topics.item(collection, id);
    final data = _seal(topic, body, rev: _nextRev(topic));
    await _publish(topic, data, expiry: policy.ttl);
    if (policy.ephemeral) _ownEphemeral.add(topic);
    return _entries[topic]!.item!;
  }

  /// Deletes item [id]: a signed tombstone for persistent collections, a
  /// cleared retained message for ephemeral ones.
  Future<void> delete(String collection, String id) async {
    final policy = _requireWrite(collection, id);
    final topic = topics.item(collection, id);
    if (policy.ephemeral) {
      await _publish(topic, Uint8List(0));
      _ownEphemeral.remove(topic);
    } else {
      await _publish(topic, _seal(topic, Uint8List(0), rev: _nextRev(topic), deleted: true));
    }
  }

  /// Owner only: replaces editors and/or collections of the access list.
  Future<void> updateAcl({Set<String>? editors, Map<String, CollectionPolicy>? collections}) async {
    _requireOwner();
    await _publishAcl(acl.copyWith(editors: editors, collections: collections));
  }

  Future<void> addEditor(String memberId) {
    publicKeyFromId(memberId);
    return updateAcl(editors: {...acl.editors, memberId});
  }

  Future<void> removeEditor(String memberId) => updateAcl(editors: {...acl.editors}..remove(memberId));

  /// Owner only: changes the channel password.
  ///
  /// Publishes the new metadata first (other sessions lock until [unlock]),
  /// then re-encrypts under the new key the access list and every item and
  /// tombstone the owner may write (re-signed by the owner, revision + 1).
  /// Items the owner may not write (other members' `self` items), ephemeral
  /// items and rejected messages are cleared from the broker.
  Future<void> changePassword(String newPassword, {KdfParams? kdf}) async {
    _requireOwner();
    final params = kdf ?? KdfParams.generate(_c);
    final newKey = ProjectKey.derive(_c, newPassword, params);
    final meta = ChannelMeta(kdf: params, keyCheck: newKey.check, rev: _meta!.rev + 1);
    final entries = {..._entries};
    final pending = {..._pending};
    final currentAcl = acl;

    _key!.dispose();
    _key = newKey;
    await _publishMeta(meta);
    await _publishAcl(currentAcl);
    for (final MapEntry(key: topic, value: e) in entries.entries) {
      final ref = topics.parse(topic)!;
      final policy = currentAcl.collections[ref.collection];
      if (policy == null || policy.ephemeral || !currentAcl.canWrite(_me.id, ref.collection!, ref.id!)) {
        await _publish(topic, Uint8List(0));
      } else {
        final i = e.item;
        await _publish(topic, _seal(topic, i?.body ?? Uint8List(0), rev: e.rev + 1, deleted: i == null));
      }
    }
    _ownEphemeral.clear();
    for (final topic in pending) {
      await _publish(topic, Uint8List(0));
    }
  }

  /// Derives the key from [password] and (re)loads all content. Used after
  /// [PasswordChanged]; throws [WrongPasswordException].
  Future<void> unlock(String password) async {
    final meta = _meta ?? (throw StateError('channel metadata not received yet'));
    final key = ProjectKey.derive(_c, password, meta.kdf);
    if (!bytesEqual(key.check, meta.keyCheck)) {
      key.dispose();
      throw const WrongPasswordException();
    }
    _key?.dispose();
    _key = key;
    _reprocessAll();
  }

  /// Waits until every message the broker had queued for this session before
  /// the call has been received — in particular all retained messages after
  /// (re)subscribing.
  ///
  /// Implemented as a barrier: an empty, non-retained probe is published to a
  /// random `sync/<nonce>` topic; the broker delivers it behind the messages
  /// already queued for this subscription.
  Future<void> sync({Duration timeout = const Duration(seconds: 10)}) async {
    final topic = topics.sync(b64u(_c.randomBytes(9)));
    final done = _syncWaiters[topic] = Completer<void>();
    try {
      await _transport.publish(topic, Uint8List(0));
      await done.future.timeout(timeout, onTimeout: () => throw TransportException('sync timed out'));
    } finally {
      _syncWaiters.remove(topic);
    }
  }

  /// Owner only: removes every retained message of the channel from the
  /// broker (metadata last), then closes the session.
  Future<void> deleteChannel() async {
    _requireOwner();
    int order(String t) => switch (topics.parse(t)?.kind) {
      TopicKind.meta => 0,
      TopicKind.acl => 1,
      _ => 2,
    };
    final all = _raw.keys.toList()..sort((a, b) => order(b).compareTo(order(a)));
    for (final t in all) {
      await _transport.publish(t, Uint8List(0), retain: true);
    }
    await close(clearEphemeral: false);
  }

  /// Checks ephemeral items for expiry now (also done periodically).
  void prune() {
    if (_acl == null) return;
    final now = _now();
    final stale = [
      for (final MapEntry(key: t, value: e) in _entries.entries)
        if (e.item case final i? when !_fresh(i, now)) (t, i),
    ];
    for (final (t, i) in stale) {
      _entries[t] = _Entry(_entries[t]!.rev, _entries[t]!.time, null);
      _emit(ItemRemoved(i.collection, i.id, expired: true));
    }
  }

  /// Stops syncing. By default also clears the ephemeral items published by
  /// this session (e.g. its position); items published by other sessions of
  /// the same identity (e.g. a background service) are left alone.
  Future<void> close({bool clearEphemeral = true}) async {
    if (_closed) return;
    if (clearEphemeral && _transport.state == TransportState.connected) {
      for (final t in _ownEphemeral) {
        await _transport.publish(t, Uint8List(0), retain: true);
      }
    }
    _closed = true;
    _pruneTimer?.cancel();
    await _sub?.cancel();
    if (_transport.state == TransportState.connected) await _transport.unsubscribe(topics.all);
    _key?.dispose();
    _key = null;
    await _events.close();
  }

  // ------------------------------------------------------------ internals

  static Future<void> _ensureConnected(Transport t) async {
    if (t.state != TransportState.connected) await t.connect();
  }

  DateTime _now() => _clock().toUtc();

  /// Ephemeral items are fresh within the TTL after their publish time (and
  /// at most 5 minutes in the future, for clock skew).
  bool _fresh(ChannelItem i, DateTime now) {
    final ttl = _acl?.collections[i.collection]?.ttl;
    if (ttl == null) return true;
    return i.time.isAfter(now.subtract(ttl)) && i.time.isBefore(now.add(const Duration(minutes: 5)));
  }

  int _nextRev(String topic) => (_entries[topic]?.rev ?? 0) + 1;

  Future<void> _start() async {
    _sub = _transport.messages.listen((m) => _onMessage(m.topic, m.payload));
    await _transport.subscribe(topics.all);
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => prune());
  }

  void _emit(ChannelEvent e) {
    if (!_closed) _events.add(e);
  }

  void _requireUnlocked() {
    if (_closed) throw StateError('channel closed');
    if (locked) throw StateError('channel locked: the password changed');
  }

  void _requireOwner() {
    _requireUnlocked();
    if (!isOwner) throw const AuthorizationException('only the channel owner can do this');
  }

  CollectionPolicy _requireWrite(String collection, String id) {
    _requireUnlocked();
    final policy = acl.collections[checkCollection(collection)];
    if (policy == null) throw AuthorizationException('collection "$collection" is not declared in the access list');
    if (!acl.canWrite(_me.id, collection, id)) {
      throw AuthorizationException('not allowed to write $collection/$id');
    }
    return policy;
  }

  Uint8List _seal(String topic, Uint8List body, {required int rev, bool deleted = false}) =>
      _env.seal(key: _key!.dataKey, topic: topic, body: body, signer: _me, rev: rev, time: _now(), deleted: deleted);

  Future<void> _publishMeta(ChannelMeta meta) async {
    final data = meta.seal(topic: topics.meta, owner: _me);
    await _publish(topics.meta, data);
  }

  Future<void> _publishAcl(ChannelAcl acl) async {
    final data = _seal(topics.acl, acl.encode(), rev: aclRev + 1);
    await _publish(topics.acl, data);
  }

  /// Publishes retained and applies locally (the echo is deduplicated).
  Future<void> _publish(String topic, Uint8List data, {Duration? expiry}) async {
    await _transport.publish(topic, data, retain: true, expiry: expiry);
    _onMessage(topic, data);
  }

  void _onMessage(String topic, Uint8List payload) {
    if (_closed) return;
    final waiter = _syncWaiters[topic];
    if (waiter != null) return waiter.complete();
    final ref = topics.parse(topic);
    if (ref == null || ref.kind == TopicKind.sync) return;
    final prev = _raw[topic];
    if (payload.isEmpty ? prev == null : (prev != null && bytesEqual(prev, payload))) return;
    if (payload.isEmpty) {
      _raw.remove(topic);
    } else {
      _raw[topic] = payload;
    }
    _process(ref, topic, payload);
  }

  void _reprocessAll() {
    int order(TopicRef r) => switch (r.kind) {
      TopicKind.meta => 0,
      TopicKind.acl => 1,
      _ => 2,
    };
    final all = [for (final e in _raw.entries) (topics.parse(e.key)!, e.key, e.value)]
      ..sort((a, b) => order(a.$1).compareTo(order(b.$1)));
    for (final (ref, topic, payload) in all) {
      if (ref.kind != TopicKind.meta) _process(ref, topic, payload);
    }
  }

  void _process(TopicRef ref, String topic, Uint8List payload) {
    try {
      switch (ref.kind) {
        case TopicKind.meta:
          _onMeta(topic, payload);
        // Removals need no key: apply them even while locked, otherwise an
        // item cleared during a password change would survive the unlock.
        case TopicKind.acl:
          if (!locked || payload.isEmpty) _onAcl(topic, payload);
        case TopicKind.item:
          if (!locked || payload.isEmpty) _onItem(ref.collection!, ref.id!, topic, payload);
        case TopicKind.sync:
          break;
      }
    } on PepException catch (e) {
      _emit(MessageRejected(topic, e));
    }
  }

  void _onMeta(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_meta != null) _emit(const ChannelDeleted());
      return;
    }
    final meta = ChannelMeta.open(_c, topic: topic, data: payload, ownerKey: _ownerKey);
    final current = _meta;
    if (current != null && meta.rev <= current.rev) return;
    _meta = meta;
    if (!_metaArrived.isCompleted) _metaArrived.complete();
    if (current != null && _key != null && !bytesEqual(_key!.check, meta.keyCheck)) {
      _key!.dispose();
      _key = null;
      _emit(const PasswordChanged());
    }
  }

  void _onAcl(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_acl != null) _emit(const ChannelDeleted());
      return;
    }
    final o = _env.open(key: _key!.dataKey, topic: topic, data: payload);
    if (o.signerId != ownerId) throw const AuthorizationException('access list not signed by the owner');
    if (o.deleted) throw const FormatPepException('access list tombstone');
    final acl = ChannelAcl.decode(o.body);
    if (acl.ownerId != ownerId) throw const FormatPepException('access list owner mismatch');
    final v = _aclVersion;
    if (v != null && !(o.rev > v.$1 || (o.rev == v.$1 && o.time.isAfter(v.$2)))) return;
    _acl = acl;
    _aclVersion = (o.rev, o.time);
    if (!_aclArrived.isCompleted) _aclArrived.complete();
    _emit(AclUpdated(acl));
    for (final t in [..._pending]) {
      final raw = _raw[t];
      if (raw != null) _process(topics.parse(t)!, t, raw);
    }
  }

  void _onItem(String collection, String id, String topic, Uint8List payload) {
    if (payload.isEmpty) {
      _pending.remove(topic);
      final e = _entries[topic];
      if (e?.item != null) {
        _entries[topic] = _Entry(e!.rev, e.time, null);
        _emit(ItemRemoved(collection, id));
      }
      return;
    }
    final a = _acl;
    if (a == null || !a.collections.containsKey(collection)) {
      _pending.add(topic);
      if (a == null) return; // processed once the access list arrives
      throw AuthorizationException('collection "$collection" is not declared');
    }
    final o = _env.open(key: _key!.dataKey, topic: topic, data: payload);
    if (!a.canWrite(o.signerId, collection, id)) {
      _pending.add(topic);
      throw AuthorizationException('${o.signerId} may not write $collection/$id');
    }
    _pending.remove(topic);
    final known = _entries[topic];
    if (known != null && !(o.rev > known.rev || (o.rev == known.rev && o.time.isAfter(known.time)))) return;
    final hadItem = known?.item != null;
    if (o.deleted) {
      _entries[topic] = _Entry(o.rev, o.time, null);
      if (hadItem) _emit(ItemRemoved(collection, id));
      return;
    }
    final item = ChannelItem(
      collection: collection,
      id: id,
      rev: o.rev,
      time: o.time,
      signerId: o.signerId,
      body: o.body,
    );
    if (!_fresh(item, _now())) {
      _entries[topic] = _Entry(o.rev, o.time, null);
      if (hadItem) _emit(ItemRemoved(collection, id, expired: true));
      return;
    }
    _entries[topic] = _Entry(o.rev, o.time, item);
    _emit(ItemUpdated(item));
  }
}
