import 'dart:async';
import 'dart:typed_data';

import '../codec/bytes.dart';
import '../codec/compression.dart';
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

/// Latest accepted revision of an item topic.
class _Entry {
  _Entry(this.opened, this.item, [this.recipients]);

  /// The verified envelope content (raw body; restricted blocks still sealed).
  final Opened opened;

  /// The item as visible to this member; null for tombstones, expired items
  /// and restricted items this member may not read.
  final ChannelItem? item;

  /// Recipients of a restricted item (also when this member is not one).
  final Set<String>? recipients;

  int get rev => opened.rev;
  DateTime get time => opened.time;

  bool olderThan(Opened o) => _newer(o, opened);
}

/// Whether version [a] of an item replaces the known version [b]: a higher
/// revision, or the same one published later. Two writers publishing the same
/// revision at the same millisecond: the one received last wins, like the
/// retained message at the broker (which delivers a topic's messages in one
/// order to everyone), so that every client ends up with the broker's version.
/// The same signed content re-encrypted (new nonce) is the same version.
bool _newer(Opened a, Opened b) {
  if (a.rev != b.rev) return a.rev > b.rev;
  if (a.time != b.time) return a.time.isAfter(b.time);
  return !(a.signerId == b.signerId &&
      a.deleted == b.deleted &&
      a.restricted == b.restricted &&
      bytesEqual(a.body, b.body));
}

/// Highest revision accepted for items written by members (the owner may go
/// beyond, when re-signing).
const maxItemRev = Envelope.maxRev - 1048576;

/// Device names given by apps ([SecureChannel.selfItemId]).
final _deviceRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Device suffixes in self item ids (keyed hashes of device names).
final _suffixRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

/// An end-to-end encrypted, signed and access-controlled channel over a
/// [Transport]: collections of opaque items, kept in sync with the broker.
///
/// Every incoming message is decrypted, its signature verified and its signer
/// checked against the owner-signed [ChannelAcl]; anything else is dropped and
/// reported as [MessageRejected]. Items carry a revision and a publish time in
/// the signed envelope header: older revisions are ignored, deletions are
/// signed tombstones, and items of ephemeral collections expire after the
/// collection's TTL. Items can be restricted to a set of recipients (see
/// [put]). The channel never interprets item bodies.
///
/// Member ids never appear in topics: `self` items are stored under
/// per-channel pseudonyms ([selfItemId]) derived from the channel key.
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
       _clock = clock ?? DateTime.now,
       _pruneInterval = pruneInterval {
    publicKeyFromId(ownerId);
  }

  /// Creates a new channel owned by [identity] with the given [collections].
  static Future<SecureChannel> create({
    required PepCrypto crypto,
    required Transport transport,
    required Identity identity,
    required String password,
    required Map<String, CollectionPolicy> collections,
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
    try {
      await s._publishAcl(ChannelAcl(ownerId: identity.id, collections: collections));
      await s._publishMeta(ChannelMeta(kdf: params, keyCheck: s._key!.check));
      await s._start();
    } catch (_) {
      await s._shutdown(clearEphemeral: false);
      rethrow;
    }
    return s;
  }

  /// Joins an existing channel from its invitation [link] and [password].
  ///
  /// Returns once all retained items have been received (sync barrier).
  /// Throws [WrongPasswordException] for a wrong password and
  /// [ChannelNotFoundException] when no metadata and access list signed by
  /// the owner named in the link arrive within [timeout].
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
      s._deriveKey(password);
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
  final DateTime Function() _clock;
  final Duration _pruneInterval;

  final ChannelTopics topics;

  /// Broker URL embedded in generated join links (null = app default broker).
  final String? linkBroker;

  /// The channel's owner (its creator, named in the join link); never changes.
  final String ownerId;

  ProjectKey? _key;
  ChannelMeta? _meta;
  ChannelAcl? _acl;
  Opened? _aclVersion;

  /// Accepted items and tombstones by topic.
  final _entries = <String, _Entry>{};

  /// Latest raw payload per topic (dedup, processing once the key is derived,
  /// re-processing after an ACL change).
  final _raw = <String, Uint8List>{};

  /// Item topics not accepted under the current ACL (unknown collection or
  /// unauthorized signer); re-evaluated whenever the ACL changes.
  final _pending = <String>{};

  /// Ephemeral items published by this session and not cleared yet.
  final _ownEphemeral = <String>{};

  final _pseudonyms = <String, String>{};
  final _syncWaiters = <String, Completer<void>>{};
  final _metaArrived = Completer<void>();
  final _aclArrived = Completer<void>();
  final _events = StreamController<ChannelEvent>.broadcast();
  StreamSubscription<TransportMessage>? _sub;
  StreamSubscription<TransportState>? _stateSub;

  /// Last transport state seen (reconnects are noticed by events and before
  /// each write).
  var _connected = false;

  /// The retained state may be outdated (a reconnect, or a failed reload).
  var _stale = false;

  /// Reloads started (the latest one counts).
  var _reloads = 0;

  /// The new connection may have lost the subscription.
  var _subscribeAgain = false;

  /// The reload in progress: completes with the error, if any.
  Future<Object?>? _reload;

  /// The tail of this session's writes, which run one at a time, in call
  /// order.
  Future<void> _writes = Future.value();

  /// Queues [write]; refused once [close] or [deleteChannel] was called.
  Future<T> _serial<T>(Future<T> Function() write) {
    if (_closing || _closed) return Future.error(StateError('channel closed'));
    final result = _writes.then((_) async {
      await _ready();
      return write();
    });
    _writes = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Timer? _pruneTimer;
  var _closed = false;

  /// [close] or [deleteChannel] started: no new writes.
  var _closing = false;

  // ---------------------------------------------------------------- state

  String get channelId => topics.channelId;

  /// This device's member id.
  String get memberId => _me.id;

  bool get isOwner => _me.id == ownerId;

  Stream<ChannelEvent> get events => _events.stream;

  ChannelAcl get acl => _acl ?? (throw StateError('access list not loaded'));

  /// Revision of the current access list.
  int get aclRev => _aclVersion?.rev ?? 0;

  /// Join link for this channel, pinning its owner.
  JoinLink get joinLink => JoinLink(channelId: channelId, ownerId: ownerId, broker: linkBroker, topicBase: topics.base);

  /// A new random item id (16 chars, topic-safe).
  String generateItemId() => newItemId(_c);

  /// Topic id of this member's item in `self` collections, optionally per
  /// [device] (`[A-Za-z0-9_-]{1,64}`, e.g. positions of several devices of one
  /// user, or several items of one device).
  String selfItemId({String? device}) => selfItemIdOf(_me.id, device: device);

  /// Topic id of [memberId]'s item in `self` collections: a pseudonym derived
  /// from the channel key, plus for a [device] a keyed hash of its name —
  /// neither member ids nor device names appear in topics.
  String selfItemIdOf(String memberId, {String? device}) {
    final p = _pseudonym(memberId);
    if (device == null) return p;
    if (!_deviceRe.hasMatch(device)) throw FormatPepException('invalid device id "$device"');
    final tag = _c.sodium.crypto.genericHash(
      message: Uint8List.fromList([...utf8Bytes('pep-device-v1'), ...publicKeyFromId(memberId), ...utf8Bytes(device)]),
      key: _requireKey().pseudonymKey,
      outLen: 16,
    );
    return '$p.${b64u(tag.sublist(0, 9))}';
  }

  /// Whether this member may currently publish item [id] of [collection].
  bool canWrite(String collection, String id) => _key != null && _acl != null && _canWrite(_me.id, collection, id);

  /// Live items of [collection] readable by this member, by id (expired
  /// ephemeral items filtered out).
  Map<String, ChannelItem> items(String collection) {
    final now = _now();
    return Map.unmodifiable({
      for (final e in _entries.values)
        if (e.item case final i? when i.collection == collection && _fresh(i, now)) i.id: i,
    });
  }

  /// Recipients of item [id] if it is restricted, also when this member
  /// cannot read it; null for unrestricted or unknown items.
  Set<String>? recipientsOf(String collection, String id) => _entries[topics.item(collection, id)]?.recipients;

  ChannelItem? item(String collection, String id) {
    final i = _entries[topics.item(collection, id)]?.item;
    return i != null && _fresh(i, _now()) ? i : null;
  }

  // -------------------------------------------------------------- actions

  /// Publishes a new revision of item [id] in [collection]. Returns it.
  ///
  /// With [recipients], the body is encrypted with a fresh key that is sealed
  /// individually for each recipient (plus the owner and this member, always
  /// added): other members see that the item exists, but cannot read it.
  Future<ChannelItem> put(String collection, String id, Uint8List body, {Set<String>? recipients}) =>
      _serial(() => _put(collection, id, body, recipients: recipients));

  Future<ChannelItem> _put(String collection, String id, Uint8List body, {Set<String>? recipients}) async {
    final policy = _requireWrite(collection, id);
    final topic = topics.item(collection, id);
    for (final r in recipients ?? const <String>{}) {
      if (!Identity.isValidKey(_c, publicKeyFromId(r))) throw FormatPepException('invalid member id "$r"');
    }
    final rev = _checkRev(topic);
    final data = recipients == null
        ? _seal(topic, body, rev: rev)
        : _seal(topic, _restrict(topic, body, {...recipients, ownerId, _me.id}), rev: rev, restricted: true);
    await _publish(topic, data, expiry: policy.ttl);
    if (policy.ephemeral) _ownEphemeral.add(topic);
    if (_closed) throw StateError('channel closed');
    final e = _entries[topic];
    if (e?.item == null || e!.rev != rev || e.opened.signerId != _me.id) {
      throw StateError('$collection/$id: the published revision was not accepted');
    }
    return e.item!;
  }

  /// Deletes item [id]: a signed tombstone for persistent collections, a
  /// cleared retained message for ephemeral ones.
  Future<void> delete(String collection, String id) => _serial(() => _delete(collection, id));

  Future<void> _delete(String collection, String id) async {
    final policy = _requireWrite(collection, id);
    final topic = topics.item(collection, id);
    if (policy.ephemeral) {
      await _publish(topic, Uint8List(0));
      _ownEphemeral.remove(topic);
    } else {
      await _publish(topic, _seal(topic, Uint8List(0), rev: _checkRev(topic), deleted: true));
    }
  }

  /// Owner only: replaces the collections of the access list, then re-signs
  /// the items whose writer may no longer write them (see [assign]).
  Future<void> updateAcl({Map<String, CollectionPolicy>? collections}) =>
      _serial(() => _updateAcl(collections: collections));

  Future<void> _updateAcl({Map<String, CollectionPolicy>? collections}) async {
    _requireOwner();
    await _publishAcl(acl.copyWith(collections: collections));
    await _resealOrphans();
  }

  /// Owner only: makes [memberId] the writer of item [id] of an `assigned`
  /// collection (null: the owner again). The current revision is re-signed by
  /// the owner, so that it stays valid for everyone; a restricted item gets
  /// the new writer as a recipient.
  Future<void> assign(String collection, String id, String? memberId) =>
      _serial(() => _assign(collection, id, memberId));

  Future<void> _assign(String collection, String id, String? memberId) async {
    _requireOwner();
    if (acl.collections[collection]?.writers != Writers.assigned) {
      throw AuthorizationException('"$collection" is not an assigned collection');
    }
    checkTopicId(id);
    if (memberId != null) publicKeyFromId(memberId);
    if (acl.assigneeOf(collection, id) == memberId) return;
    // The current revision first, signed by the owner (valid under both access
    // lists): the new writer's first edit then follows it.
    final topic = topics.item(collection, id);
    final e = _entries[topic];
    if (e != null) {
      final r = e.item?.recipients;
      if (e.opened.restricted && memberId != null && (r == null || !r.contains(memberId))) {
        if (e.item == null) {
          throw AuthorizationException('$collection/$id is restricted and not readable by the owner: cannot share it');
        }
        await _put(collection, id, e.item!.body, recipients: {...r!, memberId});
      } else if (e.opened.signerId != _me.id) {
        await _publish(topic, _reseal(topic, e));
      }
    }
    await _publishAcl(acl.withAssignee(collection, id, memberId));
    await _resealOrphans();
  }

  /// Owner: re-signs every accepted item and tombstone (outside `self`
  /// collections) whose signer may no longer write it under the current access
  /// list (e.g. after a collection's policy changed), so that sessions joining
  /// later do not reject it.
  Future<void> _resealOrphans() async {
    for (final MapEntry(key: topic, value: e) in {..._entries}.entries) {
      final ref = topics.parse(topic)!;
      final policy = acl.collections[ref.collection];
      if (policy == null || policy.writers == Writers.self || policy.ephemeral) continue;
      if (!_canWrite(e.opened.signerId, ref.collection!, ref.id!) && _canWrite(_me.id, ref.collection!, ref.id!)) {
        await _publish(topic, _reseal(topic, e));
      }
    }
  }

  /// Derives the key from [password] and processes what arrived meanwhile.
  /// Throws [WrongPasswordException].
  void _deriveKey(String password) {
    final meta = _meta ?? (throw StateError('channel metadata not received yet'));
    final key = ProjectKey.derive(_c, password, meta.kdf);
    if (!bytesEqual(key.check, meta.keyCheck)) {
      key.dispose();
      throw const WrongPasswordException();
    }
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
      await Future.wait([
        _transport.publish(topic, Uint8List(0)),
        done.future,
      ], eagerError: true).timeout(timeout, onTimeout: () => throw TransportException('sync timed out'));
    } finally {
      _syncWaiters.remove(topic);
    }
  }

  /// Owner only: removes every retained message of the channel from the
  /// broker (metadata last), then closes the session. Writes called after it
  /// fail. If it fails (e.g. offline), the session stays open: retry, or
  /// [close].
  Future<void> deleteChannel() {
    if (!isOwner) return Future.error(const AuthorizationException('only the channel owner can do this'));
    final done = _serial(() async {
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
      await _shutdown(clearEphemeral: false);
    });
    final closingNow = !_closing;
    _closing = true; // writes called from now on are refused
    return done.catchError((Object e, StackTrace st) {
      // Not deleted (e.g. offline, or the reload failed): the session goes on.
      if (closingNow && !_closed && _closeDone == null) _closing = false;
      Error.throwWithStackTrace(e, st);
    });
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
      final e = _entries[t]!;
      _entries[t] = _Entry(e.opened, null, e.recipients);
      _emit(ItemRemoved(i.collection, i.id, expired: true));
    }
  }

  /// Stops syncing. By default also clears the ephemeral items published by
  /// this session (e.g. its position); items published by other sessions of
  /// the same identity (e.g. a background service) are left alone.
  ///
  /// Waits (a few seconds at most) for writes in progress; later ones fail.
  Future<void> close({bool clearEphemeral = true}) {
    if (_closed) return _closeDone ?? Future.value();
    return _closeDone ??= () async {
      _closing = true;
      await _writes.timeout(const Duration(seconds: 5), onTimeout: () {});
      await _shutdown(clearEphemeral: clearEphemeral);
    }();
  }

  Future<void>? _closeDone;

  /// Clearing ephemeral items and unsubscribing are best effort: the session
  /// is closed in any case.
  Future<void> _shutdown({required bool clearEphemeral}) async {
    if (_closed) return;
    _closed = true;
    _pruneTimer?.cancel();
    try {
      if (clearEphemeral && _transport.state == TransportState.connected) {
        for (final t in _ownEphemeral) {
          await _transport.publish(t, Uint8List(0), retain: true).timeout(const Duration(seconds: 5));
        }
      }
      if (_transport.state == TransportState.connected) await _transport.unsubscribe(topics.all);
    } catch (_) {
      // the transport is gone or refuses: nothing more to do
    } finally {
      await _sub?.cancel();
      await _stateSub?.cancel();
      _key?.dispose();
      _key = null;
      // Not awaited: a listener paused in `await for` would block it forever.
      unawaited(_events.close());
    }
  }

  // ------------------------------------------------------------ internals

  static Future<void> _ensureConnected(Transport t) async {
    if (t.state != TransportState.connected) await t.connect();
  }

  DateTime _now() => _clock().toUtc();

  String _pseudonym(String memberId) => _pseudonyms[memberId] ??= b64u(
    _c.sodium.crypto.genericHash(
      message: Uint8List.fromList([...utf8Bytes('pep-self-v1'), ...publicKeyFromId(memberId)]),
      key: _requireKey().pseudonymKey,
      outLen: 16,
    ),
  );

  ProjectKey _requireKey() => _key ?? (throw StateError('channel key not derived yet'));

  bool _isSelfItem(String memberId, String itemId) {
    final p = _pseudonym(memberId);
    return itemId == p || (itemId.startsWith('$p.') && _suffixRe.hasMatch(itemId.substring(p.length + 1)));
  }

  bool _canWrite(String memberId, String collection, String id) =>
      acl.canWrite(memberId, collection, id, isSelfItem: _isSelfItem);

  /// Ephemeral items are fresh within the TTL after their publish time (and
  /// at most 5 minutes in the future, for clock skew).
  bool _fresh(ChannelItem i, DateTime now) {
    final ttl = _acl?.collections[i.collection]?.ttl;
    if (ttl == null) return true;
    return i.time.isAfter(now.subtract(ttl)) && i.time.isBefore(now.add(const Duration(minutes: 5)));
  }

  int _nextRev(String topic) => (_entries[topic]?.rev ?? 0) + 1;

  /// The next revision of [topic], refused beyond [maxItemRev] for members
  /// (clients would reject it).
  int _checkRev(String topic) {
    final rev = _nextRev(topic);
    if (rev > maxItemRev && !isOwner) throw FormatPepException('revision $rev too high');
    return rev;
  }

  Future<void> _start() async {
    _sub = _transport.messages.listen((m) => _onMessage(m.topic, m.payload));
    _connected = _transport.state == TransportState.connected;
    _stateSub = _transport.states.listen((_) => _checkReconnect());
    await _transport.subscribe(topics.all);
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => prune());
  }

  /// After a reconnect, the retained state may be outdated: reload it (see
  /// [_ready]). A reconnect replaces a reload still running.
  void _checkReconnect() {
    final now = _transport.state == TransportState.connected;
    final reconnected = now && !_connected;
    _connected = now;
    if (reconnected) {
      _stale = true;
      _subscribeAgain = true;
    }
    if (!now || _closed || _closeDone != null) return;
    if (reconnected || (_stale && _reload == null)) _startReload();
  }

  /// Subscribes again if needed, then waits for the retained state (sync
  /// barrier).
  void _startReload() {
    final seq = ++_reloads;
    late final Future<Object?> reload;
    Future<Object?> run() async {
      Object? error;
      try {
        if (_subscribeAgain) {
          await _transport.subscribe(topics.all);
          if (seq == _reloads) _subscribeAgain = false;
        }
        await sync();
      } catch (e) {
        error = e;
      }
      if (identical(_reload, reload)) {
        _reload = null;
        if (error == null) _stale = false;
      }
      return error;
    }

    reload = run();
    _reload = reload;
  }

  /// Waits before writing, after a reconnect, until the retained state (e.g.
  /// a new access list) has arrived again. Throws [TransportException] if the
  /// latest reload failed (the next write tries again).
  Future<void> _ready() async {
    while (true) {
      _checkReconnect();
      final r = _reload;
      if (r == null) return;
      final seq = _reloads;
      final error = await r;
      if (error != null && seq == _reloads) {
        throw TransportException('could not reload the channel after reconnecting: $error');
      }
    }
  }

  void _emit(ChannelEvent e) {
    if (!_closed) _events.add(e);
  }

  void _requireOpen() {
    if (_closed) throw StateError('channel closed');
    _requireKey();
  }

  void _requireOwner() {
    _requireOpen();
    if (!isOwner) throw const AuthorizationException('only the channel owner can do this');
  }

  CollectionPolicy _requireWrite(String collection, String id) {
    _requireOpen();
    final policy = acl.collections[checkCollection(collection)];
    if (policy == null) throw AuthorizationException('collection "$collection" is not declared in the access list');
    if (!_canWrite(_me.id, collection, id)) throw AuthorizationException('not allowed to write $collection/$id');
    return policy;
  }

  Uint8List _seal(String topic, Uint8List body, {required int rev, bool deleted = false, bool restricted = false}) =>
      _env.seal(
        key: _key!.dataKey,
        topic: topic,
        body: body,
        signer: _me,
        rev: rev,
        time: _now(),
        deleted: deleted,
        restricted: restricted,
      );

  /// Re-signs an accepted entry under the current key (revision + 1), keeping
  /// restricted blocks sealed as they are.
  Uint8List _reseal(String topic, _Entry e) =>
      _seal(topic, e.opened.body, rev: e.rev + 1, deleted: e.opened.deleted, restricted: e.opened.restricted);

  // Restricted block:
  //   u8 count | count × (recipient public key[32] | sealed content key[80])
  //   | nonce[24] | XChaCha20-Poly1305(content key, ad = topic, flags u8 | payload)
  // flags bit0: payload deflated.
  static const _sealedKeyBytes = 32 + 48;

  Uint8List _restrict(String topic, Uint8List body, Set<String> recipients) {
    if (recipients.length > 255) throw ArgumentError('at most 255 recipients');
    final key = _c.sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
    try {
      final contentKey = key.extractBytes();
      var flags = 0;
      var payload = body;
      if (body.length > 64) {
        final z = deflate(body);
        if (z.length < body.length) {
          payload = z;
          flags = 1;
        }
      }
      final nonce = _c.randomBytes(24);
      final ct = _c.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message:
            (ByteWriter()
                  ..u8(flags)
                  ..bytes(payload))
                .take(),
        nonce: nonce,
        key: key,
        additionalData: utf8Bytes(topic),
      );
      final w = ByteWriter()..u8(recipients.length);
      for (final r in recipients.toList()..sort()) {
        w
          ..bytes(publicKeyFromId(r))
          ..bytes(Identity.sealFor(_c, r, contentKey));
      }
      return (w
            ..bytes(nonce)
            ..bytes(ct))
          .take();
    } finally {
      key.dispose();
    }
  }

  /// Returns the recipients and, if this member is one of them, the body.
  (Set<String>, Uint8List?) _unrestrict(String topic, Uint8List block) {
    final r = ByteReader(block);
    final n = r.u8();
    final recipients = <String>{};
    Uint8List? sealedForMe;
    for (var i = 0; i < n; i++) {
      final pk = r.bytes(Identity.publicKeyBytes);
      if (!Identity.isValidKey(_c, pk)) throw const FormatPepException('restricted item: invalid recipient key');
      final id = b64u(pk);
      final sealed = r.bytes(_sealedKeyBytes);
      recipients.add(id);
      if (id == _me.id) sealedForMe = Uint8List.fromList(sealed);
    }
    final nonce = r.bytes(24);
    final ct = r.rest();
    if (sealedForMe == null) return (recipients, null);
    final contentKey = _me.openSealed(sealedForMe);
    if (contentKey == null) throw const FormatPepException('restricted item: content key not readable');
    final key = _c.sodium.secureCopy(contentKey);
    try {
      final Uint8List plain;
      try {
        plain = _c.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ct,
          nonce: nonce,
          key: key,
          additionalData: utf8Bytes(topic),
        );
      } catch (_) {
        throw const FormatPepException('restricted item: cannot decrypt');
      }
      final p = ByteReader(plain);
      final flags = p.u8();
      final payload = Uint8List.fromList(p.rest());
      return (recipients, flags & 1 != 0 ? inflate(payload) : payload);
    } finally {
      key.dispose();
    }
  }

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

  /// Once the key is derived: the access list first, then the items.
  void _reprocessAll() {
    final all = [
      for (final e in _raw.entries)
        if (topics.parse(e.key)!.kind != TopicKind.meta) (topics.parse(e.key)!, e.key, e.value),
    ]..sort((a, b) => (a.$1.kind == TopicKind.acl ? 0 : 1).compareTo(b.$1.kind == TopicKind.acl ? 0 : 1));
    for (final (ref, topic, payload) in all) {
      _process(ref, topic, payload);
    }
  }

  void _process(TopicRef ref, String topic, Uint8List payload) {
    try {
      switch (ref.kind) {
        case TopicKind.meta:
          _onMeta(topic, payload);
        // Before the key is derived (joining), payloads wait in _raw.
        case TopicKind.acl:
          if (_key != null) _onAcl(topic, payload);
        case TopicKind.item:
          if (_key != null) _onItem(ref.collection!, ref.id!, topic, payload);
        case TopicKind.sync:
          break;
      }
    } on PepException catch (e) {
      _emit(MessageRejected(topic, e));
    } catch (e) {
      // Whatever a message makes fail, it must not stop the channel.
      _emit(MessageRejected(topic, FormatPepException('unexpected content: $e')));
    }
  }

  /// Metadata is signed by the owner named in the join link, and never
  /// changes: another key check is rejected.
  void _onMeta(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_meta != null) _emit(const ChannelDeleted());
      return;
    }
    final meta = ChannelMeta.open(_c, topic: topic, data: payload, ownerKey: publicKeyFromId(ownerId));
    final current = _meta;
    if (current != null) {
      if (!bytesEqual(current.keyCheck, meta.keyCheck)) {
        throw const AuthorizationException('channel metadata with another key');
      }
      return;
    }
    _meta = meta;
    if (!_metaArrived.isCompleted) _metaArrived.complete();
  }

  void _onAcl(String topic, Uint8List payload) {
    if (payload.isEmpty) {
      if (_acl != null) _emit(const ChannelDeleted());
      return;
    }
    final o = _env.open(key: _key!.dataKey, topic: topic, data: payload);
    if (o.deleted) throw const FormatPepException('access list tombstone');
    if (o.signerId != ownerId) throw const AuthorizationException('access list not signed by the owner');
    final acl = ChannelAcl.decode(o.body);
    if (acl.ownerId != ownerId) throw const AuthorizationException('access list names another owner');
    final v = _aclVersion;
    if (v != null && !_newer(o, v)) return;
    _acl = acl;
    _aclVersion = o;
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
        _entries[topic] = _Entry(e!.opened, null, e.recipients);
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
    if (!_canWrite(o.signerId, collection, id)) {
      _pending.add(topic);
      throw AuthorizationException('${o.signerId} may not write $collection/$id');
    }
    // Leaves room for the revisions the owner adds when re-signing.
    if (o.rev > maxItemRev && o.signerId != ownerId) throw FormatPepException('revision ${o.rev} too high');
    _pending.remove(topic);
    final known = _entries[topic];
    if (known != null && !known.olderThan(o)) return;
    final wasVisible = known?.item != null;
    ChannelItem? item;
    Set<String>? recipients;
    var expired = false;
    if (!o.deleted) {
      if (o.restricted) {
        final (r, body) = _unrestrict(topic, o.body);
        recipients = Set.unmodifiable(r);
        if (body != null) item = _makeItem(collection, id, o, body, recipients);
      } else {
        item = _makeItem(collection, id, o, o.body, null);
      }
      if (item != null && !_fresh(item, _now())) {
        item = null;
        expired = true;
      }
    }
    _entries[topic] = _Entry(o, item, recipients);
    if (item != null) {
      _emit(ItemUpdated(item));
    } else if (wasVisible) {
      _emit(ItemRemoved(collection, id, expired: expired));
    }
  }

  ChannelItem _makeItem(String collection, String id, Opened o, Uint8List body, Set<String>? recipients) => ChannelItem(
    collection: collection,
    id: id,
    rev: o.rev,
    time: o.time,
    signerId: o.signerId,
    body: body,
    recipients: recipients,
  );
}
